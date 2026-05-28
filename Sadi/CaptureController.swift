import Foundation
import Observation
import SadiKit

/// Debug-meter orchestrator for Phase 2. Owns the two capture sources, runs
/// one consumer task per ring that pulls samples and publishes RMS to the UI.
/// The realtime callbacks themselves are still pure `ring.push` — verify in
/// `MicCapture.swift` and `SystemAudioCapture.swift`.
@Observable
final class CaptureController {
    private(set) var isRunning = false
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var micStatus: String = "idle"
    private(set) var systemStatus: String = "idle"

    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var micConsumer: Task<Void, Never>?
    private var systemConsumer: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        isRunning = true

        do {
            let m = try MicCapture()
            try m.start()
            mic = m
            micStatus = "running @ \(Int(m.sampleRate)) Hz"
            micConsumer = consumeMeter(ring: m.ring) { [weak self] level in
                self?.micLevel = level
            }
        } catch {
            micStatus = "failed: \(error)"
        }

        do {
            let s = try SystemAudioCapture()
            try s.start()
            system = s
            systemStatus = "running @ \(Int(s.sampleRate)) Hz"
            systemConsumer = consumeMeter(ring: s.ring) { [weak self] level in
                self?.systemLevel = level
            }
        } catch {
            systemStatus = "failed: \(error)"
        }
    }

    func stop() {
        guard isRunning else { return }
        micConsumer?.cancel(); micConsumer = nil
        systemConsumer?.cancel(); systemConsumer = nil
        mic?.stop(); mic = nil
        system?.stop(); system = nil
        micLevel = 0
        systemLevel = 0
        micStatus = "idle"
        systemStatus = "idle"
        isRunning = false
    }

    private nonisolated func consumeMeter(
        ring: SPSCRingBuffer,
        publish: @escaping @MainActor (Float) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            // ~21 ms at 48 kHz; small enough that meters feel live, large enough
            // that RMS is stable.
            var scratch = [Float](repeating: 0, count: 1024)
            while !Task.isCancelled {
                let pulled = scratch.withUnsafeMutableBufferPointer { buf in
                    ring.pull(count: buf.count, into: buf)
                }
                if !pulled {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }
                var sumSq: Float = 0
                for v in scratch { sumSq += v * v }
                let rms = (sumSq / Float(scratch.count)).squareRoot()
                await publish(rms)
            }
        }
    }
}
