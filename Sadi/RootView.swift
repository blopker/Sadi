import AVFoundation
import SadiKit
import SwiftUI

/// Top-level sidebar navigation. `Recordings` hosts the live capture +
/// transcript UI (`ContentView`); `Speakers` and `Settings` are early mocks
/// wired to real data where it's cheap to do so. The record/stop control lives
/// here (not in `RecordingsView`) so it's available from every tab.
struct RootView: View {
    let modelHost: ModelHost
    let transcript: TranscriptStore
    let voiceprints: VoiceprintBook
    let controller: CaptureController

    @State private var selection: SidebarItem = .recordings
    // The Recordings tab's nav path lives here so the app-wide record button
    // can switch to Recordings and push the live screen from any tab.
    @State private var recordingsPath: [RecordingsRoute] = []
    @State private var micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)

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
            detailColumn
                // Attach the record button to the detail column (not the split
                // view) so the toolbar is associated with the detail side only
                // — keeping the sidebar's material clean to the top.
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        RecordButton(controller: controller, canStart: canStart) {
                            selection = .recordings
                            recordingsPath = [.live]
                        }
                        .keyboardShortcut("r", modifiers: .command)
                    }
                }
        }
        .task {
            if micAuthorization == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
        .onChange(of: controller.isRunning) { _, isRunning in
            // When a recording stops from any tab, pop the live screen.
            if !isRunning { recordingsPath.removeAll() }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch selection {
        case .recordings:
            RecordingsView(
                modelHost: modelHost,
                transcript: transcript,
                voiceprints: voiceprints,
                controller: controller,
                canStart: canStart,
                path: $recordingsPath
            )
        case .speakers:
            SpeakersView(voiceprints: voiceprints) { item in
                // Reuse the Recordings tab's stack to show the detail: switch
                // tabs and push the recording so the same screen/back-stack
                // serves both entry points.
                selection = .recordings
                recordingsPath = [.detail(item)]
            }
        case .settings:
            SettingsView(modelHost: modelHost)
        }
    }

    private var canStart: Bool {
        micAuthorization == .authorized && modelHost.state == .ready
    }
}

/// The single record/stop control, shared by the app-wide toolbar and the
/// pushed live/detail screens inside the Recordings stack so it shows
/// everywhere. Starting calls `onStart` (which navigates to the live screen);
/// stopping is self-contained. `.titleAndIcon` keeps the label visible.
struct RecordButton: View {
    let controller: CaptureController
    let canStart: Bool
    let onStart: () -> Void

    var body: some View {
        if controller.isRunning {
            Button {
                Task { await controller.stop() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .tint(.red)
            .labelStyle(.titleAndIcon)
        } else {
            Button {
                controller.start()
                onStart()
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .disabled(!canStart)
            .labelStyle(.titleAndIcon)
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

// MARK: - Settings (mock)

/// Placeholder settings. Toggles persist to `@AppStorage` so the mock at least
/// remembers itself; none are wired into the pipeline yet.
private struct SettingsView: View {
    let modelHost: ModelHost

    @AppStorage("settings.showDroppedByDefault") private var showDroppedByDefault = false
    @AppStorage("settings.launchAtLogin") private var launchAtLogin = false
    @AppStorage("settings.playChimeOnStop") private var playChimeOnStop = false
    @AppStorage(AutoStopSettings.enabledKey) private var autoStopEnabled = false
    @AppStorage(AutoStopSettings.minutesKey) private var autoStopMinutes = AutoStopSettings
        .defaultMinutes

    var body: some View {
        Form {
            Section("Transcription") {
                Toggle("Show echo-filtered utterances by default", isOn: $showDroppedByDefault)
                Toggle("Play a chime when a recording stops", isOn: $playChimeOnStop)
            }

            Section {
                Toggle("Auto-stop when idle", isOn: $autoStopEnabled)
                if autoStopEnabled {
                    Picker("Stop after a silence of", selection: $autoStopMinutes) {
                        ForEach(AutoStopSettings.presetMinutes, id: \.self) { minutes in
                            Text("\(minutes) minute\(minutes == 1 ? "" : "s")").tag(minutes)
                        }
                    }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Auto stop the recording if a long silence is detected.")
            }
            .onChange(of: autoStopEnabled) { _, enabled in
                // Tie the notification permission prompt to turning the feature
                // on, rather than nagging everyone at launch.
                if enabled { RecordingNotifier.requestAuthorization() }
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
