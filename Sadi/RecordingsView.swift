import AppKit
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
        TranscriptDocument.load(from: directory)?.utterances ?? []
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
    /// The optional LLM-cleaned copy (`transcript.cleaned.json`), loaded
    /// alongside the raw one; `nil` when the cleanup pass hasn't run.
    @State private var cleanedDocument: TranscriptDocument?
    /// Whether the list is showing the cleaned copy rather than the original.
    @State private var showCleaned = false
    /// The cleaned copy was built from an earlier version of the raw transcript
    /// (a later rerun changed the words) — surfaces a "rerun to refresh" badge.
    @State private var cleanupStale = false
    @State private var loaded = false

    private var utterances: [Utterance] { document?.utterances ?? [] }
    /// Whether there's a cleaned copy to toggle to.
    private var cleanupAvailable: Bool { cleanedDocument != nil }
    /// What the list shows: the cleaned copy when toggled on (and present),
    /// otherwise the raw transcript; filler-only rows ("Um.") hidden either way.
    ///
    /// The cleaned doc is a text snapshot, but speaker assignments live on the
    /// raw doc (manual re-pins update it). So when showing the cleaned copy we
    /// overlay the current speaker/provenance by id, keeping a re-pin made while
    /// viewing the original reflected here too.
    private var visibleUtterances: [Utterance] {
        guard showCleaned, let cleaned = cleanedDocument else {
            return utterances.filter { !FillerWords.isFillerOnly($0.text) }
        }
        let raw = Dictionary(
            (document?.utterances ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return cleaned.utterances
            .filter { !FillerWords.isFillerOnly($0.text) }
            .map { u in
                guard let r = raw[u.id] else { return u }
                var copy = u
                copy.speaker = r.speaker
                copy.assignmentKind = r.assignmentKind
                return copy
            }
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
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(TranscriptBlock.group(visibleUtterances)) { block in
                            TranscriptBlockView(
                                block: block,
                                voiceprints: voiceprints,
                                locked: jobBusy || showCleaned,
                                onAssign: { ids, speaker in pin(ids, to: speaker) },
                                onEnroll: { name, representative, ids in
                                    enroll(name: name, from: representative, ids: ids)
                                }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(title)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
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
                if cleanupStale {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Cleaned transcript is out of date — rerun to refresh it.")
                        Spacer()
                    }
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showCleaned) {
                    Label("Cleaned", systemImage: "sparkles")
                }
                .toggleStyle(.button)
                .disabled(!cleanupAvailable)
                .help(
                    cleanupAvailable
                        ? "Switch between the original transcript and the AI-cleaned version."
                        : "No cleaned transcript yet — connect an LLM server, then finalize or rerun."
                )
            }
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
            let (doc, cleaned, stale) = await Task.detached(priority: .userInitiated) {
                let doc = TranscriptDocument.load(from: directory)
                let cleaned = TranscriptDocument.load(
                    from: directory, filename: TranscriptDocument.cleanedFilename)
                // Cleaned is stale if it was built from a different raw transcript.
                let stale: Bool
                if let doc, let cleaned {
                    stale = cleaned.sourceHash != TranscriptDocument.contentHash(doc.utterances)
                } else {
                    stale = false
                }
                return (doc, cleaned, stale)
            }.value
            document = doc
            cleanedDocument = cleaned
            cleanupStale = stale
            if cleaned == nil { showCleaned = false }
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

    /// Manual pin: the user said "these utterances are this speaker" — one
    /// segment (click on its text) or a whole coalesced block (click on the
    /// label). Writes `.manual` provenance, which every automated pass must
    /// leave alone; one atomic persist for the whole group.
    @discardableResult
    private func pin(_ ids: Set<UUID>, to speaker: SadiKit.Speaker) -> Task<Void, Never>? {
        guard let doc = document, !jobBusy, !ids.isEmpty else { return nil }
        guard let newDoc = Self.pinnedDocument(doc, ids: ids, to: speaker) else { return nil }
        document = newDoc
        let directory = item.directory
        return Task(priority: .userInitiated) {
            do {
                // The coordinator re-applies the pin to the latest on-disk
                // document; reflect the merged result back so memory matches
                // what was persisted (disk may have moved under us).
                if let merged = try await TranscriptDocumentFileCoordinator.shared.update(
                    directory: directory,
                    { latest in Self.pinnedDocument(latest, ids: ids, to: speaker) })
                {
                    document = merged
                }
            } catch {
                // Disk write failed; the in-memory pin still shows. The next
                // successful rewrite (another pin, a job) will retry the file.
            }
        }
    }

    nonisolated private static func pinnedDocument(
        _ doc: TranscriptDocument, ids: Set<UUID>, to speaker: SadiKit.Speaker
    ) -> TranscriptDocument? {
        var updated = doc.utterances
        var any = false
        for idx in updated.indices where ids.contains(updated[idx].id) {
            updated[idx].speaker = speaker
            updated[idx].assignmentKind = .manual
            any = true
        }
        guard any else { return nil }
        return doc.replacingUtterances(updated)
    }

    /// Enroll a brand-new speaker from a representative utterance's
    /// embedding, pin the given utterances manually, and sweep the name
    /// across saved recordings.
    private func enroll(name: String, from representative: Utterance, ids: Set<UUID>) {
        guard let embedding = representative.embedding else { return }
        guard let id = try? voiceprints.enroll(name: name, embedding: embedding) else { return }
        if let pinSave = pin(ids, to: .named(name, id)) {
            Task {
                await pinSave.value
                jobs.enqueueReattribution()
            }
        } else {
            jobs.enqueueReattribution()
        }
    }
}

// MARK: - Coalesced transcript blocks

/// A consecutive run of same-speaker utterances, presented as one block with
/// a single label. Presentation-only — the document keeps every utterance, so
/// per-segment reclassification (and every later pass) still works on ids.
/// Within a block, a pause of `paragraphGap` or more starts a new paragraph,
/// so a long monologue reads as paragraphs without repeating the label.
private struct TranscriptBlock: Identifiable {
    let id: UUID  // first utterance's id — stable across re-renders
    let source: Source
    let speaker: SadiKit.Speaker
    let anyManual: Bool
    let startedAt: Date
    let paragraphs: [[Utterance]]

    var utteranceIDs: Set<UUID> { Set(paragraphs.flatMap { $0.map(\.id) }) }
    var count: Int { paragraphs.reduce(0) { $0 + $1.count } }
    /// The block's full text, paragraphs separated by blank lines — what
    /// "Copy Group" puts on the pasteboard.
    var text: String {
        paragraphs
            .map { $0.map(\.text).joined(separator: " ") }
            .joined(separator: "\n\n")
    }

    /// Best utterance to enroll a new voiceprint from: prefer an embedding
    /// computed over the segment's own audio (not the ambiguous fallback).
    var enrollRepresentative: Utterance? {
        let all = paragraphs.flatMap { $0 }
        return all.first { $0.embedding != nil && $0.embeddingAmbiguous != true }
            ?? all.first { $0.embedding != nil }
    }

    static func group(
        _ utterances: [Utterance], paragraphGap: TimeInterval = 3
    ) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var current: [Utterance] = []

        func flush() {
            guard let first = current.first else { return }
            var paragraphs: [[Utterance]] = []
            var paragraph: [Utterance] = []
            var previousEnd: Date?
            for u in current {
                if let previousEnd, !paragraph.isEmpty,
                    u.startedAt.timeIntervalSince(previousEnd) >= paragraphGap {
                    paragraphs.append(paragraph)
                    paragraph = []
                }
                paragraph.append(u)
                previousEnd = u.endedAt
            }
            if !paragraph.isEmpty { paragraphs.append(paragraph) }
            blocks.append(
                TranscriptBlock(
                    id: first.id,
                    source: first.source,
                    speaker: first.speaker,
                    anyManual: current.contains { $0.assignmentKind == .manual },
                    startedAt: first.startedAt,
                    paragraphs: paragraphs
                ))
            current = []
        }

        for u in utterances {
            if let last = current.last, last.source == u.source, last.speaker == u.speaker {
                current.append(u)
            } else {
                flush()
                current = [u]
            }
        }
        flush()
        return blocks
    }
}

/// One coalesced block: the label column (click = reassign the whole group)
/// next to flowing paragraphs of segment chips (hover = highlight one
/// segment's extent, click = reassign just that segment).
private struct TranscriptBlockView: View {
    let block: TranscriptBlock
    let voiceprints: VoiceprintBook
    let locked: Bool
    let onAssign: (Set<UUID>, SadiKit.Speaker) -> Void
    let onEnroll: (String, Utterance, Set<UUID>) -> Void

    @State private var showingGroupPopover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Button(action: { showingGroupPopover = true }) {
                    HStack(spacing: 3) {
                        if block.anyManual {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        Text(speakerLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(speakerColor)
                    }
                }
                .buttonStyle(.plain)
                .disabled(locked)
                .help(
                    locked
                        ? "Editing is locked while this transcript is being rebuilt."
                        : "Click to assign all \(block.count) segment\(block.count == 1 ? "" : "s") in this group"
                )
                .popover(isPresented: $showingGroupPopover) {
                    if let representative = block.enrollRepresentative ?? block.paragraphs.first?.first {
                        AssignSpeakerPopover(
                            utterance: representative,
                            voiceprints: voiceprints,
                            scope: block.count > 1 ? "Applies to all \(block.count) segments in this group." : nil,
                            onAssign: { onAssign(block.utteranceIDs, $0) },
                            onEnroll: { onEnroll($0, representative, block.utteranceIDs) }
                        )
                    }
                }
                Text(block.startedAt.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 80, alignment: .trailing)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(block.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    SegmentFlow(spacing: 3) {
                        ForEach(paragraph) { segment in
                            SegmentChip(
                                utterance: segment,
                                groupText: block.text,
                                voiceprints: voiceprints,
                                locked: locked,
                                onAssign: { onAssign([segment.id], $0) },
                                onEnroll: { onEnroll($0, segment, [segment.id]) }
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var speakerLabel: String {
        switch block.speaker {
        case .you: "You"
        case .them: "Them"
        case .remote(let n): "Remote \(n)"
        case .localSpeaker(let n): "Speaker \(n)"
        case .named(let name, _): name
        }
    }

    private var speakerColor: Color {
        switch block.source {
        case .mic: .blue
        case .system: .orange
        }
    }
}

/// One segment inside a block: plain body text that flows with its siblings,
/// but reveals its own extent on hover and reassigns on click.
///
/// A real `Button` rather than Text + onTapGesture: `.textSelection` installs
/// a selection layer that swallows mouse-downs, making tap gestures fire only
/// sometimes. Clicks are the primary interaction here, so copying moves to
/// the right-click menu instead of drag-selection.
private struct SegmentChip: View {
    let utterance: Utterance
    let groupText: String
    let voiceprints: VoiceprintBook
    let locked: Bool
    let onAssign: (SadiKit.Speaker) -> Void
    let onEnroll: (String) -> Void

    @State private var hovered = false
    @State private var showingPopover = false

    var body: some View {
        Button {
            if !locked { showingPopover = true }
        } label: {
            Text(utterance.text)
                .font(.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .background(
                    hovered && !locked ? Color.accentColor.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(
            "\(utterance.startedAt.formatted(date: .omitted, time: .standard))"
                + (locked ? "" : " — click to reassign this segment")
        )
        .contextMenu {
            Button("Copy Segment") { copy(utterance.text) }
            Button("Copy Group") { copy(groupText) }
        }
        .popover(isPresented: $showingPopover) {
            AssignSpeakerPopover(
                utterance: utterance,
                voiceprints: voiceprints,
                scope: "Applies to this segment only.",
                onAssign: onAssign,
                onEnroll: onEnroll
            )
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Canvas check for the coalescing layout: short fragments flowing into one
/// line, a paragraph break after a >3 s pause, and a second speaker block.
#Preview("Coalesced blocks") {
    let base = Date()
    func u(_ text: String, _ start: TimeInterval, _ end: TimeInterval, source: Source = .mic, speaker: SadiKit.Speaker = .you) -> Utterance {
        Utterance(
            source: source, speaker: speaker, text: text,
            startedAt: base.addingTimeInterval(start), endedAt: base.addingTimeInterval(end))
    }
    let utterances = [
        u("So I was thinking", 0, 1.2),
        u("maybe we should", 1.8, 2.6),
        u("try the other approach first.", 3.0, 4.8),
        u("Because honestly the current one has been flaky for weeks and nobody really understands why it breaks.", 9, 16),
        u("Yeah, that makes sense to me.", 17, 19, source: .system, speaker: .named("Vanessa", UUID())),
        u("Okay, I'll write it up.", 20, 22),
    ]
    let book = VoiceprintBook(
        storeURL: FileManager.default.temporaryDirectory.appending(path: "preview-book.json"),
        modelVersion: "preview")
    return ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(TranscriptBlock.group(utterances)) { block in
                TranscriptBlockView(
                    block: block, voiceprints: book, locked: false,
                    onAssign: { _, _ in }, onEnroll: { _, _, _ in }
                )
            }
        }
        .padding(16)
    }
    .frame(width: 560, height: 320)
}

/// Minimal flow layout: lays subviews left-to-right, wrapping at the
/// container edge. Each subview is proposed the full container width, so a
/// short segment flows inline while a long one wraps internally and takes
/// its own rows — paragraphs read as prose, not as a list.
private struct SegmentFlow: Layout {
    var spacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
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
    /// Optional scope note ("Applies to all 5 segments in this group.") so a
    /// group assign and a single-segment assign are distinguishable.
    var scope: String?
    let onAssign: (SadiKit.Speaker) -> Void
    let onEnroll: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign speaker")
                .font(.headline)
            if let scope {
                Text(scope)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
