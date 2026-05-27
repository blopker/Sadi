import SwiftUI

@main
struct SadiApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        WindowGroup("Sadi", id: "main") {
            ContentView()
                .environmentObject(controller)
                .frame(minWidth: 760, minHeight: 480)
                .task {
                    // Download / load transcription models once at launch.
                    await controller.prepareModels()
                }
        }
        .windowResizability(.contentSize)

        // Menu bar item for quick start/stop without opening the window.
        MenuBarExtra("Sadi", systemImage: menuBarIcon) {
            MenuBarView()
                .environmentObject(controller)
        }
    }

    private var menuBarIcon: String {
        controller.status == .recording ? "record.circle.fill" : "record.circle"
    }
}

/// Compact controls shown from the menu bar.
struct MenuBarView: View {
    @EnvironmentObject private var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.status.label)

        Button(controller.status == .recording ? "Stop Recording" : "Start Recording") {
            controller.toggleRecording()
        }
        .disabled(controller.status.isBusy || !controller.modelsReady)
        .keyboardShortcut("r", modifiers: [.command, .option])

        Divider()

        Button("Open Sadi") {
            openWindow(id: "main")
        }

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
