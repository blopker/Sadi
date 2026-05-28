import AVFoundation
import Carbon.HIToolbox
import Combine
import Foundation
import SwiftUI

/// Central state object. Owns the recorders, the transcriber, the hotkey
/// and on-disk persistence, and exposes everything the UI observes.
@MainActor
final class AppController: ObservableObject {

    @Published var status: RecordingStatus = .idle
    @Published var recordings: [Recording] = []
    @Published var selectedRecordingID: Recording.ID?
    @Published var modelsReady = false

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    private let mixer = AudioMixer()
    private let transcriber = Transcriber()
    private var hotkey: GlobalHotkey?

    private var currentMicURL: URL?
    private var currentSystemURL: URL?
    private var recordingStartedAt: Date?

    /// Folder where audio files and the JSON index live.
    private let storageDir: URL = {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = base.appendingPathComponent("Sadi/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Persistence: saved transcripts + the in-progress crash marker.
    private lazy var library = RecordingLibrary(directory: storageDir)

    init() {
        registerHotkey()
        recordings = library.loadRecordings()
    }

    var selectedRecording: Recording? {
        recordings.first { $0.id == selectedRecordingID }
    }

    // MARK: - Setup

    private func registerHotkey() {
        // Cmd-Option-R toggles recording from anywhere.
        hotkey = GlobalHotkey(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(cmdKey | optionKey)
        ) { [weak self] in
            Task { @MainActor in self?.toggleRecording() }
        }
    }

    /// Loads transcription models, then recovers any interrupted recording.
    /// Call once at launch.
    func prepareModels() async {
        guard !modelsReady else { return }
        status = .preparingModels
        do {
            try await transcriber.prepare()
            modelsReady = true
            status = .idle
        } catch {
            status = .error("Model load failed: \(error.localizedDescription)")
            return
        }
        await recoverInterruptedRecording()
    }

    // MARK: - Recording control

    func toggleRecording() {
        switch status {
        case .recording:
            Task { await stopRecording() }
        case .idle, .error:
            Task { await startRecording() }
        default:
            break  // busy loading models or transcribing
        }
    }

    func startRecording() async {
        guard status == .idle || isErrorState else { return }

        guard await MicRecorder.requestPermission() else {
            status = .error(RecorderError.micPermissionDenied.localizedDescription)
            return
        }

        let stamp = Self.fileStamp()
        let micURL = storageDir.appendingPathComponent("mic-\(stamp).caf")
        let systemURL = storageDir.appendingPathComponent("system-\(stamp).m4a")

        do {
            try mic.start(outputURL: micURL)
            try await system.start(outputURL: systemURL)
        } catch {
            mic.stop()
            await system.stop()
            status = .error(error.localizedDescription)
            return
        }

        let startedAt = Date()
        currentMicURL = micURL
        currentSystemURL = systemURL
        recordingStartedAt = startedAt

        // Crash recovery: drop a marker so that if the app dies before Stop,
        // the next launch knows these audio files still need processing.
        library.writeMarker(
            InterruptedSession(
                micFileURL: micURL, systemFileURL: systemURL, startedAt: startedAt))

        status = .recording
    }

    func stopRecording() async {
        guard status == .recording,
            let micURL = currentMicURL,
            let systemURL = currentSystemURL,
            let startedAt = recordingStartedAt
        else { return }

        mic.stop()
        await system.stop()

        currentMicURL = nil
        currentSystemURL = nil
        recordingStartedAt = nil

        status = .transcribing
        do {
            let recording = try await makeRecording(
                micURL: micURL, systemURL: systemURL,
                startedAt: startedAt, title: Self.displayTitle(for: startedAt))
            recordings.insert(recording, at: 0)
            selectedRecordingID = recording.id
            library.saveRecordings(recordings)
            status = .idle
        } catch {
            status = .error(
                "Transcription failed: \(error.localizedDescription) "
                    + "The raw audio is safe in the Recordings folder.")
        }

        // The audio files are saved regardless; the marker has done its job.
        library.clearMarker()
    }

    // MARK: - Crash recovery

    /// If the previous session was interrupted (crash / force quit), mix and
    /// transcribe the orphaned audio files so the recording isn't lost.
    private func recoverInterruptedRecording() async {
        guard let session = library.readMarker() else { return }

        // Only worth recovering if at least one track has real audio on disk.
        guard
            Self.fileHasData(session.micFileURL)
                || Self.fileHasData(session.systemFileURL)
        else {
            library.clearMarker()
            return
        }

        status = .transcribing
        do {
            let recording = try await makeRecording(
                micURL: session.micFileURL,
                systemURL: session.systemFileURL,
                startedAt: session.startedAt,
                title: Self.recoveredTitle(for: session.startedAt))
            recordings.insert(recording, at: 0)
            selectedRecordingID = recording.id
            library.saveRecordings(recordings)
            status = .idle
        } catch {
            status = .error(
                "Couldn't transcribe the recovered recording: "
                    + "\(error.localizedDescription) The raw audio is "
                    + "preserved in the Recordings folder.")
        }
        library.clearMarker()
    }

    /// Shared pipeline: transcribe each source track, plus mix for playback.
    private func makeRecording(
        micURL: URL, systemURL: URL,
        startedAt: Date, title: String
    ) async throws -> Recording {
        // The mix is kept only for playback; transcription runs on each source
        // track separately so a quiet mic isn't swamped by loud system audio.
        let mixedURL = storageDir.appendingPathComponent("mixed-\(Self.fileStamp()).m4a")
        try await mixer.mix(micURL: micURL, systemURL: systemURL, outputURL: mixedURL)

        let duration = (try? await AVURLAsset(url: mixedURL).load(.duration))?.seconds ?? 0
        let segments = try await transcriber.transcribe(micURL: micURL, systemURL: systemURL)

        return Recording(
            title: title,
            createdAt: startedAt,
            micFileURL: micURL,
            systemFileURL: systemURL,
            mixedFileURL: mixedURL,
            durationSeconds: duration,
            segments: segments)
    }

    // MARK: - Helpers

    private var isErrorState: Bool {
        if case .error = status { return true }
        return false
    }

    /// True if the file exists and holds more than just a container header.
    private static func fileHasData(_ url: URL) -> Bool {
        guard
            let size = try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? Int
        else { return false }
        return size > 1_024
    }

    private static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func displayTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Recording — \(f.string(from: date))"
    }

    private static func recoveredTitle(for date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Recovered recording — \(f.string(from: date))"
    }
}
