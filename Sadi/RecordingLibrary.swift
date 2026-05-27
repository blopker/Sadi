import Foundation

/// On-disk persistence: the saved list of finished recordings, and the
/// "in-progress" marker used for crash recovery.
struct RecordingLibrary {

    /// Directory holding the audio files and JSON index.
    let directory: URL

    private var recordingsFile: URL {
        directory.appendingPathComponent("recordings.json")
    }
    private var markerFile: URL {
        directory.appendingPathComponent("inprogress.json")
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Saved recordings

    func loadRecordings() -> [Recording] {
        guard let data = try? Data(contentsOf: recordingsFile) else { return [] }
        return (try? makeDecoder().decode([Recording].self, from: data)) ?? []
    }

    func saveRecordings(_ recordings: [Recording]) {
        let encoder = makeEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(recordings) else { return }
        // Atomic write so a crash mid-save can't corrupt the index.
        try? data.write(to: recordingsFile, options: .atomic)
    }

    // MARK: - In-progress crash marker

    func writeMarker(_ session: InterruptedSession) {
        guard let data = try? makeEncoder().encode(session) else { return }
        try? data.write(to: markerFile, options: .atomic)
    }

    func readMarker() -> InterruptedSession? {
        guard let data = try? Data(contentsOf: markerFile) else { return nil }
        return try? makeDecoder().decode(InterruptedSession.self, from: data)
    }

    func clearMarker() {
        try? FileManager.default.removeItem(at: markerFile)
    }
}
