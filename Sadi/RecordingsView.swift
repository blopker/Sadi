import SadiKit
import SwiftUI

/// Loads finalized recordings from disk (`~/Application Support/Sadi/recordings`).
/// Each session directory carries a `session.json` (metadata) and a
/// `transcript.json` (the utterances); the mp4s are the audio source of truth.
@Observable
@MainActor
final class RecordingsStore {
    private(set) var items: [RecordingItem] = []

    /// Rescan the recordings root. The directory walk + JSON decodes run off
    /// the main actor — cheap on a local SSD, but `Data(contentsOf:)` against
    /// a slow volume must never decide whether the UI beachballs.
    func reload() async {
        items = await Task.detached(priority: .userInitiated) {
            RecordingsStore.scan()
        }.value
    }

    nonisolated private static func scan() -> [RecordingItem] {
        let fm = FileManager.default
        guard let root = try? SessionPaths.recordingsRoot(fileManager: fm),
              let dirs = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            return []
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
        return loaded.sorted { $0.session.startedAt > $1.session.startedAt }
    }

    /// Decode a finalized recording's `transcript.json` into utterances.
    /// `nonisolated` so callers can (and should) run it off the main actor.
    nonisolated static func loadTranscript(from directory: URL) -> [Utterance] {
        loadDocument(from: directory)?.utterances ?? []
    }

