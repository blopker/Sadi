import Foundation

/// Filesystem layout helper for a recording session per SPEC §10.
///
/// A session's id is the human-readable local-time timestamp
/// (`YYYY-MM-DD-HH-MM-SS`) at which it started. Lexicographic sort matches
/// chronological order; collisions are resolved by a `-N` suffix.
public struct SessionPaths: Sendable {
    public let id: String
    public let directory: URL

    public func micURL(segment: Int) -> URL {
        directory.appending(path: String(format: "mic-%03d.mp4", segment), directoryHint: .notDirectory)
    }

    public func systemURL(segment: Int) -> URL {
        directory.appending(path: String(format: "system-%03d.mp4", segment), directoryHint: .notDirectory)
    }

    /// Create a fresh session directory under the app's recordings root and
    /// return paths for it. Resolves second-collisions by appending `-N`.
    public static func create(now: Date = Date(), fileManager: FileManager = .default) throws -> SessionPaths {
        let root = try recordingsRoot(fileManager: fileManager)
        let baseID = formatID(now)
        var id = baseID
        var dir = root.appending(path: id, directoryHint: .isDirectory)
        var suffix = 1
        while fileManager.fileExists(atPath: dir.path(percentEncoded: false)) {
            id = "\(baseID)-\(suffix)"
            dir = root.appending(path: id, directoryHint: .isDirectory)
            suffix += 1
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return SessionPaths(id: id, directory: dir)
    }

    public static func recordingsRoot(fileManager: FileManager = .default) throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = support.appending(path: "Sadi/recordings", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return f
    }()

    private static func formatID(_ date: Date) -> String {
        idFormatter.string(from: date)
    }
}
