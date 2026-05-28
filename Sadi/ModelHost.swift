import FluidAudio
import Foundation
import Observation
import OSLog

/// Single point of truth for the FluidAudio models. Loads Silero VAD and
/// Parakeet TDT v2 once at app start; both stream processors share the loaded
/// weights (their decoder state is per-segment, not per-instance).
@Observable
@MainActor
final class ModelHost {
    enum LoadState: Sendable, Equatable {
        case idle
        case loading(fraction: Double, phase: String)
        case ready
        case failed(String)
    }

    private(set) var state: LoadState = .idle
    private(set) var vad: VadManager?
    private(set) var asrModels: AsrModels?

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "models")

    func loadIfNeeded() async {
        switch state {
        case .ready, .loading: return
        default: break
        }
        state = .loading(fraction: 0, phase: "Loading VAD")

        do {
            // VAD: small (~20 MB), loads fast. Get it up first.
            let vad = try await VadManager()
            self.vad = vad
            state = .loading(fraction: 0.05, phase: "Downloading Parakeet TDT v2")

            // Parakeet TDT v2: SPEC §6.3 calls this version explicitly.
            // Default location is ~/Library/Application Support/FluidAudio/Models
            // under the sandbox container.
            let dir = AsrModels.defaultCacheDirectory(for: .v2)
            try FileManager.default.createDirectory(
                at: dir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let models = try await AsrModels.load(
                from: dir,
                version: .v2,
                progressHandler: { progress in
                    Task { @MainActor [weak self] in
                        self?.state = .loading(
                            fraction: 0.05 + 0.95 * progress.fractionCompleted,
                            phase: "Parakeet: \(progress.phase)"
                        )
                    }
                }
            )
            self.asrModels = models
            state = .ready
            Self.log.info("Models ready (VAD + Parakeet v2)")
        } catch {
            Self.log.error("Model load failed: \(String(describing: error), privacy: .public)")
            state = .failed(String(describing: error))
        }
    }
}
