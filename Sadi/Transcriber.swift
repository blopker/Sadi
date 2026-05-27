import Foundation
import FluidAudio

/// Wraps FluidAudio to turn a mixed audio file into a speaker-labelled
/// transcript, fully on-device.
///
/// Strategy: rather than aligning ASR word timestamps to diarization
/// segments (fragile), we diarize first, then run ASR independently on the
/// audio slice belonging to each diarization segment. Each ASR call's text
/// therefore belongs entirely to one speaker.
///
/// API NOTE: written against FluidAudio 0.12.x. If you pull a newer version
/// and the build breaks, check the README's "Models" section in the
/// FluidAudio repo — manager/method names occasionally change.
actor Transcriber {

    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?
    private var isPrepared = false

    private let sampleRate = 16_000.0

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

    /// Produces a speaker-labelled transcript for the audio at `fileURL`.
    func transcribe(fileURL: URL) async throws -> [TranscriptSegment] {
        guard let asr, let diarizer else { throw RecorderError.notPrepared }

        // Resample to the 16 kHz mono float samples both models expect.
        let samples = try AudioConverter().resampleAudioFile(fileURL)

        // 1. Who spoke when.
        let diarization = try await diarizer.process(audio: samples)

        // 2. For each speaker turn, transcribe just that slice of audio.
        var result: [TranscriptSegment] = []
        for segment in diarization.segments {
            let startIdx = max(0, Int(segment.startTimeSeconds * sampleRate))
            let endIdx = min(samples.count, Int(segment.endTimeSeconds * sampleRate))
            guard endIdx > startIdx else { continue }

            let slice = Array(samples[startIdx..<endIdx])
            let asrResult = try await asr.transcribe(slice)
            let text = asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            result.append(TranscriptSegment(
                speakerId: segment.speakerId,
                startTime: segment.startTimeSeconds,
                endTime: segment.endTimeSeconds,
                text: text))
        }

        return result.sorted { $0.startTime < $1.startTime }
    }
}
