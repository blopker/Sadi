import SadiKit
import SwiftUI

/// Top-level sidebar navigation. `Recordings` hosts the live capture +
/// transcript UI (`ContentView`); `Speakers` and `Settings` are early mocks
/// wired to real data where it's cheap to do so.
struct RootView: View {
    let modelHost: ModelHost
    let transcript: TranscriptStore
    let voiceprints: VoiceprintBook
    let controller: CaptureController

    @State private var selection: SidebarItem = .recordings

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                NavigationLink(value: item) {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .listStyle(.sidebar)
        } detail: {
            switch selection {
            case .recordings:
                RecordingsView(
                    modelHost: modelHost,
                    transcript: transcript,
                    voiceprints: voiceprints,
                    controller: controller
                )
            case .speakers:
                SpeakersView(voiceprints: voiceprints)
            case .settings:
                SettingsView(modelHost: modelHost)
            }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case recordings
    case speakers
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recordings: "Recordings"
        case .speakers: "Speakers"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .recordings: "waveform"
        case .speakers: "person.2"
        case .settings: "gearshape"
        }
    }
}

// MARK: - Speakers (mock, real voiceprint data)

/// Lists enrolled voiceprints. Real data from `VoiceprintBook`; delete is wired
/// up, the rest (merge, re-record, listen) is future work.
private struct SpeakersView: View {
    let voiceprints: VoiceprintBook

    var body: some View {
        Group {
            if voiceprints.prints.isEmpty {
                ContentUnavailableView(
                    "No speakers yet",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Name a speaker in a transcript to enroll their voiceprint.")
                )
            } else {
                List {
                    ForEach(voiceprints.prints.sorted(by: { $0.name < $1.name })) { print in
                        SpeakerRow(voiceprint: print)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    try? voiceprints.delete(id: print.id)
                                }
                            }
                    }
                }
            }
        }
        .navigationTitle("Speakers")
    }
}

private struct SpeakerRow: View {
    let voiceprint: Voiceprint

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(voiceprint.name)
                    .font(.headline)
                Text("\(voiceprint.sampleCount) sample\(voiceprint.sampleCount == 1 ? "" : "s") · enrolled \(voiceprint.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings (mock)

/// Placeholder settings. Toggles persist to `@AppStorage` so the mock at least
/// remembers itself; none are wired into the pipeline yet.
private struct SettingsView: View {
    let modelHost: ModelHost

    @AppStorage("settings.showDroppedByDefault") private var showDroppedByDefault = false
    @AppStorage("settings.launchAtLogin") private var launchAtLogin = false
    @AppStorage("settings.playChimeOnStop") private var playChimeOnStop = false

    var body: some View {
        Form {
            Section("Transcription") {
                Toggle("Show echo-filtered utterances by default", isOn: $showDroppedByDefault)
                Toggle("Play a chime when a recording stops", isOn: $playChimeOnStop)
            }

            Section("General") {
                Toggle("Launch Sadi at login", isOn: $launchAtLogin)
            }

            Section("Models") {
                LabeledContent("Status") {
                    modelStatusText
                }
                LabeledContent("Embedding version", value: ModelHost.embeddingModelVersion)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private var modelStatusText: some View {
        switch modelHost.state {
        case .idle:
            Text("Idle").foregroundStyle(.secondary)
        case .loading(_, let phase):
            Text(phase).foregroundStyle(.secondary)
        case .ready:
            Text("Ready").foregroundStyle(.green)
        case .failed(let msg):
            Text(msg).foregroundStyle(.red)
        }
    }
}
