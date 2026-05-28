import SwiftUI

@main
struct SadiApp: App {
    var body: some Scene {
        WindowGroup("Sadi", id: "main") {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentSize)
    }
}
