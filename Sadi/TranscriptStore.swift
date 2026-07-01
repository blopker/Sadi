import CryptoKit
import Foundation
import Observation
import SadiKit

/// Append-only live list of utterances published to the UI as they're emitted
/// from the per-stream pipelines. Phase 6 routes mic utterances through the
/// EchoFilter (SPEC §7); dropped utterances are kept in a separate list so
/// the UI can offer a debug toggle (SPEC §11).
@Observable
@MainActor
final class TranscriptStore {
    private(set) var utterances: [Utterance] = []
    private(set) var dropped: [DroppedUtterance] = []
    /// Wall-clock time of the most recent transcribed utterance (kept or
    /// dropped) — i.e. the last time speech was heard. Seeded at `reset()` to
    /// the session start so a recording that never produces speech still has a
    /// well-defined idle clock for the auto-stop monitor.
    private(set) var lastActivityAt = Date()
    private var systemLog: [Utterance] = []
    private let filter = EchoFilter()
    private let voiceprints: VoiceprintBook

    /// Distinct diarizer cluster ids seen across system utterances so far.
    /// The visible `.them` / `.remote(N)` numbering is derived from this set
    /// (SPEC §13 Phase 10): one distinct cluster → everyone is `.them`; two or
    /// more → `.remote(rank+1)` by sorted cluster id. When a brand-new cluster
    /// first speaks, ranks shift and earlier utterances are relabeled.
    private var seenSystemClusters: Set<Int> = []

    init(voiceprints: VoiceprintBook) {
        self.voiceprints = voiceprints
    }

    /// Either-stream entry point. System always kept (and recorded for the
    /// filter's overlap lookups). Mic runs through the filter in call mode
    /// (call mode = any system utterance has been seen so far). SPEC §7.3:
    /// in call mode all mic clusters fold to `.you`; in mic-only mode the
    /// StreamProcessor's `.localSpeaker(N)` survives.
    func receive(_ utterance: Utterance) {
        // Any transcribed utterance — kept or echo-filtered — counts as speech
        // activity for the idle auto-stop clock.
        lastActivityAt = Date()
        if utterance.source == .system {
            systemLog.append(utterance)
            // StreamProcessor emits a `.them` placeholder; this store owns the
            // final `.them` vs `.remote(N)` numbering (SPEC §13 Phase 10).
            let newCluster: Bool
            if let c = utterance.diarCluster, !seenSystemClusters.contains(c) {
                seenSystemClusters.insert(c)
                newCluster = true
            } else {
                newCluster = false
            }
            utterances.append(utterance)
            if newCluster {
                // A previously-unseen remote cluster: ranks may have shifted
                // (e.g. .them → .remote(1) once a second speaker appears), so
                // re-derive every system utterance's label.
                relabelSystemSpeakers()
            } else {
                let i = utterances.count - 1
                utterances[i] = labelSystemUtterance(utterances[i], distinct: seenSystemClusters)
            }
            reevaluateKeptMic(overlapping: utterance)
            return
        }
        if systemLog.isEmpty {
            // Mic-only mode — no filter, keep the StreamProcessor's
            // .localSpeaker(N) label (unless a voiceprint resolves it).
            utterances.append(resolveVoiceprint(utterance))
            return
        }
        // Call mode: filter for bleed; survivors collapse to .you (or .named
        // if their embedding matches an enrolled voiceprint).
        switch filter.decide(mic: utterance, system: systemLog) {
        case .keep:
            var u = utterance
            u.speaker = .you
            utterances.append(resolveVoiceprint(u))
        case .drop(let reason):
            dropped.append(DroppedUtterance(utterance: utterance, reason: reason))
        }
    }

    /// Retroactive echo check (SPEC §7). Arrival order at this store is an
    /// ASR-latency race, not a fact about the audio: bleed by definition
    /// coincides with system speech, so both segments are usually in flight
    /// at once — and when the mic side finishes transcribing first, `decide`
    /// saw an empty overlap set and kept it. On each system arrival, re-run
    /// the filter over kept mic utterances that overlap it in time and demote
    /// any the filter now rejects.
    private func reevaluateKeptMic(overlapping sys: Utterance) {
        var kept: [Utterance] = []
        kept.reserveCapacity(utterances.count)
        for u in utterances {
            guard u.source == .mic,
                  EchoFilter.overlapSeconds(u.startedAt...u.endedAt, sys.startedAt...sys.endedAt)
                      >= filter.minOverlapSeconds,
                  case .drop(let reason) = filter.decide(mic: u, system: systemLog)
            else {
                kept.append(u)
                continue
            }
            dropped.append(DroppedUtterance(utterance: u, reason: reason))
        }
        if kept.count != utterances.count { utterances = kept }
    }

