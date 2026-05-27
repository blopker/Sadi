import SwiftUI

// MARK: - Speaker colour palette

enum SpeakerPalette {
    private static let colors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .red
    ]

    /// Stable colour for a given speaker id.
    static func color(for speakerId: String, in order: [String]) -> Color {
        guard let idx = order.firstIndex(of: speakerId) else { return .gray }
        return colors[idx % colors.count]
    }

    /// Friendly label, e.g. "Speaker 1".
    static func label(for speakerId: String, in order: [String]) -> String {
        guard let idx = order.firstIndex(of: speakerId) else { return speakerId }
        return "Speaker \(idx + 1)"
    }
}

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            detail
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            RecordButton()
                .padding()

            Divider()

            if controller.recordings.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "waveform",
                    description: Text("Press the button above or ⌥⌘R to record."))
            } else {
                List(selection: $controller.selectedRecordingID) {
                    ForEach(controller.recordings) { recording in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.title)
                                .font(.callout)
                                .lineLimit(1)
                            Text(durationText(recording.durationSeconds))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(recording.id)
                    }
                }
            }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let recording = controller.selectedRecording {
            TranscriptView(recording: recording)
        } else {
            ContentUnavailableView(
                "Select a recording",
                systemImage: "text.bubble",
                description: Text("Your transcript will appear here."))
        }
    }

    private func durationText(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d min %02d sec", m, s)
    }
}

// MARK: - Record button

struct RecordButton: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(spacing: 8) {
            Button(action: controller.toggleRecording) {
                Label(buttonTitle, systemImage: buttonIcon)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? .red : .accentColor)
            .disabled(controller.status.isBusy || !controller.modelsReady)

            Text(controller.status.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var isRecording: Bool { controller.status == .recording }

    private var buttonTitle: String {
        switch controller.status {
        case .recording:    return "Stop"
        case .transcribing: return "Transcribing…"
        case .preparingModels: return "Loading…"
        default:            return "Record"
        }
    }

    private var buttonIcon: String {
        isRecording ? "stop.circle.fill" : "record.circle"
    }
}

// MARK: - Transcript view

struct TranscriptView: View {
    let recording: Recording

    var body: some View {
        let speakers = recording.speakers

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if recording.segments.isEmpty {
                    Text("No speech was transcribed for this recording.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recording.segments) { segment in
                        SegmentRow(segment: segment, speakerOrder: speakers)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(recording.title)
    }
}

struct SegmentRow: View {
    let segment: TranscriptSegment
    let speakerOrder: [String]

    var body: some View {
        let color = SpeakerPalette.color(for: segment.speakerId, in: speakerOrder)
        let name = SpeakerPalette.label(for: segment.speakerId, in: speakerOrder)

        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(color)
                    Text(segment.timestampLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(segment.text)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
    }
}
