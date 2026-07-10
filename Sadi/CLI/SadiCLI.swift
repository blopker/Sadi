import FluidAudio
import Foundation
import SadiKit

/// Headless entry point: `Sadi cli replay [--mic-only|--system-only] [SESSION]`.
///
/// Replays a recorded session through the same `ModelHost` / `StreamProcessor`
/// / `TranscriptStore` the GUI uses, reading models, the voiceprint book, and
/// recordings from the app's sandbox container so a replay matches a live run.
/// The transcript table goes to stdout; all progress and diagnostics go to
/// stderr; nothing is written to disk (no archive writer, voiceprint book read
/// only).
@MainActor
enum SadiCLI {
    /// Parse + dispatch. Returns a process exit code (never throws to caller).
    static func run(arguments: [String]) async -> Int32 {
        do {
            let command = try parse(arguments)
            switch command {
            case .help:
                print(Self.helpText)
                return 0
            case .replay(let options):
                try await replay(options)
                return 0
            case .offline(let mode, let session):
                try await offline(mode: mode, session: session)
                return 0
            case .micTest(let seconds):
                try await micTest(seconds: seconds)
                return 0
            }
        } catch let error as CLIError {
            stderr("error: \(error.message)")
            return error.code
        } catch {
            stderr("error: \(error)")
            return 1
        }
    }

    // MARK: - Command model

    enum TrackSelection { case both, micOnly, systemOnly }

    struct ReplayOptions {
        var session: String?
        var tracks: TrackSelection = .both
    }

    enum Command {
        case help
        case replay(ReplayOptions)
        case offline(OfflinePipeline.Mode, String?)
        case micTest(seconds: Double)
    }

    static func parse(_ args: [String]) throws -> Command {
        if args.isEmpty || args.contains("-h") || args.contains("--help") {
            return .help
        }
        if args[0] == "mic" {
            guard args.count <= 2 else { throw CLIError("unexpected extra argument.") }
            let seconds = args.count == 2 ? Double(args[1]) : 10
            guard let seconds, seconds > 0, seconds <= 120 else {
                throw CLIError("seconds must be a number in (0, 120].")
            }
            return .micTest(seconds: seconds)
        }
        if args[0] == "finalize" || args[0] == "rerun" {
            let mode: OfflinePipeline.Mode = args[0] == "finalize" ? .finalize : .rerun
            let rest = args.dropFirst()
            if let bad = rest.first(where: { $0.hasPrefix("-") }) {
                throw CLIError("unknown option '\(bad)'.")
            }
            guard rest.count <= 1 else {
                throw CLIError("unexpected extra argument '\(rest.dropFirst().first!)'.")
            }
            return .offline(mode, rest.first)
        }
        guard args[0] == "replay" else {
            throw CLIError("unknown command '\(args[0])'. Commands: replay, finalize, rerun.")
        }

        var options = ReplayOptions()
        for arg in args.dropFirst() {
            switch arg {
            case "--mic-only": options.tracks = .micOnly
            case "--system-only": options.tracks = .systemOnly
            default:
                if arg.hasPrefix("-") {
                    throw CLIError("unknown option '\(arg)'.")
                }
                if options.session != nil {
                    throw CLIError("unexpected extra argument '\(arg)'.")
                }
                options.session = arg
            }
        }
        return .replay(options)
    }

    // MARK: - Replay

    static func replay(_ options: ReplayOptions) async throws {
        let sessionDir = try resolveSession(options.session)
        let sessionID = sessionDir.lastPathComponent
        let sessionStart = parseSessionStart(from: sessionID)

        stderr("Session: \(sessionID)")
        stderr("  dir: \(sessionDir.path(percentEncoded: false))")

        // 1. Models — fail fast if they aren't already downloaded.
        guard await ModelHost.modelsPresent() else {
            throw CLIError(
                "models not downloaded. Launch the Sadi app once to fetch them, then retry.",
                code: 2
            )
        }
        stderr("Loading models…")
        let host = ModelHost()
        await host.loadIfNeeded()
        guard host.state == .ready,
              let vad = host.vad,
              let asr = host.asr,
              let diarizerModel = host.diarizerModel,
              let embeddingDiarizer = host.embeddingDiarizer
        else {
            if case .failed(let message) = host.state {
                throw CLIError("model load failed: \(message)")
            }
            throw CLIError("model load failed.")
        }

        // 2. Shared store + voiceprint book (read only — never persisted here).
        let book = VoiceprintBook(
            storeURL: SadiApp.voiceprintBookURL(),
            modelVersion: ModelHost.embeddingModelVersion
        )
        stderr("Voiceprints loaded: \(book.prints.count)")
        let store = TranscriptStore(voiceprints: book)

        // 3. Decode the requested tracks.
        var tracks: [FileReplayDriver.Track] = []
        for (source, file) in selectedTracks(options.tracks, sessionDir: sessionDir) {
            guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
                stderr("  \(source == .mic ? "mic" : "system"): missing \(file.lastPathComponent), skipping.")
                continue
            }
            let (samples, rate) = try FileReplayDriver.decodeMono(file)
            let seconds = rate > 0 ? Double(samples.count) / rate : 0
            stderr("  \(source == .mic ? "mic" : "system"): \(samples.count) samples @ \(Int(rate)) Hz (\(String(format: "%.1f", seconds)) s)")
            tracks.append(.init(source: source, samples: samples, sampleRate: rate))
        }
        guard !tracks.isEmpty else {
            throw CLIError("no audio tracks to replay in \(sessionID).")
        }

