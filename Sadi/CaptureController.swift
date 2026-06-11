import FluidAudio
import Foundation
import Observation
import OSLog
import SadiKit

/// Phases 2 + 3 + 4 coordinator. Owns the recording lifecycle as an explicit
/// state machine and delegates per-session state to `ActiveSession` (which
/// holds one `StreamPipeline` per capture stream: ring → archive writer →
/// `StreamProcessor` → `TranscriptStore`).
///
/// Lifecycle: .idle → .starting → .recording → .stopping → .idle. The heavy
/// bring-up (HAL device setup, `AudioOutputUnitStart`, writer/file creation)
/// and teardown both run OFF the main thread; the main actor only sequences
/// them. `stop()` is idempotent — concurrent callers (Stop button, idle
/// auto-stop, app termination) all await the same teardown task.
@Observable
@MainActor
final class CaptureController {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    private(set) var phase: Phase = .idle
    /// True from the moment Record is pressed until teardown completes. UI
    /// uses this for the Stop button / live row; the idle monitor and the
    /// deferred system start check `phase == .recording` specifically.
    var isRunning: Bool { phase != .idle }

    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var micStatus: String = "idle"
    private(set) var systemStatus: String = "idle"
    private(set) var sessionID: String = ""
    private(set) var sessionDirectoryPath: String = ""

    private let modelHost: ModelHost
    private let transcript: TranscriptStore

