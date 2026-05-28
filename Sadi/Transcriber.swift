import Foundation
import FluidAudio

/// Wraps FluidAudio to turn the recorded tracks into a speaker-labelled
/// transcript, fully on-device.
///
/// Strategy: transcribe each source track on its own rather than diarizing a
/// mixed file. The mic and system levels routinely differ by ~10x, so a quiet
/// speaker vanishes from a mix; and we already know which track is which. Per
/// track we diarize first, then run ASR independently on each diarization
/// segment's audio slice, so every ASR call's text belongs to one speaker.
///
/// API NOTE: written against FluidAudio 0.12.x. If you pull a newer version
/// and the build breaks, check the README's "Models" section in the
/// FluidAudio repo — manager/method names occasionally change.
actor Transcriber {

    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?
    private var isPrepared = false

    private let sampleRate = 16_000.0

    /// Per-track loudness target (RMS) and clip ceiling, so a quiet mic and a
    /// loud system track both reach the level the models expect.
    private let targetRMS: Float = 0.06
    private let maxPeak: Float = 0.95

    /// Cosine-distance threshold below which a mic voice is judged the same
    /// speaker as a far-end voice (i.e. bleed). Matches FluidAudio's own
    /// same-speaker clustering threshold.
    private let bleedMatchDistance: Float = 0.65
    /// Energy backstop: if the far-end is at least this many times louder than
    /// the mic across a segment, treat it as (degraded) bleed even without a
    /// fingerprint match.
    private let bleedEnergyRatio: Float = 3.0

    /// A transcribed speech turn plus the speaker embedding behind it, kept so
    /// the bleed gate can compare mic voices against far-end voices.
    private struct DiarizedTurn {
        let transcript: TranscriptSegment
        let embedding: [Float]
    }

    /// Downloads (first run only) and loads the ASR + diarization models.
    /// Models are cached by FluidAudio after the first download.
    func prepare() async throws {
        guard !isPrepared else { return }

        // English-optimised Parakeet. Use `.v3` for multilingual instead.
        let asrModels = try await AsrModels.downloadAndLoad(version: .v2)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(asrModels)
        self.asr = asr

        // Pyannote Community-1 offline pipeline — best accuracy for batch.
        let diarizer = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await diarizer.prepareModels()
        self.diarizer = diarizer

        isPrepared = true
    }

    /// Produces a speaker-labelled transcript from the two source tracks.
    ///
    /// On a call (far-end audio present) the mic is treated as the single local
    /// speaker, "You". With no far-end — e.g. system capture off and the mic
    /// recording a room — the mic is diarized into its own speakers instead, so
    /// we never assume the mic is just one person.
    func transcribe(micURL: URL, systemURL: URL) async throws -> [TranscriptSegment] {
        // Both tracks are diarized on their own merits; ids are namespaced so
        // the two tracks' speaker clusters never collide.
        let (systemSamples, systemGain, systemTurns) = try await transcribeTrack(systemURL, speakerPrefix: "remote-")
        let (micSamples, micGain, micTurns) = try await transcribeTrack(micURL, speakerPrefix: "mic-")

        let systemSegments = systemTurns.map(\.transcript)

        // Branch on whether the far-end actually spoke.
        let micFinal: [TranscriptSegment]
        if systemTurns.isEmpty {
            // No far-end speech: mic-only / in-room recording. Keep the mic's
            // own diarized speakers — there's no far-end to bleed in.
            micFinal = micTurns.map(\.transcript)
        } else {
            // Call: drop the far-end's bleed from the mic (hybrid gate), then
            // label the survivors as the single local speaker, "You".
            let farVoices = centroids(of: systemTurns)
            micFinal = micTurns
                .filter { turn in
                    !isBleed(turn, farEndSpeech: systemSegments, farVoices: farVoices,
                             micSamples: micSamples, micGain: micGain,
                             systemSamples: systemSamples, systemGain: systemGain)
                }
                .map { turn in
                    var labelled = turn.transcript
                    labelled.speakerId = TranscriptSegment.localSpeakerID
                    return labelled
                }
        }

        return (systemSegments + micFinal).sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Bleed detection

    /// Average embedding (voiceprint) per far-end speaker cluster.
    private func centroids(of turns: [DiarizedTurn]) -> [[Float]] {
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for turn in turns where !turn.embedding.isEmpty {
            let id = turn.transcript.speakerId
            if var running = sums[id] {
                guard running.count == turn.embedding.count else { continue }
                for i in running.indices { running[i] += turn.embedding[i] }
                sums[id] = running
                counts[id, default: 0] += 1
            } else {
                sums[id] = turn.embedding
                counts[id] = 1
            }
        }
        return sums.compactMap { id, sum in
            guard let count = counts[id], count > 0 else { return nil }
            return sum.map { $0 / Float(count) }
        }
    }

    /// Hybrid bleed test for one mic turn during a call. Bleed is only possible
    /// while the far-end is speaking, so a turn that overlaps no far-end speech
    /// is always kept (this is what lets a local speaker who sounds like the
    /// far-end survive). Otherwise:
    /// Primary — fingerprint: does the mic voice match a far-end voiceprint
    /// (≈ same speaker)? Level-independent, so it survives double-talk.
    /// Backstop — energy: lacking a fingerprint match, is the far-end
    /// overwhelmingly louder (degraded bleed that didn't match)?
    private func isBleed(
        _ turn: DiarizedTurn,
        farEndSpeech: [TranscriptSegment],
        farVoices: [[Float]],
        micSamples: [Float], micGain: Float,
        systemSamples: [Float], systemGain: Float
    ) -> Bool {
        let seg = turn.transcript

        let overlapsFarEnd = farEndSpeech.contains { far in
            min(seg.endTime, far.endTime) - max(seg.startTime, far.startTime) > 0.1
        }
        guard overlapsFarEnd else { return false }

        if !turn.embedding.isEmpty, !farVoices.isEmpty {
            let nearest = farVoices.map { cosineDistance(turn.embedding, $0) }.min() ?? .infinity
            if nearest < bleedMatchDistance { return true }   // same voice as far-end
        }

        // Raw (pre-normalization) levels, undoing each track's gain so the
        // loudness boost — which also lifts the bleed — doesn't mask it.
        let micRaw = rms(of: micSamples, from: seg.startTime, to: seg.endTime) / micGain
        let sysRaw = rms(of: systemSamples, from: seg.startTime, to: seg.endTime) / systemGain
        return sysRaw > micRaw * bleedEnergyRatio
    }

    /// Cosine distance (0 = identical, larger = more different) between two
    /// embeddings; matches FluidAudio's definition so `bleedMatchDistance`
    /// stays comparable to its speaker threshold.
    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return .infinity }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }

    // MARK: - Per-track pipeline

    /// Resamples + loudness-normalizes one track, diarizes it, and transcribes
    /// each speech segment. Speaker ids are namespaced with `speakerPrefix` so
    /// the two tracks' clusters never collide. A track with no speech yields an
    /// empty turn list rather than throwing, so a silent system track (nothing
    /// was playing) doesn't sink the run. Also returns the normalized samples,
    /// applied gain, and each turn's speaker embedding, for the bleed gate.
    private func transcribeTrack(
        _ url: URL,
        speakerPrefix: String
    ) async throws -> (samples: [Float], gain: Float, turns: [DiarizedTurn]) {
        guard let asr, let diarizer else { throw RecorderError.notPrepared }

        var samples = try AudioConverter().resampleAudioFile(url)
        guard let gain = normalize(&samples) else { return ([], 1, []) }   // silent

        let diarization: DiarizationResult
        do {
            diarization = try await diarizer.process(audio: samples)
        } catch let error as OfflineDiarizationError {
            if case .noSpeechDetected = error { return (samples, gain, []) }
            throw error
        }

        var turns: [DiarizedTurn] = []
        for segment in diarization.segments {
            let startIdx = max(0, Int(Double(segment.startTimeSeconds) * sampleRate))
            let endIdx = min(samples.count, Int(Double(segment.endTimeSeconds) * sampleRate))
            guard endIdx > startIdx else { continue }

            let slice = Array(samples[startIdx..<endIdx])
            // Fresh decoder state per slice: each is an independent turn.
            var decoderState = try TdtDecoderState()
            let asrResult = try await asr.transcribe(slice, decoderState: &decoderState)
            let text = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            turns.append(DiarizedTurn(
                transcript: TranscriptSegment(
                    speakerId: speakerPrefix + segment.speakerId,
                    startTime: Double(segment.startTimeSeconds),
                    endTime: Double(segment.endTimeSeconds),
                    text: text),
                embedding: segment.embedding))
        }
        return (samples, gain, turns)
    }

    // MARK: - Audio helpers

    /// Scales `samples` in place toward `targetRMS`, capping gain so the peak
    /// stays below `maxPeak`. Returns the gain applied, or nil if the track is
    /// effectively silent. The gain lets callers recover raw levels later.
    private func normalize(_ samples: inout [Float]) -> Float? {
        guard !samples.isEmpty else { return nil }

        var sumSquares = 0.0
        var peak: Float = 0
        for v in samples {
            sumSquares += Double(v) * Double(v)
            peak = max(peak, abs(v))
        }
        let level = Float((sumSquares / Double(samples.count)).squareRoot())
        guard level > 0.0005, peak > 0 else { return nil }

        var gain = targetRMS / level
        if peak * gain > maxPeak { gain = maxPeak / peak }
        for i in samples.indices { samples[i] *= gain }
        return gain
    }

    /// RMS level of `samples` within the `[start, end)` time window (seconds).
    private func rms(of samples: [Float], from start: Double, to end: Double) -> Float {
        let lo = max(0, Int(start * sampleRate))
        let hi = min(samples.count, Int(end * sampleRate))
        guard hi > lo else { return 0 }
        var sumSquares = 0.0
        for i in lo..<hi { sumSquares += Double(samples[i]) * Double(samples[i]) }
        return Float((sumSquares / Double(hi - lo)).squareRoot())
    }
}