        // 4. Feed through the real pipeline.
        stderr("Replaying…")
        try await FileReplayDriver.feed(
            tracks: tracks,
            vad: vad,
            asr: asr,
            diarizerModel: diarizerModel,
            embeddingDiarizer: embeddingDiarizer,
            store: store,
            startWallClock: sessionStart,
            aec: host.aec
        )

        // 5. Print results (stdout) + summary; dropped detail to stderr.
        printResults(store, mode: tracks.contains { $0.source == .system } ? "call/mixed" : "mic-only")
    }

    // MARK: - Offline finalize / rerun

    /// Run the offline pipeline over a saved session. Unlike `replay`, this
    /// WRITES: transcript.json is replaced (generator finalize/rerun) and
    /// session.json's `needsFinalize` is cleared — exactly what the GUI's
    /// post-stop finalize and Rerun button do.
    static func offline(mode: OfflinePipeline.Mode, session: String?) async throws {
        let sessionDir = try resolveSession(session)
        stderr("Session: \(sessionDir.lastPathComponent)")
        stderr("  dir: \(sessionDir.path(percentEncoded: false))")

        guard await ModelHost.modelsPresent() else {
            throw CLIError(
                "models not downloaded. Launch the Sadi app once to fetch them, then retry.",
                code: 2
            )
        }
        stderr("Loading models…")
        let host = ModelHost()
        await host.loadIfNeeded()
        guard host.state == .ready else {
            if case .failed(let message) = host.state {
                throw CLIError("model load failed: \(message)")
            }
            throw CLIError("model load failed.")
        }

        let book = VoiceprintBook(
            storeURL: SadiApp.voiceprintBookURL(),
            modelVersion: ModelHost.embeddingModelVersion
        )
        stderr("Voiceprints loaded: \(book.prints.count)")

        let outcome = try await OfflinePipeline.run(
            mode: mode,
            sessionDirectory: sessionDir,
            modelHost: host,
            voiceprints: book,
            progress: { stderr("  \($0)") }
        )

        let utterances = RecordingsStore.loadTranscript(from: sessionDir)
        print("────── Transcript (\(utterances.count)) ──────")
        for u in utterances { print(row(u, marker: "✓")) }
        print("""

        ────── Summary ──────
        mode:            \(outcome.mode.rawValue)
        kept:            \(outcome.utteranceCount)
        dropped (echo):  \(outcome.droppedAsEcho)
        voiceprint hits: \(outcome.voiceprintHits)
        """)
    }

    // MARK: - Mic test

    /// Sandboxed end-to-end check of the live mic path: MicCapture (raw
    /// AUHAL) → resample → Apple ASR. Prints level stats and the transcript.
    static func micTest(seconds: Double) async throws {
        stderr("Recording \(seconds)s from the mic…")
        let mic = try MicCapture()
        stderr("  client rate: \(Int(mic.sampleRate)) Hz")
        try mic.start()

        var samples: [Float] = []
        var buf = [Float](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let avail = mic.ring.availableToRead
            if avail >= 1024 {
                let n = min(avail, buf.count)
                let ok = buf.withUnsafeMutableBufferPointer { mic.ring.pull(count: n, into: $0) }
                if ok { samples.append(contentsOf: buf[0..<n]) }
            } else {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        mic.stop()

        var sumSq: Float = 0
        var peak: Float = 0
        for v in samples {
            sumSq += v * v
            peak = max(peak, abs(v))
        }
        let rms = samples.isEmpty ? 0 : (sumSq / Float(samples.count)).squareRoot()
        print(String(
            format: "captured %.1f s, rms=%.5f, peak=%.5f, dropped=%d",
            Double(samples.count) / mic.sampleRate, rms, peak, mic.droppedFrames))
        guard !samples.isEmpty else { throw CLIError("no samples captured (mic permission?)") }

        stderr("Transcribing…")
        let asr = try await AppleAsr.load()
        var resampler = try Resampler(sourceRate: mic.sampleRate, maxInputFrames: 2048)
        var samples16k: [Float] = []
        var i = 0
        while i < samples.count {
            let chunk = Array(samples[i..<min(i + 2048, samples.count)])
            let out = try chunk.withUnsafeBufferPointer { try resampler.resample($0) }
            samples16k.append(contentsOf: out)
            i += 2048
        }
        let result = try await asr.transcribe(samples16k)
        print("transcript: \(result.text.isEmpty ? "(empty)" : result.text)")
    }

    // MARK: - Session resolution

    static func selectedTracks(_ selection: TrackSelection, sessionDir: URL) -> [(Source, URL)] {
        let mic = (Source.mic, sessionDir.appending(path: "mic-001.mp4", directoryHint: .notDirectory))
        let system = (Source.system, sessionDir.appending(path: "system-001.mp4", directoryHint: .notDirectory))
        switch selection {
        case .both: return [mic, system]
        case .micOnly: return [mic]
        case .systemOnly: return [system]
        }
    }

    static func resolveSession(_ arg: String?) throws -> URL {
        let root = try SessionPaths.recordingsRoot()
        let fm = FileManager.default
        if let arg {
            let asPath = URL(fileURLWithPath: arg, isDirectory: true)
            if fm.fileExists(atPath: asPath.path(percentEncoded: false)) { return asPath }
            let byID = root.appending(path: arg, directoryHint: .isDirectory)
            if fm.fileExists(atPath: byID.path(percentEncoded: false)) { return byID }
            throw CLIError("session not found: \(arg)")
        }
        let entries = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let sessions = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { $0.lastPathComponent.hasPrefix("20") }
        guard let newest = sessions.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            throw CLIError("no sessions found under \(root.path(percentEncoded: false)).")
        }
        return newest
    }

    static func parseSessionStart(from id: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter.date(from: id) ?? Date()
    }

    // MARK: - Output

    static func printResults(_ store: TranscriptStore, mode: String) {
        let kept = store.utterances
        let dropped = store.dropped

        print("────── Transcript (\(kept.count)) ──────")
        for u in kept { print(row(u, marker: "✓")) }

        if !dropped.isEmpty {
            stderr("\n────── Dropped (\(dropped.count)) ──────")
            for d in dropped { stderr(row(d.utterance, marker: "✗", trailer: "[\(d.reason.rawValue)]")) }
        }

        let namedHits = kept.filter { if case .named = $0.speaker { return true } else { return false } }.count
        print("""

        ────── Summary ──────
        mode:            \(mode)
        kept:            \(kept.count)
        dropped (echo):  \(dropped.count)
        voiceprint hits: \(namedHits)
        """)
    }

    static func row(_ u: Utterance, marker: String, trailer: String = "") -> String {
        let tag = u.source == .mic ? "MIC" : "SYS"
        let embed = u.embedding != nil ? "e" : "·"
        let trail = trailer.isEmpty ? "" : " \(trailer)"
        return "  \(marker) [\(tag) \(String(format: "rms=%.3f", u.rms ?? 0)) \(embed)] [\(speakerLabel(u.speaker))]\(trail) \(u.text)"
    }

    static func speakerLabel(_ speaker: SadiKit.Speaker) -> String {
        switch speaker {
        case .you: return "You"
        case .them: return "Them"
        case .remote(let n): return "Remote \(n)"
        case .localSpeaker(let n): return "Speaker \(n)"
        case .named(let name, _): return name
        }
    }

    // MARK: - Help

    static let helpText = """
    Sadi cli — drive the real transcription pipeline from recorded files.

    Replays a captured session through the exact StreamProcessor /
    TranscriptStore / ModelHost the GUI runs live — streaming VAD →
    Apple SpeechTranscriber ASR → LS-EEND diarization → WeSpeaker
    embedding → echo filter → voiceprint resolution. Only the audio
    source differs: a session's .mp4 tracks fed in chunks instead of
    live capture.

    Models, the voiceprint book, and recordings are read from the app's
    sandbox container, so a replay matches a live run.

    USAGE:
      Sadi cli replay [OPTIONS] [SESSION]
      Sadi cli finalize [SESSION]
      Sadi cli rerun [SESSION]
      Sadi cli mic [SECONDS]

    COMMANDS:
      replay         Re-drive the live streaming pipeline from the session's
                     audio. Read-only; prints the transcript to stdout.
      finalize       Offline post-pass: keep the saved transcript's text,
                     re-derive speakers (offline diarization + voiceprints)
                     and echo filtering. WRITES transcript.json/session.json.
      rerun          Full regeneration from audio: offline VAD + batch ASR +
                     the finalize tail. WRITES transcript.json/session.json.
      mic            Diagnostic: record SECONDS (default 10) from the live
                     MicCapture, print level stats and the ASR transcript.
                     Nothing written to disk.

    ARGS:
      SESSION        Session id (e.g. 2026-05-28-14-03-09) or a path to a
                     session directory. Default: newest session on disk.

    OPTIONS:
      --mic-only         Replay only the mic track.
      --system-only      Replay only the system track.
      -h, --help         Show this help.
    """
}

/// A user-facing CLI failure with an exit code. Distinct from internal errors
/// so we can print a clean one-line message instead of a Swift dump.
struct CLIError: Error {
    let message: String
    let code: Int32
    init(_ message: String, code: Int32 = 1) {
        self.message = message
        self.code = code
    }
}

/// All diagnostics go to stderr; only the transcript table goes to stdout.
func stderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
