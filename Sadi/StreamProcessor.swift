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
    private let resampler: Resampler
    private let vad: VadManager
    private let asr: AsrManager
    private let store: TranscriptStore
    private let startWallClock: Date

    private var streamState: VadStreamState
    private var pending16k: [Float] = []        // accumulator for partial chunks
    private var window: [Float] = []            // rolling window of 16 kHz samples
    private var windowStartSample: Int64 = 0    // absolute index of window[0]
    private var pendingSpeechStart: Int64?

    // Cap the unspoken backlog so a silent recording doesn't grow unbounded.
    private let windowCapSeconds: Int = 30
    private var windowCapSamples: Int { windowCapSeconds * Int(Resampler.targetRate) }

    private let minSpeechSamples = Int(Resampler.targetRate * 0.3)   // 300 ms
    private let maxSpeechSamples = Int(Resampler.targetRate * 14)    // < model cap (15 s)

    private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "stream")

    init(
        source: Source,
        sourceRate: Double,
        vad: VadManager,
        asrModels: AsrModels,
        store: TranscriptStore,
        startWallClock: Date
    ) throws {
        self.source = source
        self.resampler = try Resampler(sourceRate: sourceRate, maxInputFrames: 2048)
        self.vad = vad
        self.asr = AsrManager(config: .default, models: asrModels)
        self.store = store
        self.startWallClock = startWallClock
        self.streamState = VadStreamState.initial()
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

        while pending16k.count >= chunkSize {
            let chunk = Array(pending16k.prefix(chunkSize))
            pending16k.removeFirst(chunkSize)
            window.append(contentsOf: chunk)
            await advance(chunk: chunk)
            pruneWindowIfIdle()
        }
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
            Self.log.error("Segment outside window — dropped (start=\(startInWindow), end=\(endInWindow), windowCount=\(self.window.count))")
            return
        }
        let segmentSamples = Array(window[startInWindow..<endInWindow])

        do {
            var decoderState = try TdtDecoderState()
            let result = try await asr.transcribe(segmentSamples, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            let startedAt = wallClock(forSample: absoluteStart)
            let endedAt = wallClock(forSample: absoluteEnd)
            let utterance = Utterance(
                source: source,
                speaker: source == .mic ? .you : .them,
                text: text,
                startedAt: startedAt,
                endedAt: endedAt,
                asrConfidence: result.confidence
            )
            await store.append(utterance)
        } catch {
            Self.log.error("ASR failed: \(String(describing: error), privacy: .public)")
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
