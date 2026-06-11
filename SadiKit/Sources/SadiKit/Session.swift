import Foundation

/// A meeting / recording event. Persisted as `session.json` in the session
/// directory. SPEC §9 + §10. Identified by its start time at second
/// resolution — sortable lexicographically, human-readable, one per call.
///
/// State is derived from the data, not stored as an enum (SPEC §10):
///   - `endedAt != nil`                                  → finalized
///   - `endedAt == nil`, last segment `endedAt == nil`   → recording
///   - `endedAt == nil`, last segment `endedAt != nil`   → paused / interrupted
///
/// Today the app records a single segment (pause/resume is a later phase), so a
/// finalized `session.json` carries exactly one `Segment`.
public struct Session: Codable, Sendable {
    public let id: String                  // "YYYY-MM-DD-HH-MM-SS" (local time)
    public var title: String
    public let startedAt: Date             // wall-clock start of segment 1
    public var endedAt: Date?              // nil while in-progress or paused
    public var segments: [Segment]         // 1+ contiguous record-to-pause periods
    public var speakerClusters: [SpeakerCluster]  // accumulated across segments
    /// True while the post-stop finalize pass (offline diarization + echo
    /// re-filter) is still owed — set when the recording stops, cleared when
    /// finalize completes. Survives a quit mid-finalize so the pass can run
    /// lazily on next launch. `nil` (older sessions / mid-recording) means
    /// no finalize is pending.
    public var needsFinalize: Bool?

    public init(
        id: String,
        title: String,
        startedAt: Date,
        endedAt: Date?,
        segments: [Segment],
        speakerClusters: [SpeakerCluster],
        needsFinalize: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
        self.speakerClusters = speakerClusters
        self.needsFinalize = needsFinalize
    }

    /// Atomically write `session.json` into the session directory. Written by
    /// `CaptureController.stop()` after the MP4s and transcript are on disk, so
    /// `endedAt != nil` marks the session finalized. The `.atomic` option goes
    /// through a temp file + rename, so a partial write can't replace a good
    /// `session.json` (SPEC §10.4).
    public func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let url = directory.appending(path: "session.json", directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
    }
}

/// One uninterrupted recording period within a session. SPEC §9.
/// Pause finalizes the current segment; resume appends a new one.
public struct Segment: Codable, Sendable {
    public let index: Int                  // 1-indexed within the session
    public let startedAt: Date
    public var endedAt: Date?              // nil while this segment is recording
    public var micFilename: String         // e.g. "mic-001.mp4", relative to session dir
    public var systemFilename: String?     // nil in mic-only mode
    /// Wall clock of each track's sample 0, stamped when its capture actually
    /// started. The mic anchor ≈ `startedAt`, but the system tap comes up
    /// ~1.5–2 s later (deferred until the mic settles) — any pass that maps
    /// file-relative time back to wall-clock (offline finalize/rerun) needs
    /// the per-track anchor, not the session start. `nil` on older sessions;
    /// readers fall back to `startedAt` and accept the skew.
    public var micAnchor: Date?
    public var systemAnchor: Date?

    public init(
        index: Int,
        startedAt: Date,
        endedAt: Date?,
        micFilename: String,
        systemFilename: String?,
        micAnchor: Date? = nil,
        systemAnchor: Date? = nil
    ) {
        self.index = index
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.micFilename = micFilename
        self.systemFilename = systemFilename
        self.micAnchor = micAnchor
        self.systemAnchor = systemAnchor
    }
}

/// A persistent speaker cluster accumulated across a session's segments.
/// SPEC §9. Not yet populated by the live pipeline (the diarizer timeline is
/// owned per-stream); reserved so `session.json` carries the field and a later
/// post-session relabel pass can fill it in.
public struct SpeakerCluster: Codable, Sendable {
    public let id: UUID
    public let source: Source
    public let localIdx: Int               // 1-indexed within the source track
    public var centroid: [Float]
    public var resolvedName: String?       // if matched to a voiceprint
    public var resolvedVoiceprintID: UUID?

    public init(
        id: UUID,
        source: Source,
        localIdx: Int,
        centroid: [Float],
        resolvedName: String?,
        resolvedVoiceprintID: UUID?
    ) {
        self.id = id
        self.source = source
        self.localIdx = localIdx
        self.centroid = centroid
        self.resolvedName = resolvedName
        self.resolvedVoiceprintID = resolvedVoiceprintID
    }
}
