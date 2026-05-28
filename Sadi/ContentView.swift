import AVFoundation
import SwiftUI

struct ContentView: View {
    @State private var micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var controller = CaptureController()

    var body: some View {
        VStack(spacing: 20) {
            Text("Sadi — Phase 2 capture meters")
                .font(.title2)

            Text(permissionLabel)
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                Button(controller.isRunning ? "Stop" : "Start") {
                    if controller.isRunning {
                        Task { await controller.stop() }
                    } else {
                        controller.start()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(micAuthorization != .authorized)
            }

            if !controller.sessionID.isEmpty {
                Text("Session: \(controller.sessionID)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GroupBox("Mic") {
                MeterRow(level: controller.micLevel, status: controller.micStatus)
            }

            GroupBox("System audio") {
                MeterRow(level: controller.systemLevel, status: controller.systemStatus)
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if micAuthorization == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    private var permissionLabel: String {
        switch micAuthorization {
        case .authorized: "Mic access: granted"
        case .denied: "Mic access: denied — enable in System Settings"
        case .restricted: "Mic access: restricted"
        case .notDetermined: "Mic access: not yet requested"
        @unknown default: "Mic access: unknown"
        }
    }
}

private struct MeterRow: View {
    let level: Float
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(min(max(level * 4, 0), 1)))
                .progressViewStyle(.linear)
            HStack {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "RMS %.4f", level))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }
}