    /// Build the `RecordingItem` for a single session directory — used to
    /// deep-link straight to a recording (e.g. the one that just stopped)
    /// without waiting for a full list rescan. `nil` until/unless its
    /// `session.json` is on disk.
    nonisolated static func loadItem(from directory: URL) -> RecordingItem? {
        let url = directory.appending(path: "session.json", directoryHint: .notDirectory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let session = try? decoder.decode(Session.self, from: data)
        else { return nil }
        return RecordingItem(session: session, directory: directory)
    }

    /// Full-document load — for callers that rewrite the transcript (manual
    /// speaker pinning, re-attribution) and must preserve the generator tag.
    nonisolated static func loadDocument(from directory: URL) -> TranscriptDocument? {
        let url = directory.appending(path: "transcript.json", directoryHint: .notDirectory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(TranscriptDocument.self, from: data)
    }

    /// Atomic transcript rewrite, same encoder settings as the live store's
    /// `writeTranscript`.
    nonisolated static func saveDocument(_ doc: TranscriptDocument, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        let url = directory.appending(path: "transcript.json", directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
    }
}

/// Plain value that crosses between the background scan and the UI —
/// `nonisolated` so its `Hashable`/`Identifiable` conformances work anywhere.
nonisolated struct RecordingItem: Identifiable, Hashable, Sendable {
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
    let jobs: TranscriptionJobs
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
                        controller: controller,
                        jobs: jobs
                    )
                    .navigationTitle("Recording")
                    .toolbar { ToolbarItem(placement: .primaryAction) { recordButton } }
                case .detail(let item):
                    RecordingDetailView(
                        item: item,
                        voiceprints: voiceprints,
                        jobs: jobs,
                        isRecording: controller.isRunning
                    )
                    .toolbar { ToolbarItem(placement: .primaryAction) { recordButton } }
                }
            }
        }
        .task { await store.reload() }
        .onChange(of: path) { _, newPath in
            // Back to the root list — drop the lingering row highlight so the
            // same row can be tapped again immediately. Conditional write: on
            // a recording stop the isRunning handler below already cleared it
            // in the same update wave, and writing again would re-trip
            // SwiftUI's multiple-navigation-updates-per-frame warning.
            if newPath.isEmpty, selection != nil { selection = nil }
        }
        .onChange(of: controller.isRunning) { wasRunning, isRunning in
            // A recording just finished — its session.json is on disk now.
            // Clear the selection here too (RootView pops the live screen in
            // this same wave) so the path handler has nothing left to write.
            if wasRunning && !isRunning {
                selection = nil
                Task { await store.reload() }
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
    let voiceprints: VoiceprintBook
    let jobs: TranscriptionJobs
    let isRecording: Bool

    @State private var document: TranscriptDocument?
    @State private var loaded = false

    private var utterances: [Utterance] { document?.utterances ?? [] }
    /// What the list shows: filler-only rows ("Um.") hidden, presentation
    /// only — the document keeps them, and pins still resolve by id.
    private var visibleUtterances: [Utterance] {
        utterances.filter { !FillerWords.isFillerOnly($0.text) }
    }
    /// A finalize/rerun for this session is queued or running — lock edits so
    /// a manual pin can't race the transcript rewrite.
    private var jobBusy: Bool { jobs.isBusy(sessionID: item.session.id) }

    var body: some View {
        Group {
            if loaded && utterances.isEmpty {
                ContentUnavailableView(
                    "No transcript",
                    systemImage: "text.bubble",
                    description: Text(
                        "This recording has no saved transcript. The audio is still on disk — use Rerun Transcription to regenerate it.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleUtterances) { utterance in
                            SavedUtteranceRow(
                                utterance: utterance,
                                voiceprints: voiceprints,
                                locked: jobBusy,
                                onAssign: { speaker in pin(utterance, to: speaker) },
                                onEnroll: { name in enroll(name: name, from: utterance) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(title)
        .safeAreaInset(edge: .top) {
            if let active = jobs.active, active.kind.sessionID == item.session.id {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(bannerLabel(for: active))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if jobBusy {
                    Button {
                        jobs.cancel(sessionID: item.session.id)
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .help("Stop rebuilding this transcript. The current transcript is kept.")
                } else {
                    Button {
                        jobs.enqueueRerun(directory: item.directory)
                    } label: {
                        Label("Rerun Transcription", systemImage: "arrow.trianglehead.2.clockwise")
                    }
                    .help(
                        isRecording
                            ? "Available after the current recording stops."
                            : "Regenerate this transcript from the recorded audio."
                    )
                    .disabled(isRecording || jobs.isRunningModelJob)
                }
            }
        }
        // Reload when a different recording is shown, or when a job touching
        // this (or any — re-attribution uses "*") session finishes.
        .task(id: "\(item.id)|\(jobs.lastCompletedSessionID ?? "")") {
            let directory = item.directory
            document = await Task.detached(priority: .userInitiated) {
                RecordingsStore.loadDocument(from: directory)
            }.value
            loaded = true
        }
    }

    private var title: String {
        item.session.title.isEmpty
            ? item.session.startedAt.formatted(date: .abbreviated, time: .shortened)
            : item.session.title
    }

    private func bannerLabel(for job: TranscriptionJobs.ActiveJob) -> String {
        switch job.kind {
        case .finalize: "Finalizing — \(job.phase)"
        case .rerun: "Rerunning transcription — \(job.phase)"
        case .reattribute: "Updating speaker names…"
        }
    }

    /// Manual pin: the user said "this utterance is this speaker". Writes
    /// `.manual` provenance, which every automated pass must leave alone.
    private func pin(_ utterance: Utterance, to speaker: SadiKit.Speaker) {
        guard let doc = document, !jobBusy else { return }
        var updated = doc.utterances
        guard let idx = updated.firstIndex(where: { $0.id == utterance.id }) else { return }
        updated[idx].speaker = speaker
        updated[idx].assignmentKind = .manual
        let newDoc = TranscriptDocument(
            schemaVersion: 2,
            sessionID: doc.sessionID,
            generator: doc.generator,
            utterances: updated
        )
        document = newDoc
        let directory = item.directory
        Task.detached(priority: .userInitiated) {
            do {
                try RecordingsStore.saveDocument(newDoc, to: directory)
            } catch {
                // Disk write failed; the in-memory pin still shows. The next
                // successful rewrite (another pin, a job) will retry the file.
            }
        }
    }

    /// Enroll a brand-new speaker from this utterance's embedding, pin the
    /// utterance manually, and sweep the name across saved recordings.
    private func enroll(name: String, from utterance: Utterance) {
        guard let embedding = utterance.embedding else { return }
        guard let id = try? voiceprints.enroll(name: name, embedding: embedding) else { return }
        pin(utterance, to: .named(name, id))
        jobs.enqueueReattribution()
    }
}

/// Utterance row for saved transcripts. The speaker label opens an assignment
/// popover (pick an enrolled speaker, or enroll a new one from this
/// utterance's embedding); a pin marks manual assignments.
private struct SavedUtteranceRow: View {
    let utterance: Utterance
    let voiceprints: VoiceprintBook
    let locked: Bool
    let onAssign: (SadiKit.Speaker) -> Void
    let onEnroll: (String) -> Void

    @State private var showingAssignPopover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: { showingAssignPopover = true }) {
                HStack(spacing: 3) {
                    if utterance.assignmentKind == .manual {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    Text(speakerLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(speakerColor)
                }
                .frame(width: 80, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .disabled(locked)
            .help(locked ? "Editing is locked while this transcript is being rebuilt." : "Click to assign this line to a speaker")
            .popover(isPresented: $showingAssignPopover) {
                AssignSpeakerPopover(
                    utterance: utterance,
                    voiceprints: voiceprints,
                    onAssign: onAssign,
                    onEnroll: onEnroll
                )
            }
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

/// Saved-transcript counterpart of the live screen's NameSpeakerPopover.
/// Assigning an existing speaker is a pure manual pin (no enrollment — the
/// voiceprint already exists); a new name enrolls from this utterance's
/// embedding first.
private struct AssignSpeakerPopover: View {
    let utterance: Utterance
    let voiceprints: VoiceprintBook
    let onAssign: (SadiKit.Speaker) -> Void
    let onEnroll: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign speaker")
                .font(.headline)

            if !voiceprints.prints.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(voiceprints.prints.sorted(by: {
                            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                        })) { vp in
                            Button {
                                onAssign(.named(vp.name, vp.id))
                                dismiss()
                            } label: {
                                Label(vp.name, systemImage: "person.crop.circle")
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 120)
                Divider()
            }

            Text("Or enroll a new speaker from this line:")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
                .disabled(utterance.embedding == nil)
            if utterance.embedding == nil {
                Text("This line has no voice embedding; pick an existing speaker instead.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Enroll & Assign") { submit() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        name.trimmingCharacters(in: .whitespaces).isEmpty
                            || utterance.embedding == nil)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, utterance.embedding != nil else { return }
        onEnroll(trimmed)
        dismiss()
    }
}
