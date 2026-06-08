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

    /// Live voiceprint resolution (SPEC §8.2). If the utterance carries an
    /// embedding and matches an enrolled voiceprint within `matchThreshold`,
    /// replace the speaker label with `.named`. Otherwise pass through.
    private func resolveVoiceprint(_ u: Utterance) -> Utterance {
        guard let embedding = u.embedding,
              let match = voiceprints.match(embedding: embedding)
        else { return u }
        var copy = u
        copy.speaker = .named(match.voiceprint.name, match.voiceprint.id)
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
    func writeTranscript(to directory: URL) throws {
        let doc = TranscriptDocument(
            schemaVersion: 1,
            sessionID: directory.lastPathComponent,
            utterances: utterances
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(doc)
        let url = directory.appending(path: "transcript.json", directoryHint: .notDirectory)
        try data.write(to: url, options: .atomic)
    }
}

/// On-disk shape of `transcript.json`. `schemaVersion` lets a later reader
/// migrate older files; `Utterance` is already `Codable` (SadiKit).
struct TranscriptDocument: Codable {
    let schemaVersion: Int
    let sessionID: String
    let utterances: [Utterance]
}

struct DroppedUtterance: Identifiable, Hashable, Sendable {
    let utterance: Utterance
    let reason: EchoFilter.DropReason
    var id: UUID { utterance.id }
}
