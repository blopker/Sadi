import AVFoundation
import SadiKit
import SwiftUI

struct ContentView: View {
    let modelHost: ModelHost
    let transcript: TranscriptStore
    let voiceprints: VoiceprintBook
    let controller: CaptureController

    @State private var micAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var showDropped = false

    var body: some View {
        VStack(spacing: 16) {
            header

            HStack(alignment: .top, spacing: 16) {
                metersColumn
                    .frame(width: 320)
                TranscriptList(
                    utterances: transcript.utterances,
                    dropped: showDropped ? transcript.dropped : [],
                    voiceprints: voiceprints,
                    onName: { utterance, name in
                        guard let embedding = utterance.embedding else { return }
                        _ = try? voiceprints.enroll(name: name, embedding: embedding)
                        transcript.rerunVoiceprintMatching()
                    }
                )
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
            Spacer()
            Toggle("Show dropped", isOn: $showDropped)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Show utterances filtered out as echo bleed (\(transcript.dropped.count))")
            modelStatusView
        }
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
    let dropped: [DroppedUtterance]
    let voiceprints: VoiceprintBook
    let onName: (Utterance, String) -> Void

    private var rows: [Row] {
        let kept = utterances.map { Row.kept($0) }
        let droppedRows = dropped.map { Row.dropped($0) }
        return (kept + droppedRows).sorted { $0.startedAt < $1.startedAt }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if utterances.isEmpty && dropped.isEmpty {
                        ContentUnavailableView(
                            "No transcripts yet",
                            systemImage: "text.bubble",
                            description: Text("Press Start, then speak or play audio.")
                        )
                        .padding(.top, 60)
                    } else {
                        ForEach(rows) { row in
                            switch row {
                            case .kept(let utt):
                                UtteranceRow(
                                    utterance: utt,
                                    voiceprints: voiceprints,
                                    onName: { name in onName(utt, name) }
                                )
                                .id(utt.id)
                            case .dropped(let d):
                                DroppedRow(dropped: d)
                                    .id(d.id)
                            }
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

    private enum Row: Identifiable {
        case kept(Utterance)
        case dropped(DroppedUtterance)

        var id: UUID {
            switch self {
            case .kept(let u): u.id
            case .dropped(let d): d.id
            }
        }

        var startedAt: Date {
            switch self {
            case .kept(let u): u.startedAt
            case .dropped(let d): d.utterance.startedAt
            }
        }
    }
}

private struct NameSpeakerPopover: View {
    let utterance: Utterance
    let existingNames: [String]
    let onSubmit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name this speaker")
                .font(.headline)
            Text("Future recordings will recognize them automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)

            if !existingNames.isEmpty {
                Text("Or pick from your voiceprint book:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(existingNames, id: \.self) { existing in
                            Button(existing) {
                                name = existing
                                submit()
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 100)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Save") { submit() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || utterance.embedding == nil)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, utterance.embedding != nil else { return }
        onSubmit(trimmed)
        dismiss()
    }
}

private struct DroppedRow: View {
    let dropped: DroppedUtterance

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.circle")
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(dropped.utterance.text)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .strikethrough()
                    .textSelection(.enabled)
                Text("dropped: \(dropped.reason.rawValue) — \(dropped.utterance.startedAt, style: .time)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct UtteranceRow: View {
    let utterance: Utterance
    let voiceprints: VoiceprintBook
    let onName: (String) -> Void

    @State private var showingNamePopover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: { showingNamePopover = true }) {
                Text(speakerLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(speakerColor)
                    .frame(width: 80, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help(utterance.embedding == nil ? "No embedding for this utterance" : "Click to name this speaker")
            .disabled(utterance.embedding == nil)
            .popover(isPresented: $showingNamePopover) {
                NameSpeakerPopover(
                    utterance: utterance,
                    existingNames: voiceprints.prints.map(\.name).sorted(),
                    onSubmit: onName
                )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(utterance.text)
                    .font(.body)
                    .textSelection(.enabled)
                // Include seconds — `style: .time` renders only H:MM in en_US,
                // which hides the sub-minute ordering between mic and system.
                Text(utterance.startedAt.formatted(date: .omitted, time: .standard))
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
