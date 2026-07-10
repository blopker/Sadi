import FluidAudio
import Foundation
import Observation
import OSLog
import SadiKit

// FluidAudio's LSEENDModel uses an internal NSLock to serialize predict calls
// (see Sources/FluidAudio/Diarizer/LS-EEND/LSEENDInference.swift). It does not
// declare Sendable, so we retroactively assert it — the lock is what makes
// passing it from the MainActor ModelHost into the per-stream actor safe.
extension LSEENDModel: @unchecked @retroactive Sendable {}

// DiarizerManager: we only call its read-only `extractSpeakerEmbedding`
// helper from per-stream actors after init. Internal models are immutable
// post-init; safe to mark @unchecked Sendable.
extension DiarizerManager: @unchecked @retroactive Sendable {}

/// Single point of truth for the speech models. Loads Silero VAD, the Apple
/// SpeechTranscriber ASR engine, and the FluidAudio diarizers once at app
/// start; both stream processors share them (ASR/decoder state is
/// per-segment, not per-instance).
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
    private(set) var asr: AppleAsr?
    /// Validated LocalVQE dylib/model locations, set during `loadIfNeeded`.
    /// `nil` when the engine can't be loaded — the pipeline then runs
    /// without acoustic AEC (the text-level EchoFilter remains), so load
    /// failure is non-fatal. Consumers construct their own engine instance
    /// per use via `makeAEC()`: a LocalVQE context carries per-stream
    /// adaptive-filter state, so a live session and a concurrent offline
    /// pass must never share one.
    private(set) var aecLocations: (library: URL, model: URL)?
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

    /// Whether every model `loadIfNeeded()` needs is already on disk — the
    /// FluidAudio folders plus the OS speech assets for our locale. The CLI
    /// uses this to fail fast instead of silently kicking off a (potentially
    /// large) download in a headless run.
    nonisolated static func modelsPresent() async -> Bool {
        // `AsrModels.defaultCacheDirectory` is used purely as a path anchor
        // for the FluidAudio cache root; the Parakeet ASR models themselves
        // are no longer downloaded.
        let root = AsrModels.defaultCacheDirectory(for: .v2).deletingLastPathComponent()
        let required = ["ls-eend", "silero-vad", "speaker-diarization"]
        let fm = FileManager.default
        let fluidPresent = required.allSatisfy { name in
            var isDir: ObjCBool = false
            let path = root.appending(path: name, directoryHint: .isDirectory).path(percentEncoded: false)
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        guard fluidPresent else { return false }
        return await AppleAsr.assetsInstalled()
    }

    /// Locate the LocalVQE dylib + model. In the app bundle: dylib embedded
    /// in Frameworks (code-signed on copy), model in Resources. The env var
    /// override serves headless/dev runs outside a full bundle.
    nonisolated static func localVQELocations() -> (library: URL, model: URL)? {
        func locate(library: URL, model: URL) -> (URL, URL)? {
            let fm = FileManager.default
            guard fm.fileExists(atPath: library.path(percentEncoded: false)),
                  fm.fileExists(atPath: model.path(percentEncoded: false))
            else { return nil }
            return (library, model)
        }
        if let dir = ProcessInfo.processInfo.environment["SADI_LOCALVQE_DIR"] {
            let d = URL(fileURLWithPath: dir, isDirectory: true)
            if let found = locate(
                library: d.appending(path: LocalVQE.libraryFilename),
                model: d.appending(path: LocalVQE.modelFilename)) {
                return found
            }
        }
        guard let fw = Bundle.main.privateFrameworksURL, let res = Bundle.main.resourceURL else {
            return nil
        }
        return locate(
            library: fw.appending(path: LocalVQE.libraryFilename),
            model: res.appending(path: LocalVQE.modelFilename))
    }

    /// Build a fresh LocalVQE engine (one per canceller/session). ~10 ms of
    /// dlopen + GGUF parse — call off the main actor. Returns nil (logged)
    /// when the engine is unavailable.
    nonisolated static func makeAEC(locations: (library: URL, model: URL)?) -> LocalVQE? {
        guard let locations else { return nil }
        do {
            return try LocalVQE(libraryURL: locations.library, modelURL: locations.model)
        } catch {
            Self.log.error("LocalVQE engine construction failed: \(String(describing: error), privacy: .public)")
            return nil
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
            state = .loading(fraction: 0.05, phase: "Preparing speech model")

            // Apple SpeechTranscriber: the OS ships the model; first run may
            // download the locale's assets (system-managed, shared).
            let asr = try await AppleAsr.load { fraction, phase in
                Task { @MainActor [weak self] in
                    self?.state = .loading(
                        fraction: 0.05 + 0.9 * fraction,
                        phase: phase
                    )
                }
            }
            self.asr = asr
            state = .loading(fraction: 0.96, phase: "Loading echo canceller")

            // LocalVQE AEC — bundled. Validate once (off-main: dlopen + GGUF
            // parse) and remember the locations; consumers build their own
            // engine per session via `makeAEC`. Non-fatal: without it the mic
            // path runs raw and the text-level echo filter carries alone.
            if let locations = Self.localVQELocations() {
                let ok = await Task.detached(priority: .userInitiated) {
                    Self.makeAEC(locations: locations) != nil
                }.value
                if ok { self.aecLocations = locations }
            } else {
                Self.log.error("LocalVQE dylib/model not found (continuing without AEC)")
            }
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
            // (`AsrModels.defaultCacheDirectory` = path anchor only, see
            // `modelsPresent`.)
            let diarizerCache = AsrModels.defaultCacheDirectory(for: .v2)
                .deletingLastPathComponent()
                .appending(path: "speaker-diarization", directoryHint: .isDirectory)
            let diarModels = try await DiarizerModels.load(from: diarizerCache)
            let dm = DiarizerManager(config: .default)
            dm.initialize(models: consume diarModels)
            self.embeddingDiarizer = dm

            state = .ready
            Self.log.info("Models ready (VAD + Apple ASR + LS-EEND dihard3 + WeSpeaker)")
        } catch {
            Self.log.error("Model load failed: \(String(describing: error), privacy: .public)")
            state = .failed(String(describing: error))
        }
    }
}
