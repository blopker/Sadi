import AppKit
import Foundation
import OSLog
import SadiKit
import SwiftUI

/// Single binary, two faces. `Sadi cli …` runs the transcription pipeline
/// headless (see `SadiCLI`); anything else launches the SwiftUI app. The CLI
/// branch never touches AppKit, so no window or Dock icon appears.
@main
struct AppEntry {
    static func main() async {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "cli" {
            let code = await SadiCLI.run(arguments: Array(args.dropFirst(2)))
            exit(code)
        }
        SadiApp.main()
    }
}

/// Intercepts app termination (⌘Q, menu Quit, logout) so a recording in
/// progress is finalized like a normal Stop — MP4s flushed, then transcript
/// written — before the process exits. A force-quit or crash bypasses this;
/// the fragmented MP4s remain re-derivable in that case.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: CaptureController?

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "lifecycle")

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.isRunning else { return .terminateNow }
        // Defer termination, run the same stop path the UI button uses, then
        // let AppKit finish quitting once everything is on disk.
        Task {
            Self.log.notice("Quit while recording — finalizing session before exit")
            await controller.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

struct SadiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
            RootView(
                modelHost: modelHost,
                transcript: transcript,
                voiceprints: voiceprints,
                controller: controller
            )
            .frame(minWidth: 900, minHeight: 520)
            .task {
                appDelegate.controller = controller
                await modelHost.loadIfNeeded()
            }
        }
        .windowResizability(.contentSize)
    }

    static func voiceprintBookURL() -> URL {
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
