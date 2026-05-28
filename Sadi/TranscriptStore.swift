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

    /// Either-stream entry point. System always kept (and recorded for the
    /// filter's overlap lookups). Mic runs through the filter in call mode
    /// (call mode = any system utterance has been seen so far). SPEC §7.3:
    /// in call mode all mic clusters fold to `.you`; in mic-only mode the
    /// StreamProcessor's `.localSpeaker(N)` survives.
    func receive(_ utterance: Utterance) {
        if utterance.source == .system {
            systemLog.append(utterance)
            utterances.append(utterance)
            return
        }
        if systemLog.isEmpty {
            // Mic-only mode — no filter, keep the StreamProcessor's
            // .localSpeaker(N) label.
            utterances.append(utterance)
            return
        }
        // Call mode: filter for bleed; survivors collapse to .you.
        switch filter.decide(mic: utterance, system: systemLog) {
        case .keep:
            var u = utterance
            u.speaker = .you
            utterances.append(u)
        case .drop(let reason):
            dropped.append(DroppedUtterance(utterance: utterance, reason: reason))
        }
    }

    func reset() {
        utterances.removeAll()
        dropped.removeAll()
        systemLog.removeAll()
    }
}

struct DroppedUtterance: Identifiable, Hashable, Sendable {
    let utterance: Utterance
    let reason: EchoFilter.DropReason
    var id: UUID { utterance.id }
}
