import SadiKit
import SwiftUI

// MARK: - Presentation model

/// Everything the Speakers UI needs about one speaker, flattened into a plain
/// value. This is the seam between the view and the data layer: the views below
/// render `SpeakerSummary` and never touch `Voiceprint`/`RecordingsStore`
/// directly, so the data pass can rewrite `SpeakersModel`'s internals (or back
/// it with a different store) without disturbing the UI.
struct SpeakerSummary: Identifiable {
    let id: UUID
    let name: String
    let sampleCount: Int
    let enrolledAt: Date
    /// Recordings this speaker appears in, newest first.
    let recordings: [RecordingItem]
}

/// View-model for the Speakers screen. Owns the (currently file-scanning) data
/// access and exposes a sorted `[SpeakerSummary]`. Swap the body of `reload()`
/// when the real query layer lands; the view stays put.
@Observable
@MainActor
final class SpeakersModel {
    private(set) var speakers: [SpeakerSummary] = []

    private let voiceprints: VoiceprintBook
    private let store = RecordingsStore()

    init(voiceprints: VoiceprintBook) {
        self.voiceprints = voiceprints
    }

    /// Rescan recordings, rebuild the speaker → recordings index, and project
    /// each enrolled voiceprint into a `SpeakerSummary`.
    ///
    /// "Which recordings is a speaker in?" is derived from each session's saved
    /// `transcript.json`: utterances resolved to a voiceprint carry
    /// `.named(name, voiceprintID)`. (Session-level `speakerClusters` aren't
    /// populated by the live pipeline yet — see `SpeakerCluster`.)
    func reload() {
        store.reload()
        var index: [UUID: [RecordingItem]] = [:]
        for item in store.items {
            let ids = Set(RecordingsStore.loadTranscript(from: item.directory).compactMap { utterance -> UUID? in
                if case .named(_, let voiceprintID) = utterance.speaker { return voiceprintID }
                return nil
            })
            for id in ids { index[id, default: []].append(item) }
        }
        // store.items is already newest-first, so each bucket inherits that order.
        speakers = voiceprints.prints
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { vp in
                SpeakerSummary(
                    id: vp.id,
                    name: vp.name,
                    sampleCount: vp.sampleCount,
                    enrolledAt: vp.createdAt,
                    recordings: index[vp.id] ?? []
                )
            }
    }

    func delete(id: UUID) {
        try? voiceprints.delete(id: id)
        reload()
    }
}

// MARK: - Speakers (two-panel: list + detail)

/// Two-panel speaker browser. The left column is a fixed-width, selectable list
/// of enrolled speakers; the right column shows the selected speaker's card
/// (stats) and the recordings they appear in. Selecting a recording hands it
/// back to the host (`onOpenRecording`) which pushes it in the Recordings stack.
struct SpeakersView: View {
    /// Open a recording in the Recordings tab's detail screen.
    let onOpenRecording: (RecordingItem) -> Void

    @State private var model: SpeakersModel
    @State private var selectedID: SpeakerSummary.ID?

    init(voiceprints: VoiceprintBook, onOpenRecording: @escaping (RecordingItem) -> Void) {
        self.onOpenRecording = onOpenRecording
        _model = State(initialValue: SpeakersModel(voiceprints: voiceprints))
    }

    var body: some View {
        Group {
            if model.speakers.isEmpty {
                ContentUnavailableView(
                    "No speakers yet",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Name a speaker in a transcript to enroll their voiceprint.")
                )
            } else {
                HStack(spacing: 0) {
                    speakerList
                        .frame(width: 260)
                    Divider()
                    detail
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Speakers")
        .task {
            model.reload()
            selectCurrentOrFirst()
        }
    }

    private var speakerList: some View {
        List(selection: $selectedID) {
            ForEach(model.speakers) { speaker in
                SpeakerRow(speaker: speaker)
                    .tag(speaker.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) {
                            model.delete(id: speaker.id)
                            selectCurrentOrFirst()
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        // Drop the sidebar list's vibrancy material so the column inherits the
        // window's content background — matching the detail panel's darker gray.
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let speaker = model.speakers.first(where: { $0.id == id }) {
            SpeakerDetailView(speaker: speaker, onOpenRecording: onOpenRecording)
        } else {
            ContentUnavailableView(
                "Select a speaker",
                systemImage: "person.crop.circle",
                description: Text("Choose a speaker on the left to see their recordings.")
            )
        }
    }

    /// Keep a valid selection: default to the first speaker, and recover if the
    /// selected speaker was just deleted.
    private func selectCurrentOrFirst() {
        if selectedID == nil || !model.speakers.contains(where: { $0.id == selectedID }) {
            selectedID = model.speakers.first?.id
        }
    }
}

/// Left-column row: avatar, name, and a one-line recording summary.
private struct SpeakerRow: View {
    let speaker: SpeakerSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(speaker.name)
                    .font(.headline)
                Text("\(speaker.recordings.count) recording\(speaker.recordings.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Speaker detail

/// Right-column detail: a stats card over the list of recordings the speaker
/// appears in. Rows are buttons that open the recording's detail screen.
private struct SpeakerDetailView: View {
    let speaker: SpeakerSummary
    let onOpenRecording: (RecordingItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SpeakerCard(speaker: speaker)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recordings")
                        .font(.headline)

                    if speaker.recordings.isEmpty {
                        Text("This speaker hasn't appeared in any saved recordings yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(speaker.recordings) { item in
                                Button {
                                    onOpenRecording(item)
                                } label: {
                                    HStack {
                                        RecordingRow(item: item)
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 12)

                                if item.id != speaker.recordings.last?.id {
                                    Divider().padding(.leading, 12)
                                }
                            }
                        }
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Header card: large avatar, name, and at-a-glance stats.
private struct SpeakerCard: View {
    let speaker: SpeakerSummary

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 8) {
                Text(speaker.name)
                    .font(.title2.bold())
                HStack(spacing: 24) {
                    Stat(value: "\(speaker.recordings.count)", label: speaker.recordings.count == 1 ? "Recording" : "Recordings")
                    Stat(value: "\(speaker.sampleCount)", label: speaker.sampleCount == 1 ? "Sample" : "Samples")
                }
                Text("Enrolled \(speaker.enrolledAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A single labeled metric in the speaker card.
private struct Stat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
