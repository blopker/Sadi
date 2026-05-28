import FluidAudio
import Foundation
import Observation
import OSLog
import SadiKit

/// Phases 2 + 3 + 4 orchestrator. Owns the two capture sources, opens one
/// archive writer per stream, and runs a consumer task per ring that:
///   1. Pulls source-rate Float32 mono samples
///   2. Appends to the segment's fragmented MP4 (Phase 3)
///   3. Hands the samples to the per-stream StreamProcessor (Phase 4): which
///      resamples to 16 kHz, segments via Silero VAD, transcribes via
///      Parakeet, and publishes Utterances to the shared TranscriptStore
///   4. Publishes RMS to the meter UI
@Observable
final class CaptureController {
    private(set) var isRunning = false
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var micStatus: String = "idle"
    private(set) var systemStatus: String = "idle"
    private(set) var sessionID: String = ""
    private(set) var sessionDirectoryPath: String = ""

    private let modelHost: ModelHost
    private let transcript: TranscriptStore

    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var micConsumer: Task<Void, Never>?
    private var systemConsumer: Task<Void, Never>?

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "capture")

    init(modelHost: ModelHost, transcript: TranscriptStore) {
        self.modelHost = modelHost
        self.transcript = transcript
    }

    func start() {
        guard !isRunning else { return }
        guard let vad = modelHost.vad,
              let asrModels = modelHost.asrModels,
              let diarizerModel = modelHost.diarizerModel,
              let embeddingDiarizer = modelHost.embeddingDiarizer
        else {
            micStatus = "models not loaded"
            systemStatus = "models not loaded"
            return
        }

        let session: SessionPaths
        do {
            session = try SessionPaths.create()
        } catch {
            micStatus = "session-dir: \(error)"
            systemStatus = "session-dir: \(error)"
            return
        }
        sessionID = session.id
        sessionDirectoryPath = session.directory.path(percentEncoded: false)
        let startWallClock = Date()
        transcript.reset()
        isRunning = true

        // Mic pipeline.
        do {
            let m = try MicCapture()
            let writer = try SegmentArchiveWriter(
                url: session.micURL(segment: 1),
                sampleRate: m.sampleRate
            )
            let proc = try StreamProcessor(
                source: .mic,
                sourceRate: m.sampleRate,
                vad: vad,
                asrModels: asrModels,
                diarizerModel: diarizerModel,
                embeddingDiarizer: embeddingDiarizer,
                store: transcript,
                startWallClock: startWallClock
            )
            try m.start()
            mic = m
            micStatus = "running @ \(Int(m.sampleRate)) Hz"
            micConsumer = consume(ring: m.ring, writer: writer, processor: proc) { [weak self] level in
                self?.micLevel = level
            }
        } catch {
            micStatus = "failed: \(error)"
            Self.log.error("Mic start failed: \(String(describing: error), privacy: .public)")
        }

        // System audio pipeline.
        do {
            let s = try SystemAudioCapture()
            let writer = try SegmentArchiveWriter(
                url: session.systemURL(segment: 1),
                sampleRate: s.sampleRate
            )
            let proc = try StreamProcessor(
                source: .system,
                sourceRate: s.sampleRate,
                vad: vad,
                asrModels: asrModels,
                diarizerModel: diarizerModel,
                embeddingDiarizer: embeddingDiarizer,
                store: transcript,
                startWallClock: startWallClock
            )
            try s.start()
            system = s
            systemStatus = "running @ \(Int(s.sampleRate)) Hz"
            systemConsumer = consume(ring: s.ring, writer: writer, processor: proc) { [weak self] level in
                self?.systemLevel = level
            }
        } catch {
            systemStatus = "failed: \(error)"
            Self.log.error("System start failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() async {
        guard isRunning else { return }
        mic?.stop()
        system?.stop()
        micConsumer?.cancel()
        systemConsumer?.cancel()
        await micConsumer?.value
        await systemConsumer?.value
        mic = nil
        system = nil
        micConsumer = nil
        systemConsumer = nil
        micLevel = 0
        systemLevel = 0
        micStatus = "idle"
        systemStatus = "idle"
        isRunning = false
    }

    private nonisolated func consume(
        ring: SPSCRingBuffer,
        writer: SegmentArchiveWriter,
        processor: StreamProcessor,
        publish: @escaping @MainActor (Float) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            var scratch = [Float](repeating: 0, count: 1024)
            while !Task.isCancelled {
                let pulled = scratch.withUnsafeMutableBufferPointer { buf in
                    ring.pull(count: buf.count, into: buf)
                }
                if !pulled {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }

                scratch.withUnsafeBufferPointer { buf in
                    do {
                        try writer.append(buf)
                    } catch {
                        Self.log.error("Archive append: \(String(describing: error), privacy: .public)")
                    }
                }

                // Hand the same chunk to the transcription pipeline.
                await processor.feed(scratch)

                var sumSq: Float = 0
                for v in scratch { sumSq += v * v }
                let rms = (sumSq / Float(scratch.count)).squareRoot()
                await publish(rms)
            }
            await writer.finalize()
        }
    }
}
