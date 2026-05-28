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
            utterances.append(resolveVoiceprint(utterance))
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

    func reset() {
        utterances.removeAll()
        dropped.removeAll()
        systemLog.removeAll()
    }

    /// Re-resolve every existing utterance against the current voiceprint
    /// book. Called after enrollment so the new name spreads to past
    /// utterances of the same speaker.
    func rerunVoiceprintMatching() {
        utterances = utterances.map(resolveVoiceprint)
    }
}

struct DroppedUtterance: Identifiable, Hashable, Sendable {
    let utterance: Utterance
    let reason: EchoFilter.DropReason
    var id: UUID { utterance.id }
}