    /// Live voiceprint resolution (SPEC §8.2). If the utterance carries an
    /// embedding and matches an enrolled voiceprint within `matchThreshold`,
    /// replace the speaker label with `.named` and stamp `matched` provenance.
    /// `manual` utterances are never touched — that's the user's pin, and the
    /// AssignmentKind contract says only the user may move it.
    ///
    /// Cross-track sanity: a mic utterance matching a *far-end* speaker's
    /// print is either bleed (it overlaps system speech — the echo filter's
    /// problem) or a mis-match (the speakers were silent, so the audio can't
    /// be the remote person — keep `.you` rather than mislabeling the local
    /// user). See `SpeakerSanity`.
    private func resolveVoiceprint(_ u: Utterance) -> Utterance {
        guard u.assignmentKind != .manual,
              let embedding = u.embedding,
              let match = voiceprints.match(embedding: embedding)
        else { return u }
        if SpeakerSanity.isImplausibleMicMatch(
            u, voiceprintID: match.voiceprint.id,
            systemUtterances: utterances.filter { $0.source == .system }
        ) {
            return u
        }
        var copy = u
        copy.speaker = .named(match.voiceprint.name, match.voiceprint.id)
        copy.assignmentKind = .matched
        return copy
    }

    /// Re-derive `.them` / `.remote(N)` for every system utterance from the
    /// current `seenSystemClusters` set, then re-apply voiceprint resolution
    /// (which can override the cluster label with a persistent `.named`).
    /// Only system utterances are touched; mic labels are left as-is.
    private func relabelSystemSpeakers() {
        utterances = utterances.map { u in
            u.source == .system ? labelSystemUtterance(u, distinct: seenSystemClusters) : u
        }
    }

    /// Cluster-derived label for one system utterance, with voiceprint
    /// resolution layered on top. `distinct` is the set of cluster ids seen
    /// across all system utterances.
    private func labelSystemUtterance(_ u: Utterance, distinct: Set<Int>) -> Utterance {
        var copy = u
        copy.speaker = .remoteLabel(forCluster: u.diarCluster, among: distinct)
        return resolveVoiceprint(copy)
    }

    func reset() {
        utterances.removeAll()
        dropped.removeAll()
        systemLog.removeAll()
        seenSystemClusters.removeAll()
        lastActivityAt = Date()
    }

    /// Re-resolve every existing utterance against the current voiceprint
    /// book. Called after enrollment so the new name spreads to past
    /// utterances of the same speaker.
    func rerunVoiceprintMatching() {
        utterances = utterances.map(resolveVoiceprint)
    }

    /// Persist the current transcript to `transcript.json` in the session
    /// directory. Called from `CaptureController.stop()` after the MP4s are
    /// finalized, so a clean Stop (or a graceful app quit, which routes through
    /// the same stop path) leaves both the audio and the transcript on disk.
    /// The write is atomic; a partial file can never replace a good one.
    ///
    /// Not a crash-recovery mechanism — a force-quit or crash never reaches
    /// here. The session's fragmented MP4s remain the source of truth and the
    /// transcript can be re-derived from them (transcription is cheap).
    func writeTranscript(to directory: URL) async throws {
        // Snapshot the main-actor state here; the coordinator actor does the
        // encode + atomic write off the main thread and serializes it against
        // any other transcript rewrite for the session.
        let doc = TranscriptDocument(
            schemaVersion: 2,
            sessionID: directory.lastPathComponent,
            generator: .live,
            utterances: utterances
        )
        try await TranscriptDocumentFileCoordinator.shared.save(doc, to: directory)
    }
}