    private var session: ActiveSession?
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "capture")

    init(modelHost: ModelHost, transcript: TranscriptStore) {
        self.modelHost = modelHost
        self.transcript = transcript
    }

    // MARK: - Start

    /// Synchronous entry point: transitions to `.starting` immediately (so a
    /// second tap is rejected and the UI flips at once) and runs the actual
    /// bring-up in a task. A Stop during bring-up cancels that task and tears
    /// down whatever was registered — see `performStop`.
    func start() {
        guard phase == .idle else { return }
        guard modelHost.vad != nil,
              modelHost.asrModels != nil,
              modelHost.diarizerModel != nil,
              modelHost.embeddingDiarizer != nil
        else {
            micStatus = "models not loaded"
            systemStatus = "models not loaded"
            return
        }
        phase = .starting
        micStatus = "starting"
        systemStatus = "waiting for mic"
        startTask = Task { await self.performStart() }
    }

    private func performStart() async {
        guard let vad = modelHost.vad,
              let asrModels = modelHost.asrModels,
              let diarizerModel = modelHost.diarizerModel,
              let embeddingDiarizer = modelHost.embeddingDiarizer
        else {
            micStatus = "models not loaded"
            systemStatus = "models not loaded"
            if !Task.isCancelled { phase = .idle }
            return
        }

        // Session directory on disk — off main; Application Support can be
        // slow (and unbounded on a network home directory).
        let paths: SessionPaths
        do {
            paths = try await Task.detached(priority: .userInitiated) {
                try SessionPaths.create()
            }.value
        } catch {
            micStatus = "session-dir: \(error)"
            systemStatus = "session-dir: \(error)"
            if !Task.isCancelled { phase = .idle }
            return
        }

        let session = ActiveSession(paths: paths, startedAt: Date())
        self.session = session
        sessionID = paths.id
        sessionDirectoryPath = paths.directory.path(percentEncoded: false)
        transcript.reset()

        // Mic pipeline. Device setup, writer creation, and the unit start all
        // happen off main — `AudioOutputUnitStart` alone can block ~1 s on a
        // Bluetooth device mid-transition, which used to beachball the UI.
        // The pipeline is registered on the session the moment it's live, so
        // a concurrent stop (which awaits `startTask` first) tears it down
        // through the normal path.
        do {
            let micURL = paths.micURL(segment: 1)
            // The anchor is the stream's sample-0 wall clock; stamping it
            // right after the unit starts (rather than at session start) keeps
            // utterance timestamps honest even when bring-up blocked for a
            // second on a balky device.
            let (mic, micWriter, anchor) = try await Task.detached(priority: .userInitiated) {
                let m = try MicCapture()
                let w = try SegmentArchiveWriter(url: micURL, sampleRate: m.sampleRate)
                try m.start()
                return (m, w, Date())
            }.value
            do {
                let processor = try StreamProcessor(
                    source: .mic,
                    sourceRate: mic.sampleRate,
                    vad: vad,
                    asrModels: asrModels,
                    diarizerModel: diarizerModel,
                    embeddingDiarizer: embeddingDiarizer,
                    store: transcript,
                    startWallClock: anchor
                )
                session.add(StreamPipeline(
                    source: .mic,
                    capture: mic,
                    rateSource: nil,
                    writer: micWriter,
                    processor: processor,
                    segmentFilename: micURL.lastPathComponent,
                    anchor: anchor,
                    publish: { [weak self] level in
                        self?.micLevel = level
                    },
                    onStall: { [weak self] in
                        self?.handleStall(source: .mic)
                    }
                ))
            } catch {
                // Processor construction failed after the unit started — don't
                // leak a running, unregistered capture.
                await Task.detached(priority: .userInitiated) { mic.stop() }.value
                throw error
            }
            micStatus = "running @ \(Int(mic.sampleRate)) Hz"
        } catch {
            micStatus = "failed: \(error)"
            Self.log.error("Mic start failed: \(String(describing: error), privacy: .public)")
        }

        // A stop raced the bring-up; it's awaiting `startTask` and owns the
        // teardown of everything registered above from here.
        if Task.isCancelled { return }

        phase = .recording
        session.idleMonitor = startIdleMonitor()

        // System audio pipeline — deferred until the mic has actually started
        // producing audio. Opening the mic input can kick off a Bluetooth
        // A2DP→HFP profile switch that churns CoreAudio for ~1 s; creating the
        // system process tap during that window corrupts it (-10877 storms, a
        // collapsed effective rate). The mic's first delivered frame signals
        // the input device (and any profile switch) has settled.
        session.systemStartTask = Task { [weak self] in
            guard let self else { return }
            let mic = session.pipeline(for: .mic)?.capture
            for _ in 0..<40 {  // up to ~2 s
                if Task.isCancelled { return }
                if mic?.firstHostTime != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled, self.phase == .recording else { return }
            await self.startSystemPipeline(in: session)
        }
    }

    /// Build and start the system-audio pipeline. Runs after the mic has
    /// settled (see the deferred task in `performStart`). Tap + aggregate
    /// creation happen off main — `SystemAudioCapture.init` can sleep up to
    /// ~500 ms retrying the Sequoia object-not-ready race, and the first
    /// `AudioDeviceStart` can block on the TCC permission prompt.
    private func startSystemPipeline(in session: ActiveSession) async {
        guard let vad = modelHost.vad,
              let asrModels = modelHost.asrModels,
              let diarizerModel = modelHost.diarizerModel,
              let embeddingDiarizer = modelHost.embeddingDiarizer
        else { return }

        // The system stream's sample-0 anchor is stamped right after the tap
        // starts — NOT at session start. The tap is brought up here, ~1.5–2 s
        // after the mic (we waited for the mic/Bluetooth path to settle), so
        // anchoring to session start would slot every system utterance ~1.5 s
        // too early relative to the mic. The post-start stamp is within a few
        // tens of ms of the tap's first frame, well below noticeable.
        do {
            let systemURL = session.paths.systemURL(segment: 1)
            let (system, systemWriter, anchor) = try await Task.detached(priority: .userInitiated) {
                let s = try SystemAudioCapture()
                let w = try SegmentArchiveWriter(url: systemURL, sampleRate: s.sampleRate)
                try s.start()
                return (s, w, Date())
            }.value
            do {
                let processor = try StreamProcessor(
                    source: .system,
                    sourceRate: system.sampleRate,
                    vad: vad,
                    asrModels: asrModels,
                    diarizerModel: diarizerModel,
                    embeddingDiarizer: embeddingDiarizer,
                    store: transcript,
                    startWallClock: anchor
                )
                session.add(StreamPipeline(
                    source: .system,
                    capture: system,
                    rateSource: system,
                    writer: systemWriter,
                    processor: processor,
                    segmentFilename: systemURL.lastPathComponent,
                    anchor: anchor,
                    publish: { [weak self] level in
                        self?.systemLevel = level
                    },
                    onStall: { [weak self] in
                        self?.handleStall(source: .system)
                    }
                ))
            } catch {
                // Don't leak a running, unregistered tap.
                await Task.detached(priority: .userInitiated) { system.stop() }.value
                throw error
            }
            systemStatus = "running @ \(Int(system.sampleRate)) Hz"
        } catch {
            systemStatus = "failed: \(error)"
            Self.log.error("System start failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stall failsafe: a pipeline reported sustained archive-audio loss (ring
    /// overflow or writer backpressure — in practice, a wedged disk). Stop the
    /// recording through the normal idempotent path and tell the user why.
    /// Fired from the archive loop via a main-actor hop; the stop runs in its
    /// own task so the reporting loop is never blocked on its own teardown.
    private func handleStall(source: Source) {
        guard phase == .starting || phase == .recording else { return }
        Self.log.error("Archive stall on \(source == .mic ? "mic" : "system", privacy: .public) — stopping recording")
        Task {
            await self.stop()
            RecordingNotifier.recordingStalled()
        }
    }

    /// Watch the transcript's last-activity timestamp and stop the recording
    /// once it's been idle longer than the user's auto-stop window, posting a
    /// local notification when it fires. The setting is re-read every tick, so
    /// toggling auto-stop (or changing its duration) mid-recording takes effect.
    /// Polling at a coarse interval is plenty — the window is minutes.
    private func startIdleMonitor() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.phase == .recording, !Task.isCancelled else { return }
                let config = AutoStopSettings.current()
                guard config.enabled else { continue }
                let idle = Date().timeIntervalSince(self.transcript.lastActivityAt)
                guard idle >= Double(config.minutes) * 60 else { continue }
                Self.log.notice("Auto-stop: idle \(Int(idle))s ≥ \(config.minutes)m — stopping")
                await self.stop()
                RecordingNotifier.autoStopped(afterMinutes: config.minutes)
                return
            }
        }
    }

    // MARK: - Stop

    /// Idempotent: the first caller creates the teardown task; everyone else
    /// (Stop button, idle auto-stop, app termination) awaits that same task,
    /// so a second Stop can never interleave a second teardown.
    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        guard phase == .starting || phase == .recording else { return }
        // Stamp the end the moment the user stopped, before the teardown awaits.
        let endedAt = Date()
        let task = Task { await self.performStop(endedAt: endedAt) }
        stopTask = task
        await task.value
    }

    private func performStop(endedAt: Date) async {
        phase = .stopping
        // Cancel a bring-up still in flight and wait it out. `performStart`
        // registers each pipeline on the session as soon as it's live, so once
        // this await returns the pipeline list is final (modulo the deferred
        // system task, handled next) and teardown below covers everything.
        startTask?.cancel()
        await startTask?.value
        startTask = nil

        if let session {
            // Stop the idle monitor. Cancel-only (no `await`): when auto-stop
            // fires, the monitor task is the caller, so awaiting its value
            // would deadlock.
            session.idleMonitor?.cancel()
            session.idleMonitor = nil
            // Cancel the deferred system start and wait it out, so it can't
            // bring a system pipeline up after we've begun tearing down.
            session.systemStartTask?.cancel()
            await session.systemStartTask?.value
            session.systemStartTask = nil

            // Tear the capture devices down OFF the main thread. Their stop()
            // makes blocking HAL calls (AudioOutputUnitStop, AudioDeviceStop,
            // dispose) that can wedge for seconds when a Bluetooth device is
            // mid-transition — running them on the main actor beachballs the
            // UI. `await`ing a detached task suspends the main actor without
            // blocking the main thread.
            let captures = session.pipelines.map(\.capture)
            await Task.detached(priority: .userInitiated) {
                for capture in captures { capture.stop() }
            }.value

            // Archivers drain the ring tails, finish their inference channels,
            // and finalize the MP4s (the producers above are quiesced, so the
            // tails are stable). The inference tasks then complete on their
            // own once they've consumed everything — await them (no cancel) so
            // every utterance reaches the store before the transcript persists.
            for pipeline in session.pipelines { pipeline.archiver.cancel() }
            for pipeline in session.pipelines { await pipeline.archiver.value }
            for pipeline in session.pipelines { await pipeline.inference.value }

            // MP4s are finalized now. Persist on-disk artifacts in SPEC §10.6
            // order: audio (done) → transcript.json → session.json. A clean
            // Stop and a graceful quit (which routes through this same path)
            // both leave a fully self-describing session directory.
            do {
                try await transcript.writeTranscript(to: session.paths.directory)
            } catch {
                Self.log.error("Transcript persist failed: \(String(describing: error), privacy: .public)")
            }
            await session.writeMetadata(endedAt: endedAt)
        }

        session = nil
        micLevel = 0
        systemLevel = 0
        micStatus = "idle"
        systemStatus = "idle"
        phase = .idle
        stopTask = nil
    }
}
