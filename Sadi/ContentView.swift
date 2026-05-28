import AVFoundation
import SwiftUI

struct ContentView: View {
    @State private var micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(spacing: 16) {
            Text("Sadi")
                .font(.largeTitle)
            Text(statusLabel)
                .foregroundStyle(.secondary)
            if micAuthorization == .notDetermined {
                Button("Grant Microphone Access") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if micAuthorization == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    private var statusLabel: String {
        switch micAuthorization {
        case .authorized: "Microphone access: granted"
        case .denied: "Microphone access: denied — enable in System Settings"
        case .restricted: "Microphone access: restricted"
        case .notDetermined: "Microphone access: not yet requested"
        @unknown default: "Microphone access: unknown"
        }
    }
}
