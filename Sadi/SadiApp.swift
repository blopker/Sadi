import SwiftUI

@main
struct SadiApp: App {
    @State private var modelHost = ModelHost()
    @State private var transcript = TranscriptStore()
    @State private var controller: CaptureController

    init() {
        let host = ModelHost()
        let store = TranscriptStore()
        _modelHost = State(initialValue: host)
        _transcript = State(initialValue: store)
        _controller = State(initialValue: CaptureController(modelHost: host, transcript: store))
    }

    var body: some Scene {
        WindowGroup("Sadi", id: "main") {
            ContentView(
                modelHost: modelHost,
                transcript: transcript,
                controller: controller
            )
            .frame(minWidth: 760, minHeight: 480)
            .task {
                await modelHost.loadIfNeeded()
            }
        }
        .windowResizability(.contentSize)
    }
}
