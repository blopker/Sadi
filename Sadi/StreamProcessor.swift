import FluidAudio
import Foundation
import OSLog
import SadiKit

/// Per-stream (mic or system) transcription pipeline:
/// source-rate samples → 16 kHz resample → Silero streaming VAD → Parakeet
/// ASR → Utterance published to the TranscriptStore.
///
/// One instance per stream. Owns its own resampler and `AsrManager` (sharing
/// model weights from `ModelHost`; decoder state is fresh per segment, per
/// SPEC §6.3). VAD segmentation uses FluidAudio's `processStreamingChunk`,
/// which runs the Silero hysteresis state machine for us and emits
/// `.speechStart` / `.speechEnd` events.
actor StreamProcessor {
    private let source: Source
    private var resampler: Resampler
    private var resamplerSourceRate: Double
    private let vad: VadManager
    private let asr: AsrManager
    private let diarizer: LSEENDDiarizer
    private let embeddingDiarizer: DiarizerManager
    private let store: TranscriptStore
    /// Wall-clock instant this stream's sample 0 was captured. Each stream gets
    /// its own: the mic uses session start, but the system tap is brought up
    /// ~1.5–2 s later (we wait for the mic/Bluetooth path to settle first), so
    /// sharing one session-start `Date` would slot every system utterance
    /// ~1.5 s too early. `CaptureController` stamps the system's value when the
    /// system pipeline actually starts.
    private let startWallClock: Date

    private var streamState: VadStreamState
    private var pending16k: [Float] = []  // accumulator for partial chunks
    private var window: [Float] = []  // rolling window of 16 kHz samples
    private var windowStartSample: Int64 = 0  // absolute index of window[0]
    private var pendingSpeechStart: Int64?

    // Cap the unspoken backlog so a silent recording doesn't grow unbounded.
    private let windowCapSeconds: Int = 30
    private var windowCapSamples: Int { windowCapSeconds * Int(Resampler.targetRate) }

    private let minSpeechSamples = Int(Resampler.targetRate * 0.3)  // 300 ms
    // Backstop force-split for speech that never hits a VAD pause. 60 s rather
    // than the old 14 s: AsrManager.transcribe internally chunks audio > ~15 s
    // via ChunkProcessor (overlapping windows + token dedup), so long segments
    // transcribe fine — and more cleanly than several cold 14 s force-splits,
    // which each restart the decoder with no overlap. Trades worst-case latency
    // on a 60 s-unbroken monologue for far fewer mid-word seams.
    private let maxSpeechSamples = Int(Resampler.targetRate * 60)

    private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "stream")

    init(
        source: Source,
        sourceRate: Double,
        vad: VadManager,
        asrModels: AsrModels,
        diarizerModel: LSEENDModel,
        embeddingDiarizer: DiarizerManager,
        store: TranscriptStore,
        startWallClock: Date
    ) throws {
        self.source = source
        self.resampler = try Resampler(sourceRate: sourceRate, maxInputFrames: 2048)
        self.resamplerSourceRate = sourceRate
        self.vad = vad
        self.asr = AsrManager(config: .default, models: asrModels)
        self.diarizer = try LSEENDDiarizer(model: diarizerModel)
        self.embeddingDiarizer = embeddingDiarizer
        self.store = store
        self.startWallClock = startWallClock
        self.streamState = VadStreamState.initial()
    }

    /// SPEC §5.2: retune the resampler when the source's effective sample
    /// rate has drifted from the nominal rate the resampler was built for.
    /// Threshold of 0.2% picks up the kind of long-term drift CoreAudio
    /// process taps exhibit without thrashing on micro-jitter. The 16 kHz
    /// downstream state (VAD stream, ASR window, diarizer timeline) is
    /// untouched because the *output* rate is unchanged.
    func retuneSourceRate(_ measuredRate: Double, threshold: Double = 0.002) {
        guard measuredRate > 0 else { return }
        let relativeDelta = abs(measuredRate - resamplerSourceRate) / resamplerSourceRate
        guard relativeDelta > threshold else { return }
        do {
            self.resampler = try Resampler(sourceRate: measuredRate, maxInputFrames: 2048)
            Self.log.info(
                "Retuned \(self.source == .mic ? "mic" : "system") resampler: \(self.resamplerSourceRate, format: .fixed(precision: 2)) Hz → \(measuredRate, format: .fixed(precision: 2)) Hz (Δ \(relativeDelta * 100, format: .fixed(precision: 3))%)"
            )
            self.resamplerSourceRate = measuredRate
        } catch {
            Self.log.error(
                "Resampler retune failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Feed a chunk of source-rate Float32 mono samples (the same chunk the
    /// archive writer just consumed). Resamples → VAD → on speech-end, slices
    /// the window and transcribes.
    func feed(_ samples: [Float]) async {
        let resampled: [Float]
        do {
            resampled = try samples.withUnsafeBufferPointer { try resampler.resample($0) }
        } catch {
            Self.log.error("Resample failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard !resampled.isEmpty else { return }

        pending16k.append(contentsOf: resampled)
        let chunkSize = VadManager.chunkSize

        // Feed the diarizer once per resample call — it accepts any chunk
        // size, so we don't need the same 4096-step buffering as Silero VAD.
        do {
            _ = try diarizer.process(samples: resampled, sourceSampleRate: 16_000.0)
        } catch {
            Self.log.error("Diarize step failed: \(String(describing: error), privacy: .public)")
        }

        while pending16k.count >= chunkSize {
            let chunk = Array(pending16k.prefix(chunkSize))
            pending16k.removeFirst(chunkSize)
            window.append(contentsOf: chunk)
            await advance(chunk: chunk)
            pruneWindowIfIdle()
        }
    }

    /// Emit any speech still open when the stream ends (a `speechStart` with
    /// no `speechEnd` yet) — without this, a recording stopped mid-sentence
    /// silently loses its final utterance. Called once, after the last `feed`:
    /// by the inference task when its channel finishes, and by the CLI replay
    /// driver after the last chunk.
    ///
    /// Only audio that has been through the VAD is flushed; a sub-chunk
    /// remainder still sitting in `pending16k` (< ~256 ms) is below the
    /// 300 ms minimum segment length and is dropped with the stream.
    func flush() async {
        guard let start = pendingSpeechStart else { return }
        pendingSpeechStart = nil
        await emit(absoluteStart: start, absoluteEnd: Int64(streamState.processedSamples))
    }

    private func advance(chunk: [Float]) async {
        let stepResult: VadStreamResult
        do {
            stepResult = try await vad.processStreamingChunk(chunk, state: streamState)
        } catch {
            Self.log.error("VAD failed: \(String(describing: error), privacy: .public)")
            return
        }
        streamState = stepResult.state

        guard let event = stepResult.event else { return }
        switch event.kind {
        case .speechStart:
            pendingSpeechStart = Int64(event.sampleIndex)
        case .speechEnd:
            guard let start = pendingSpeechStart else { return }
            pendingSpeechStart = nil
            let end = Int64(event.sampleIndex)
            await emit(absoluteStart: start, absoluteEnd: end)
        }

        // Force-split very long speech to stay under the 15 s model cap.
        if let start = pendingSpeechStart {
            let current = Int64(streamState.processedSamples)
            if current - start >= Int64(maxSpeechSamples) {
                await emit(absoluteStart: start, absoluteEnd: current)
                pendingSpeechStart = current
            }
        }
    }

    private func emit(absoluteStart: Int64, absoluteEnd: Int64) async {
        guard absoluteEnd > absoluteStart else { return }
        let length = Int(absoluteEnd - absoluteStart)
        guard length >= minSpeechSamples else {
            Self.log.debug("Drop short segment: \(length) samples")
            return
        }
        let startInWindow = Int(absoluteStart - windowStartSample)
        let endInWindow = Int(absoluteEnd - windowStartSample)
        guard startInWindow >= 0, endInWindow <= window.count else {
            Self.log.error(
                "Segment outside window — dropped (start=\(startInWindow), end=\(endInWindow), windowCount=\(self.window.count))"
            )
            return
        }
        let segmentSamples = Array(window[startInWindow..<endInWindow])

        do {
            var decoderState = try TdtDecoderState()
            let result = try await asr.transcribe(segmentSamples, decoderState: &decoderState)
            let fullText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fullText.isEmpty else { return }

            let segmentStartSec = Double(absoluteStart) / Resampler.targetRate

            // No per-token timing → single Utterance with dominant speaker.
            guard let timings = result.tokenTimings, !timings.isEmpty else {
                let cluster = dominantCluster(
                    startSec: segmentStartSec, endSec: Double(absoluteEnd) / Resampler.targetRate)
                let speaker = label(source: source, cluster: cluster)
                await emitUtterance(
                    text: fullText,
                    words: nil,
                    runAudio: segmentSamples,
                    fallbackAudio: segmentSamples,
                    runStartSample: absoluteStart,
                    runEndSample: absoluteEnd,
                    speaker: speaker,
                    cluster: cluster,
                    confidence: result.confidence
                )
                return
            }

            // Per-token timing → split this VAD segment into one Utterance per
            // speaker-coherent word run. `Sadi cli replay` drives this exact
            // path from recorded files (see Sadi/CLI/FileReplayDriver.swift).
            let words = groupTokensIntoWords(timings)
            let runs = SpeakerSegmenter.splitIntoRuns(
                tokens: words,
                speakerAt: { [self] wordTimeRelative in
                    let absoluteSec = segmentStartSec + wordTimeRelative
                    return clusterAtInstant(timeSec: absoluteSec)
                },
                minTokensPerRun: 2
            )

            for run in runs {
                let runText = run.text
                if runText.isEmpty { continue }
                let runStartIdx = max(0, Int(run.startTime * Resampler.targetRate))
                let runEndIdx = min(segmentSamples.count, Int(run.endTime * Resampler.targetRate))
                let runAudio =
                    runEndIdx > runStartIdx
                    ? Array(segmentSamples[runStartIdx..<runEndIdx])
                    : segmentSamples

                let runStartSample = absoluteStart + Int64(run.startTime * Resampler.targetRate)
                let runEndSample = absoluteStart + Int64(run.endTime * Resampler.targetRate)
                let speaker = label(source: source, cluster: run.speakerIndex)
                await emitUtterance(
                    text: runText,
                    words: run.tokens,
                    runAudio: runAudio,
                    fallbackAudio: segmentSamples,
                    runStartSample: runStartSample,
                    runEndSample: runEndSample,
                    speaker: speaker,
                    cluster: run.speakerIndex,
                    confidence: result.confidence
                )
            }
        } catch {
            Self.log.error("ASR failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func emitUtterance(
        text: String,
        words: [TimedToken]?,
        runAudio: [Float],
        fallbackAudio: [Float],
        runStartSample: Int64,
        runEndSample: Int64,
        speaker: SadiKit.Speaker,
        cluster: Int?,
        confidence: Float?
    ) async {
        var sumSq: Float = 0
        for v in runAudio { sumSq += v * v }
        let rms = runAudio.isEmpty ? Float(0) : (sumSq / Float(runAudio.count)).squareRoot()

        // 256-dim WeSpeaker embedding for voiceprint matching (SPEC §8).
        // Need ≥300 ms of audio for a stable embedding; for shorter runs we
        // fall back to the whole VAD-segment slice — flagged ambiguous, since
        // the wider slice may contain other speakers.
        let usedFallback = runAudio.count < 4_800 && fallbackAudio.count > runAudio.count
        let embedAudio = usedFallback ? fallbackAudio : runAudio
        let embedding = try? embeddingDiarizer.extractSpeakerEmbedding(from: embedAudio)

        // Persist word timings re-based from segment-relative to
        // utterance-relative seconds (token times are relative to the VAD
        // segment; the utterance starts at the run's first token).
        let timings = words.map { ws -> [WordTiming] in
            let base = ws.first?.startTime ?? 0
            return ws.map { tok in
                WordTiming(
                    word: tok.text.trimmingCharacters(in: .whitespaces),
                    start: tok.startTime - base,
                    end: tok.endTime - base
                )
            }
        }

        let utterance = Utterance(
            source: source,
            speaker: speaker,
            text: text,
            startedAt: wallClock(forSample: runStartSample),
            endedAt: wallClock(forSample: runEndSample),
            embedding: embedding,
            asrConfidence: confidence,
            rms: rms,
            diarCluster: cluster,
            wordTimings: timings,
            assignmentKind: .auto,
            embeddingAmbiguous: embedding == nil ? nil : usedFallback
        )
        await store.receive(utterance)
    }

    // MARK: - Per-token speaker queries

    /// Group Parakeet's subword tokens into whole words. FluidAudio's ASR
    /// normalizes `▁` → " " before populating TokenTiming.token, so a word
    /// starts at any token whose text begins with a space (or, defensively,
    /// the raw `▁` marker if a future version stops normalizing).
    private func groupTokensIntoWords(_ timings: [TokenTiming]) -> [TimedToken] {
        var words: [TimedToken] = []
        var currentTexts: [String] = []
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0
        for tt in timings {
            let startsWord = tt.token.hasPrefix(" ") || tt.token.hasPrefix("▁")
            if startsWord && !currentTexts.isEmpty {
                words.append(
                    TimedToken(
                        text: currentTexts.joined(),
                        startTime: currentStart,
                        endTime: currentEnd
                    ))
                currentTexts = []
            }
            if currentTexts.isEmpty {
                currentStart = tt.startTime
            }
            currentTexts.append(tt.token)
            currentEnd = tt.endTime
        }
        if !currentTexts.isEmpty {
            words.append(
                TimedToken(
                    text: currentTexts.joined(),
                    startTime: currentStart,
                    endTime: currentEnd
                ))
        }
        return words
    }

    /// Dominant cluster id over [startSec, endSec) across the diarizer's
    /// finalized + tentative segments. Falls back to nil when the diarizer
    /// has no segments overlapping the range.
    private func dominantCluster(startSec: Double, endSec: Double) -> Int? {
        let frameDur = Double(diarizer.modelFrameHz.map { 1 / $0 } ?? 0.1)
        var overlap: [Int: Int] = [:]
        for (idx, speaker) in diarizer.timeline.speakers {
            for seg in speaker.finalizedSegments + speaker.tentativeSegments {
                let segStartSec = Double(seg.startFrame) * frameDur
                let segEndSec = Double(seg.endFrame) * frameDur
                let lo = max(segStartSec, startSec)
                let hi = min(segEndSec, endSec)
                if hi > lo { overlap[idx, default: 0] += Int((hi - lo) / frameDur) }
            }
        }
        return overlap.max(by: { $0.value < $1.value })?.key
    }

    /// Speaker cluster at a single instant — per-word lookup for
    /// SpeakerSegmenter. Returns nil when no diarizer segment covers the
    /// frame; SpeakerSegmenter then borrows the prior known speaker.
    private func clusterAtInstant(timeSec: Double) -> Int? {
        let frameDur = Double(diarizer.modelFrameHz.map { 1 / $0 } ?? 0.1)
        let frame = Int(timeSec / frameDur)
        for (idx, speaker) in diarizer.timeline.speakers {
            for seg in speaker.finalizedSegments + speaker.tentativeSegments {
                if seg.startFrame <= frame && frame <= seg.endFrame {
                    return idx
                }
            }
        }
        return nil
    }

    /// Visible-label mapping for a cluster id.
    ///
    /// System utterances get a `.them` placeholder only: `TranscriptStore` is
    /// the authority for the final `.them` vs `.remote(N)` numbering because
    /// it sees the full set of emitted clusters and can retroactively relabel
    /// earlier utterances when a second remote cluster first speaks (SPEC §13
    /// Phase 10). The raw cluster id rides along on `Utterance.diarCluster`.
    /// Mic-only multi-speaker numbering (`.localSpeaker(N)`) stays here — there
    /// is no cross-utterance relabel for it in this phase.
    private func label(source: Source, cluster: Int?) -> SadiKit.Speaker {
        switch source {
        case .system:
            return .them
        case .mic:
            let speakers = diarizer.timeline.speakers
            guard !speakers.isEmpty, let cid = cluster else { return .localSpeaker(1) }
            let displayIndex = (speakers.keys.sorted().firstIndex(of: cid) ?? 0) + 1
            return .localSpeaker(displayIndex)
        }
    }

    private func pruneWindowIfIdle() {
        // Only prune when we're not in the middle of a segment.
        guard pendingSpeechStart == nil else { return }
        if window.count > windowCapSamples {
            let drop = window.count - windowCapSamples
            window.removeFirst(drop)
            windowStartSample += Int64(drop)
        }
    }

    private func wallClock(forSample sample: Int64) -> Date {
        startWallClock.addingTimeInterval(Double(sample) / Resampler.targetRate)
    }

}
