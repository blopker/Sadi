import Foundation
import SadiKit
import SwiftUI

@main
struct SadiApp: App {
    @State private var modelHost: ModelHost
    @State private var voiceprints: VoiceprintBook
    @State private var transcript: TranscriptStore
    @State private var controller: CaptureController

    init() {
        let host = ModelHost()
        let bookURL = SadiApp.voiceprintBookURL()
        let book = VoiceprintBook(
            storeURL: bookURL,
            modelVersion: ModelHost.embeddingModelVersion
        )
        let store = TranscriptStore(voiceprints: book)
        _modelHost = State(initialValue: host)
        _voiceprints = State(initialValue: book)
        _transcript = State(initialValue: store)
        _controller = State(initialValue: CaptureController(modelHost: host, transcript: store))
    }

    var body: some Scene {
        WindowGroup("Sadi", id: "main") {
            ContentView(
                modelHost: modelHost,
                transcript: transcript,
                voiceprints: voiceprints,
                controller: controller
            )
            .frame(minWidth: 760, minHeight: 480)
            .task {
                await modelHost.loadIfNeeded()
            }
        }
        .windowResizability(.contentSize)
    }

    private static func voiceprintBookURL() -> URL {
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let base = support ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appending(path: "Sadi/Voiceprints/book.json", directoryHint: .notDirectory)
    }
}
