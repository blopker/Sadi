import AVFoundation
import Foundation
import OSLog
import SadiKit
import Speech

/// Apple `SpeechTranscriber` (macOS 26 `SpeechAnalyzer`) as the ASR stage.
/// Replaces Parakeet for transcription only — VAD, diarization, speaker
/// embeddings, and echo filtering stay on the FluidAudio pipeline. Raw
/// accuracy between the two engines is a wash and Sadi's differentiation
/// lives in that surrounding pipeline (scratch/speech-compare/ANALYSIS.md);
/// Apple's engine wins on zero model download and OS-managed assets.
///
/// Stateless: each `transcribe` call builds a fresh transcriber + analyzer
/// (~70–270 ms per segment, measured), the same fresh-decoder-per-segment
/// shape the Parakeet path used. One instance is safely shared across both
/// stream processors and the offline rerun's worker pool.
final class AppleAsr: Sendable {
    struct Result: Sendable {
        /// Full transcript text, whitespace-trimmed.
        let text: String
        /// Word-level tokens, times in seconds relative to the segment.
        /// Apple emits one attributed-text run per word carrying
        /// `.audioTimeRange`; each token's text keeps its leading space, so
        /// joining texts reconstructs the transcript — the exact contract
        /// `TimedToken`/`SpeakerSegmenter.joinTokenText` expect. Empty when
        /// the engine returned no timed runs.
        let words: [TimedToken]
    }

    enum Failure: Error, LocalizedError {
        case noSupportedLocale
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .noSupportedLocale:
                "Apple speech recognition supports neither the system locale nor en-US."
            case .bufferAllocationFailed:
                "Could not allocate an audio buffer for transcription."
            }
        }
    }

    let locale: Locale

    private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "apple-asr")

    private init(locale: Locale) {
        self.locale = locale
    }

    /// The locale the engine will run in: the user's, falling back to en-US
    /// (always available; matches Parakeet's English-only behavior).
    private static func resolveLocale() async -> Locale? {
        if let current = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            return current
        }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
    }

    /// Whether the speech assets for the resolved locale are already on disk.
    /// The CLI's fail-fast check, alongside `ModelHost.modelsPresent()` — a
    /// headless run must not silently kick off a system asset download.
    static func assetsInstalled() async -> Bool {
        guard let locale = await resolveLocale() else { return false }
        return await SpeechTranscriber.installedLocales
            .contains { $0.identifier == locale.identifier }
    }

    /// Resolve the locale, reserve its asset slot, and download the speech
    /// model if the OS doesn't have it yet (first run only; the asset is
    /// system-managed and shared across apps).
    static func load(
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> AppleAsr {
        guard let locale = await resolveLocale() else { throw Failure.noSupportedLocale }

        // The locale must be reserved before an analyzer may use it (today a
        // console warning, "will be an error in a future release").
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier == locale.identifier }) {
            try await AssetInventory.reserve(locale: locale)
        }

        let transcriber = Self.makeTranscriber(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log.info("Downloading speech assets for \(locale.identifier, privacy: .public)")
            let poller = Task {
                while !Task.isCancelled {
                    progress(request.progress.fractionCompleted, "Downloading speech model")
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { poller.cancel() }
            try await request.downloadAndInstall()
        }
        log.info("Apple ASR ready (locale \(locale.identifier, privacy: .public))")
        return AppleAsr(locale: locale)
    }

    /// Transcribe one speech segment of 16 kHz mono Float32 samples.
    func transcribe(_ samples: [Float]) async throws -> Result {
        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // 16 kHz mono *Int16* — the transcriber's only accepted format
        // (`bestAvailableAudioFormat` reports it; Float32 input traps inside
        // the Speech framework).
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.int16ChannelData?.pointee
        else { throw Failure.bufferAllocationFailed }
        for (i, v) in samples.enumerated() {
            // isFinite guard: Int16(NaN) traps, and a degenerate capture
            // (device glitch mid-resample) must not take the app down.
            channel[i] = v.isFinite ? Int16(max(-1.0, min(1.0, v)) * 32767) : 0
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Results must be consumed concurrently with the analysis — the
        // sequence ends when the analyzer finishes.
        let collector = Task { () -> (String, [TimedToken]) in
            var text = ""
            var words: [TimedToken] = []
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    words.append(
                        TimedToken(
                            text: String(result.text[run.range].characters),
                            startTime: range.start.seconds,
                            endTime: range.end.seconds
                        ))
                }
            }
            return (text, words)
        }

        do {
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            continuation.yield(AnalyzerInput(buffer: buffer))
            continuation.finish()
            if let last = try await analyzer.analyzeSequence(stream) {
                try await analyzer.finalizeAndFinish(through: last)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            // End the results sequence so the collector can't leak, then
            // surface the analyzer error (the collector's is secondary).
            await analyzer.cancelAndFinishNow()
            _ = try? await collector.value
            throw error
        }

        let (text, words) = try await collector.value
        return Result(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: words
        )
    }

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }
}