/// On-disk shape of `transcript.json`. `schemaVersion` lets a later reader
/// migrate older files; `Utterance` is already `Codable` (SadiKit).
/// `nonisolated` so its `Codable` conformance can run off the main actor (the
/// app builds with default main-actor isolation). `load`/`write` below are the
/// single definition of the on-disk coding; all rewrites go through
/// `TranscriptDocumentFileCoordinator`. Members are all value types from
/// SadiKit, so this is safe.
nonisolated struct TranscriptDocument: Codable, Sendable {
    let schemaVersion: Int
    let sessionID: String
    /// Which pass produced this document. `nil` = schema-v1 live transcript.
    let generator: Generator?
    let utterances: [Utterance]
    /// For `.cleaned` documents: the `contentHash` of the raw transcript this
    /// was derived from, so the UI can tell when the cleaned copy has fallen
    /// behind the raw one (e.g. a rerun changed the words while the LLM server
    /// was offline). `nil` for raw/live/finalize/rerun documents.
    let sourceHash: String?

    /// Schema v2: live = streaming pipeline at record time; finalize =
    /// post-stop offline diarization/echo pass over the draft; rerun = full
    /// from-audio regeneration; cleaned = optional LLM cleanup pass over a
    /// finalized transcript (stored separately, never overwrites the raw).
    nonisolated enum Generator: String, Codable, Sendable {
        case live
        case finalize
        case rerun
        case cleaned
    }

    /// The optional LLM-cleaned copy, stored beside `transcript.json`.
    static let cleanedFilename = "transcript.cleaned.json"

    init(
        schemaVersion: Int, sessionID: String, generator: Generator?,
        utterances: [Utterance], sourceHash: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.generator = generator
        self.utterances = utterances
        self.sourceHash = sourceHash
    }

    /// Copy with the utterance list swapped and every other field preserved.
    /// The document is immutable-by-field, so this is how rewrite passes
    /// (pins, re-attribution, cleanup stitching) produce their output.
    func replacingUtterances(_ utterances: [Utterance]) -> TranscriptDocument {
        TranscriptDocument(
            schemaVersion: schemaVersion, sessionID: sessionID, generator: generator,
            utterances: utterances, sourceHash: sourceHash)
    }

    /// Decode a session directory's transcript. `nil` when the file is missing
    /// or unreadable. Reads need no coordination; call from any executor.
    static func load(from directory: URL, filename: String = "transcript.json") -> TranscriptDocument? {
        let url = directory.appending(path: filename, directoryHint: .notDirectory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(TranscriptDocument.self, from: data)
    }

    /// Atomic encode + write. `fileprivate` on purpose: all writers must go
    /// through `TranscriptDocumentFileCoordinator` (same file) so competing
    /// read/modify/write passes cannot overtake each other.
    fileprivate func write(to directory: URL, filename: String = "transcript.json") throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        let url = directory.appending(path: filename, directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
    }

    /// Stable fingerprint of the cleanup-relevant content — each utterance's
    /// id + text, in order. Speaker re-pins (which don't touch text) leave it
    /// unchanged; a rerun that alters the words changes it. Used to flag a
    /// `.cleaned` document as out of date against its raw transcript.
    static func contentHash(_ utterances: [Utterance]) -> String {
        var hasher = SHA256()
        for u in utterances {
            hasher.update(data: Data(u.id.uuidString.utf8))
            hasher.update(data: Data([0x1f]))
            hasher.update(data: Data(u.text.utf8))
            hasher.update(data: Data([0x0a]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Serializes transcript file mutations across every writer — live stop,
/// offline finalize/rerun, cleanup, manual pins, re-attribution. Atomic writes
/// protect against a torn file; this protects against lost updates from
/// competing read/modify/write passes.
actor TranscriptDocumentFileCoordinator {
    static let shared = TranscriptDocumentFileCoordinator()

    func save(
        _ doc: TranscriptDocument, to directory: URL, filename: String = "transcript.json"
    ) throws {
        try doc.write(to: directory, filename: filename)
    }

    /// Read the latest on-disk document, transform, write. The transform also
    /// returns a caller value (e.g. a change count) — it is the only code that
    /// sees both the before and after documents. Returns `nil` when the
    /// transcript is missing or the transform declines.
    @discardableResult
    func update<Extra: Sendable>(
        directory: URL,
        _ transform: @Sendable (TranscriptDocument) -> (TranscriptDocument, Extra)?
    ) throws -> (document: TranscriptDocument, extra: Extra)? {
        guard let current = TranscriptDocument.load(from: directory),
              let (updated, extra) = transform(current)
        else { return nil }
        try updated.write(to: directory)
        return (updated, extra)
    }

    /// Read-modify-write without a side value.
    @discardableResult
    func update(
        directory: URL,
        _ transform: @Sendable (TranscriptDocument) -> TranscriptDocument?
    ) throws -> TranscriptDocument? {
        try update(directory: directory) { doc in
            transform(doc).map { ($0, ()) }
        }?.document
    }
}

struct DroppedUtterance: Identifiable, Hashable, Sendable {
    let utterance: Utterance
    let reason: EchoFilter.DropReason
    var id: UUID { utterance.id }
}
