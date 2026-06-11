import Foundation

/// One spoken contribution after the echo filter, ready to display.
/// SPEC §9.
public struct Utterance: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public let source: Source
    public var speaker: Speaker
    public let text: String
    public let startedAt: Date
    public let endedAt: Date
    public let embedding: [Float]?
    public let asrConfidence: Float?
    /// Raw RMS of the segment samples, pre-normalization (SPEC §7.2c).
    /// EchoFilter's energy backstop compares this across tracks.
    public let rms: Float?
    /// Source-local diarizer cluster id captured at emit time. The visible
    /// `.them` / `.remote(N)` / `.localSpeaker(N)` numbering is derived from
    /// this by `TranscriptStore` so a second remote cluster appearing
    /// mid-recording can retroactively relabel earlier utterances (SPEC §13
    /// Phase 10). Mutable so a post-session relabel pass can refresh it from
    /// the diarizer's finalized timeline. `nil` when the diarizer pinned no
    /// cluster for the segment, or for older persisted transcripts.
    public var diarCluster: Int?
    /// Per-word timings from the ASR, seconds relative to `startedAt`.
    /// `nil` when the model returned no token timings, or for older
    /// persisted transcripts.
    public var wordTimings: [WordTiming]?
    /// How `speaker` was decided — see `AssignmentKind`. `nil` (older
    /// transcripts) reads as `.auto`.
    public var assignmentKind: AssignmentKind?
    /// True when `embedding` was computed over more audio than this
    /// utterance's own run (sub-300 ms runs fall back to the whole VAD
    /// segment, which may contain other speakers). Re-attribution passes
    /// should weight ambiguous embeddings accordingly.
    public var embeddingAmbiguous: Bool?

    public init(
        id: UUID = UUID(),
        source: Source,
        speaker: Speaker,
        text: String,
        startedAt: Date,
        endedAt: Date,
        embedding: [Float]? = nil,
        asrConfidence: Float? = nil,
        rms: Float? = nil,
        diarCluster: Int? = nil,
        wordTimings: [WordTiming]? = nil,
        assignmentKind: AssignmentKind? = nil,
        embeddingAmbiguous: Bool? = nil
    ) {
        self.id = id
        self.source = source
        self.speaker = speaker
        self.text = text
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.embedding = embedding
        self.asrConfidence = asrConfidence
        self.rms = rms
        self.diarCluster = diarCluster
        self.wordTimings = wordTimings
        self.assignmentKind = assignmentKind
        self.embeddingAmbiguous = embeddingAmbiguous
    }
}

/// One word's position within an utterance, seconds relative to the
/// utterance's `startedAt`. Persisted so later passes (click-to-seek,
/// re-diarization by overlap) don't need to re-run ASR.
public struct WordTiming: Hashable, Sendable, Codable {
    public let word: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(word: String, start: TimeInterval, end: TimeInterval) {
        self.word = word
        self.start = start
        self.end = end
    }
}

/// Provenance of an `Utterance.speaker` label. The contract every
/// transcript-rewriting pass must honor:
///   - `manual`  — the user pinned this specific utterance; no automated
///                 pass (finalize, rerun, re-attribution) may change it.
///   - `matched` — derived by embedding match against the voiceprint book;
///                 free to be re-derived by any later, better pass.
///   - `auto`    — bare diarizer cluster label, no persistent identity.
public enum AssignmentKind: String, Hashable, Sendable, Codable {
    case manual
    case matched
    case auto
}

public enum Source: String, Hashable, Sendable, Codable {
    case mic
    case system
}

/// Speaker identity for an `Utterance`. SPEC §8.1.
public enum Speaker: Hashable, Sendable, Codable {
    case you                       // mic, call mode
    case them                      // system, single far-end speaker
    case remote(Int)               // system, multi-speaker (1-indexed)
    case localSpeaker(Int)         // mic-only mode, multi-speaker (1-indexed)
    case named(String, UUID)       // persistent identity from voiceprint book

    /// Visible far-end label for a diarizer cluster given the full set of
    /// clusters seen across system utterances (SPEC §13 Phase 10). One
    /// distinct cluster → `.them`; two or more → `.remote(rank+1)` where rank
    /// is the cluster's position in ascending cluster-id order. A `nil`
    /// cluster (diarizer pinned nothing) falls back to `.them`.
    ///
    /// Numbering keys off *emitted* clusters, not every cluster the diarizer
    /// knows about, so "Remote 1/2" count only far-end speakers who actually
    /// produced an utterance — and a second speaker appearing mid-recording
    /// retroactively flips earlier `.them` rows to `.remote(N)`.
    public static func remoteLabel(forCluster cluster: Int?, among clusters: Set<Int>) -> Speaker {
        let distinct = clusters.sorted()
        guard distinct.count > 1, let c = cluster, let rank = distinct.firstIndex(of: c) else {
            return .them
        }
        return .remote(rank + 1)
    }
}
