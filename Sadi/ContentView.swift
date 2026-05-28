import AVFoundation
import SadiKit
import SwiftUI

struct ContentView: View {
    let modelHost: ModelHost
    let transcript: TranscriptStore
    let controller: CaptureController

    @State private var micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)

    var body: some View {
        VStack(spacing: 16) {
            header

            HStack(alignment: .top, spacing: 16) {
                metersColumn
                    .frame(width: 320)
                TranscriptList(utterances: transcript.utterances)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if micAuthorization == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Sadi").font(.title2)
            Spacer()
            modelStatusView
            Button(controller.isRunning ? "Stop" : "Start") {
                if controller.isRunning {
                    Task { await controller.stop() }
                } else {
                    controller.start()
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!canStart)
        }
    }

    private var canStart: Bool {
        if controller.isRunning { return true }
        return micAuthorization == .authorized && modelHost.state == .ready
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch modelHost.state {
        case .idle:
            Text("Models: idle").foregroundStyle(.secondary).font(.caption)
        case .loading(let f, let phase):
            HStack(spacing: 6) {
                ProgressView(value: f).controlSize(.small).frame(width: 80)
                Text(phase).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        case .ready:
            Text("Models: ready").foregroundStyle(.green).font(.caption)
        case .failed(let msg):
            Text("Models failed: \(msg)").foregroundStyle(.red).font(.caption).lineLimit(2)
        }
    }

    private var metersColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !controller.sessionID.isEmpty {
                Text("Session: \(controller.sessionID)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(permissionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            GroupBox("Mic") {
                MeterRow(level: controller.micLevel, status: controller.micStatus)
            }
            GroupBox("System audio") {
                MeterRow(level: controller.systemLevel, status: controller.systemStatus)
            }
            Spacer()
        }
    }

    private var permissionLabel: String {
        switch micAuthorization {
        case .authorized: "Mic access: granted"
        case .denied: "Mic access: denied — System Settings"
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

private struct TranscriptList: View {
    let utterances: [Utterance]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if utterances.isEmpty {
                        ContentUnavailableView(
                            "No transcripts yet",
                            systemImage: "text.bubble",
                            description: Text("Press Start, then speak or play audio.")
                        )
                        .padding(.top, 60)
                    } else {
                        ForEach(utterances) { utt in
                            UtteranceRow(utterance: utt)
                                .id(utt.id)
                        }
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: utterances.count) { _, _ in
                if let last = utterances.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct UtteranceRow: View {
    let utterance: Utterance

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(speakerLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(speakerColor)
                .frame(width: 60, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(utterance.text)
                    .font(.body)
                    .textSelection(.enabled)
                Text(utterance.startedAt, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var speakerLabel: String {
        switch utterance.speaker {
        case .you: "You"
        case .them: "Them"
        case .remote(let n): "Remote \(n)"
        case .localSpeaker(let n): "Speaker \(n)"
        case .named(let name, _): name
        }
    }

    private var speakerColor: Color {
        switch utterance.source {
        case .mic: .blue
        case .system: .orange
        }
    }
}
