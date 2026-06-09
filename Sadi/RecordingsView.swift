import SadiKit
import SwiftUI

/// Loads finalized recordings from disk (`~/Application Support/Sadi/recordings`).
/// Each session directory carries a `session.json` (metadata) and a
/// `transcript.json` (the utterances); the mp4s are the audio source of truth.
@Observable
@MainActor
final class RecordingsStore {
    private(set) var items: [RecordingItem] = []

    /// Rescan the recordings root. Cheap (decodes one small JSON per session),
    /// so we just call it on appear and whenever a recording finishes.
    func reload() {
        let fm = FileManager.default
        guard let root = try? SessionPaths.recordingsRoot(fileManager: fm),
              let dirs = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            items = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var loaded: [RecordingItem] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let sessionURL = dir.appending(path: "session.json", directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: sessionURL),
                  let session = try? decoder.decode(Session.self, from: data)
            else { continue }  // no metadata — see backfillMissingSessions()
            loaded.append(RecordingItem(session: session, directory: dir))
        }
        // Newest first.
        items = loaded.sorted { $0.session.startedAt > $1.session.startedAt }
    }

    /// Decode a finalized recording's `transcript.json` into utterances.
    static func loadTranscript(from directory: URL) -> [Utterance] {
        let url = directory.appending(path: "transcript.json", directoryHint: .notDirectory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let doc = try? decoder.decode(TranscriptDocument.self, from: data)
        else { return [] }
        return doc.utterances
    }
}

struct RecordingItem: Identifiable, Hashable {
    let session: Session
    let directory: URL
    var id: String { session.id }

    static func == (lhs: RecordingItem, rhs: RecordingItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Recordings list

/// Navigation routes within the Recordings tab. Lifted to file scope (and the
/// path binding to `RootView`) so the app-wide record button can push the live
/// screen from any tab.
enum RecordingsRoute: Hashable {
    case live
    case detail(RecordingItem)
}

struct RecordingsView: View {
    let modelHost: ModelHost
    let transcript: TranscriptStore
    let voiceprints: VoiceprintBook
    let controller: CaptureController
    let canStart: Bool
    @Binding var path: [RecordingsRoute]

    @State private var store = RecordingsStore()
    // Drives the row highlight. Without an explicit binding, SwiftUI leaves a
    // pushed NavigationLink's row highlighted after popping back, and the stale
    // highlight swallows the next tap — so we clear it whenever the stack empties.
    @State private var selection: RecordingsRoute?

    var body: some View {
        NavigationStack(path: $path) {
            List(selection: $selection) {
                if controller.isRunning {
                    Section {
                        NavigationLink(value: RecordingsRoute.live) {
                            Label {
                                Text("Recording in progress")
                            } icon: {
                                Image(systemName: "record.circle.fill").foregroundStyle(.red)
                            }
                        }
                    }
                }

                Section {
                    if store.items.isEmpty {
                        Text("No recordings yet. Press Record to start.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.items) { item in
                            NavigationLink(value: RecordingsRoute.detail(item)) {
                                RecordingRow(item: item)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recordings")
            .navigationDestination(for: RecordingsRoute.self) { route in
                switch route {
                case .live:
                    ContentView(
                        modelHost: modelHost,
                        transcript: transcript,
                        voiceprints: voiceprints,
                        controller: controller
                    )
                    .navigationTitle("Recording")
                    .toolbar { ToolbarItem(placement: .primaryAction) { recordButton } }
                case .detail(let item):
                    RecordingDetailView(item: item)
                        .toolbar { ToolbarItem(placement: .primaryAction) { recordButton } }
                }
            }
        }
        .task { store.reload() }
        .onChange(of: path) { _, newPath in
            // Back to the root list — drop the lingering row highlight so the
            // same row can be tapped again immediately.
            if newPath.isEmpty { selection = nil }
        }
        .onChange(of: controller.isRunning) { wasRunning, isRunning in
            // A recording just finished — its session.json is on disk now.
            if wasRunning && !isRunning {
                store.reload()
            }
        }
    }

    // Same control as the app-wide toolbar, re-attached to the pushed live /
    // detail screens (a NavigationStack hides the outer detail toolbar once a
    // destination is pushed). Already inside Recordings, so starting just
    // pushes the live screen.
    private var recordButton: some View {
        RecordButton(controller: controller, canStart: canStart) {
            path = [.live]
        }
    }
}

/// Compact recording summary row. Used by the Recordings list and reused by the
/// Speakers detail panel's per-speaker recording list.
struct RecordingRow: View {
    let item: RecordingItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let duration {
                Text(duration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // Relative, distinct-per-recording timestamp: "Today at 4:30 PM",
    // "Yesterday at 2:15 PM", or "Jun 5, 2026 at 9:00 AM".
    private var timestamp: String {
        Self.timestampFormatter.string(from: item.session.startedAt)
    }

    // When the session has no title (the current default), the timestamp *is*
    // the headline; otherwise it drops to the subtitle.
    private var title: String {
        item.session.title.isEmpty ? timestamp : item.session.title
    }

    private var subtitle: String? {
        item.session.title.isEmpty ? nil : timestamp
    }

    private var duration: String? {
        guard let ended = item.session.endedAt else { return nil }
        return Self.durationFormatter.string(
            from: ended.timeIntervalSince(item.session.startedAt))
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true  // "Today" / "Yesterday"
        return f
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        f.zeroFormattingBehavior = .dropAll
        return f
    }()
}

// MARK: - Recording detail (saved transcript)

private struct RecordingDetailView: View {
    let item: RecordingItem

    @State private var utterances: [Utterance] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded && utterances.isEmpty {
                ContentUnavailableView(
                    "No transcript",
                    systemImage: "text.bubble",
                    description: Text("This recording has no saved transcript. The audio is still on disk.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(utterances) { utterance in
                            SavedUtteranceRow(utterance: utterance)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(title)
        .task(id: item.id) {
            // transcript.json is small; decoding on the main actor is fine.
            utterances = RecordingsStore.loadTranscript(from: item.directory)
            loaded = true
        }
    }

    private var title: String {
        item.session.title.isEmpty
            ? item.session.startedAt.formatted(date: .abbreviated, time: .shortened)
            : item.session.title
    }
}

/// Read-only utterance row for saved transcripts (no speaker-naming popover).
private struct SavedUtteranceRow: View {
    let utterance: Utterance

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(speakerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(speakerColor)
                .frame(width: 80, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(utterance.text)
                    .font(.body)
                    .textSelection(.enabled)
                Text(utterance.startedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var speakerLabel: String {
        switch utterance.speaker {
        case .you: "You"
        case .them: "Them"
        case .remote(let n): "Remote \(n)"
        case .localSpeaker(let n): "Speaker \(n)"
        case .named(let name, _): name
        }
    }

    private var speakerColor: Color {
        switch utterance.source {
        case .mic: .blue
        case .system: .orange
        }
    }
}
