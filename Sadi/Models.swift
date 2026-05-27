import Foundation

/// Errors surfaced by the recording / transcription pipeline.
enum RecorderError: LocalizedError {
    case noDisplay
    case exportFailed
    case notPrepared
    case micPermissionDenied
    case captureSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display available for system-audio capture."
        case .exportFailed:
            return "Failed to mix the recorded audio files."
        case .notPrepared:
            return "Transcription models are not loaded yet."
        case .micPermissionDenied:
            return "Microphone access was denied. Enable it in System Settings › Privacy & Security › Microphone."
        case .captureSetupFailed(let message):
            return "Audio capture setup failed: \(message)"
        }
    }
}

/// High-level state of the app, drives the UI.
enum RecordingStatus: Equatable {
    case idle
    case preparingModels
    case recording
    case transcribing
    case error(String)

    var label: String {
        switch self {
        case .idle:            return "Ready"
        case .preparingModels: return "Loading transcription models…"
        case .recording:       return "Recording…"
        case .transcribing:    return "Transcribing…"
        case .error(let m):    return "Error: \(m)"
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparingModels, .transcribing: return true
        default: return false
        }
    }
}

/// One contiguous block of speech attributed to a single speaker.
struct TranscriptSegment: Identifiable, Hashable, Codable {
    let id = UUID()
    var speakerId: String
    var startTime: Double
    var endTime: Double
    var text: String

    var timestampLabel: String {
        let m = Int(startTime) / 60
        let s = Int(startTime) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

/// A finished recording plus its transcript.
struct Recording: Identifiable, Hashable, Codable {
    let id = UUID()
    var title: String
    var createdAt: Date
    var micFileURL: URL
    var systemFileURL: URL
    var mixedFileURL: URL?
    var durationSeconds: Double
    var segments: [TranscriptSegment]

    /// Distinct speaker identifiers in first-appearance order.
    var speakers: [String] {
        var seen: [String] = []
        for seg in segments where !seen.contains(seg.speakerId) {
            seen.append(seg.speakerId)
        }
        return seen
    }
}

/// Written to disk while a recording is in progress. Its presence on the
/// next launch means the previous session was interrupted (crash / force
/// quit) and the referenced audio files still need to be recovered.
struct InterruptedSession: Codable {
    var micFileURL: URL
    var systemFileURL: URL
    var startedAt: Date
}
