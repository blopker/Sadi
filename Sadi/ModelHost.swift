import FluidAudio
import Foundation
import Observation
import OSLog

// FluidAudio's LSEENDModel uses an internal NSLock to serialize predict calls
// (see Sources/FluidAudio/Diarizer/LS-EEND/LSEENDInference.swift). It does not
// declare Sendable, so we retroactively assert it — the lock is what makes
// passing it from the MainActor ModelHost into the per-stream actor safe.
extension LSEENDModel: @unchecked @retroactive Sendable {}

// DiarizerManager: we only call its read-only `extractSpeakerEmbedding`
// helper from per-stream actors after init. Internal models are immutable
// post-init; safe to mark @unchecked Sendable.
extension DiarizerManager: @unchecked @retroactive Sendable {}

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
    private(set) var diarizerModel: LSEENDModel?
    private(set) var embeddingDiarizer: DiarizerManager?
    /// Offline (batch) diarization model set — loaded lazily on the first
    /// finalize/rerun pass, NOT at app start: it's a separate ~100 MB download
    /// (Segmentation/FBank/Embedding/PldaRho, HF variant "offline") that a
    /// user who never reruns a transcript shouldn't pay for. The task is
    /// memoized so concurrent passes share one download/compile.
    private var offlineDiarizerModelsTask: Task<OfflineDiarizerModels, Error>?

    /// Stable identifier for the speaker-embedding model. Stamped into each
    /// `Voiceprint` so we can detect (and refuse to match against) prints
    /// from a different model release (SPEC §8.2).
    nonisolated static let embeddingModelVersion = "fluidaudio-wespeaker-256d-v1"

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "models")

    /// Whether every model folder `loadIfNeeded()` needs is already on disk.
    /// The CLI uses this to fail fast instead of silently kicking off a
    /// (potentially large) HuggingFace download in a headless run.
    nonisolated static func modelsPresent() -> Bool {
        let root = AsrModels.defaultCacheDirectory(for: .v2).deletingLastPathComponent()
        let required = ["parakeet-tdt-0.6b-v2", "ls-eend", "silero-vad", "speaker-diarization"]
        let fm = FileManager.default
        return required.allSatisfy { name in
            var isDir: ObjCBool = false
            let path = root.appending(path: name, directoryHint: .isDirectory).path(percentEncoded: false)
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Load (downloading on first use) the offline diarizer models. Memoized;
    /// a failed attempt clears the memo so the next pass can retry.
    /// `OfflineDiarizerModels` is Sendable — callers construct their own
    /// (non-Sendable) `OfflineDiarizerManager` from it inside whatever task
    /// runs the pass.
    func loadOfflineDiarizerModels() async throws -> OfflineDiarizerModels {
        let task = offlineDiarizerModelsTask ?? Task.detached(priority: .userInitiated) {
            try await OfflineDiarizerModels.load()
        }
        offlineDiarizerModelsTask = task
        do {
            return try await task.value
        } catch {
            Self.log.error("Offline diarizer load failed: \(String(describing: error), privacy: .public)")
            offlineDiarizerModelsTask = nil
            throw error
        }
    }

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
            state = .loading(fraction: 0.97, phase: "Downloading LS-EEND")

            // LS-EEND streaming diarizer. dihard3 variant is the general-
            // purpose default (vs callhome/ami). 100 ms step gives us
            // sub-utterance frame resolution for the dominant-speaker query
            // without being so fine that we pay extra inference cost.
            let lseend = try await LSEENDModel.loadFromHuggingFace(
                variant: .dihard3,
                stepSize: .step100ms
            )
            self.diarizerModel = lseend
            state = .loading(fraction: 0.99, phase: "Loading speaker embedding")

            // DiarizerModels carries both the segmentation + 256-dim WeSpeaker
            // embedding model. We only use the embedding side (LS-EEND handles
            // diarization itself), but DiarizerManager.extractSpeakerEmbedding
            // needs the segmentation model loaded to size its all-ones mask.
            let diarizerCache = AsrModels.defaultCacheDirectory(for: .v2)
                .deletingLastPathComponent()
                .appending(path: "speaker-diarization", directoryHint: .isDirectory)
            let diarModels = try await DiarizerModels.load(from: diarizerCache)
            let dm = DiarizerManager(config: .default)
            dm.initialize(models: consume diarModels)
            self.embeddingDiarizer = dm

            state = .ready
            Self.log.info("Models ready (VAD + Parakeet v2 + LS-EEND dihard3 + WeSpeaker)")
        } catch {
            Self.log.error("Model load failed: \(String(describing: error), privacy: .public)")
            state = .failed(String(describing: error))
        }
    }
}
