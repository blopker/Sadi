import Foundation
import Observation
import SadiKit

/// Append-only live list of utterances published to the UI as they're emitted
/// from the per-stream pipelines. Phase 4 — no echo filter or speaker
/// resolution yet, just direct append.
@Observable
@MainActor
final class TranscriptStore {
    private(set) var utterances: [Utterance] = []

    func append(_ utterance: Utterance) {
        utterances.append(utterance)
    }

    func reset() {
        utterances.removeAll()
    }
}
