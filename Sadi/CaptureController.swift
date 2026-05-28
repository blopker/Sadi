import Foundation
import Observation
import OSLog
import SadiKit

/// Phase 2 + 3 orchestrator: owns the two capture sources, opens one archive
/// writer per stream, and runs a consumer task per ring that pulls samples,
/// appends to the writer, and publishes RMS to the UI.
@Observable
final class CaptureController {
    private(set) var isRunning = false
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var micStatus: String = "idle"
    private(set) var systemStatus: String = "idle"
    private(set) var sessionID: String = ""
    private(set) var sessionDirectoryPath: String = ""

    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var micConsumer: Task<Void, Never>?
    private var systemConsumer: Task<Void, Never>?

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "capture")

    func start() {
        guard !isRunning else { return }

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
        isRunning = true

        // Mic: capture → writer → RMS.
        do {
            let m = try MicCapture()
            let writer = try SegmentArchiveWriter(
                url: session.micURL(segment: 1),
                sampleRate: m.sampleRate
            )
            try m.start()
            mic = m
            micStatus = "running @ \(Int(m.sampleRate)) Hz"
            micConsumer = consume(ring: m.ring, writer: writer) { [weak self] level in
                self?.micLevel = level
            }
        } catch {
            micStatus = "failed: \(error)"
            Self.log.error("Mic start failed: \(String(describing: error), privacy: .public)")
        }

        // System audio: capture → writer → RMS.
        do {
            let s = try SystemAudioCapture()
            let writer = try SegmentArchiveWriter(
                url: session.systemURL(segment: 1),
                sampleRate: s.sampleRate
            )
            try s.start()
            system = s
            systemStatus = "running @ \(Int(s.sampleRate)) Hz"
            systemConsumer = consume(ring: s.ring, writer: writer) { [weak self] level in
                self?.systemLevel = level
            }
        } catch {
            systemStatus = "failed: \(error)"
            Self.log.error("System start failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() async {
        guard isRunning else { return }
        // Stop producers first so no more samples flow into the rings.
        mic?.stop()
        system?.stop()
        // Cancel consumers; each finalizes its writer in its defer.
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
        publish: @escaping @MainActor (Float) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            // ~21 ms at 48 kHz. Stable RMS, small AAC frames.
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
                        Self.log.error("Archive append failed: \(String(describing: error), privacy: .public)")
                    }
                }

                var sumSq: Float = 0
                for v in scratch { sumSq += v * v }
                let rms = (sumSq / Float(scratch.count)).squareRoot()
                await publish(rms)
            }
            // Cancelled — flush AVAssetWriter so the .mp4 is fully playable.
            await writer.finalize()
        }
    }
}
