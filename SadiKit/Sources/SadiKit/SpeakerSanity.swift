import Foundation

/// Cross-track identity sanity checks.
///
/// In a call, the local user is on the mic track and remote people are on the
/// system track. The same identity appearing on both tracks at once has
/// exactly one physical explanation: speaker bleed — the speakers emit the
/// remote voice and the mic picks it up. Bleed therefore *requires* temporal
/// overlap with system speech. A mic utterance whose embedding matches a
/// far-end speaker's voiceprint but does NOT substantially overlap system
/// speech cannot be bleed — the speakers were silent — so the match is wrong
/// (embedding noise, or a voiceprint polluted by past bleed) and must be
/// rejected rather than mislabeling the local user as the remote person.
public enum SpeakerSanity {
    /// Fraction of the mic utterance's duration that must coincide with
    /// system speech for a far-end voiceprint match to be plausible. Real
    /// bleed overlaps almost fully (the mic hears the speakers in real
    /// time); brief conversational crosstalk stays well under this.
    public static let minBleedOverlapFraction = 0.5

    /// Should this mic utterance's voiceprint match be rejected?
    ///
    /// - Parameters:
    ///   - utterance: the mic utterance that matched a voiceprint.
    ///   - voiceprintID: the matched voiceprint.
    ///   - systemUtterances: the call's system-track utterances with their
    ///     final speaker labels (used both to ask "is this identity a
    ///     far-end speaker?" and for the overlap test).
    public static func isImplausibleMicMatch(
        _ utterance: Utterance,
        voiceprintID: UUID,
        systemUtterances: [Utterance]
    ) -> Bool {
        guard utterance.source == .mic, !systemUtterances.isEmpty else { return false }
        // Only far-end identities are constrained; matching the local user's
        // own voiceprint on the mic is the normal case.
        let onSystem = systemUtterances.contains { u in
            if case .named(_, let id) = u.speaker { return id == voiceprintID }
            return false
        }
        guard onSystem else { return false }

        let duration = utterance.endedAt.timeIntervalSince(utterance.startedAt)
        guard duration > 0 else { return true }
        let micRange = utterance.startedAt...utterance.endedAt
        var overlap = 0.0
        for sys in systemUtterances where sys.endedAt > sys.startedAt {
            overlap += EchoFilter.overlapSeconds(micRange, sys.startedAt...sys.endedAt)
        }
        return overlap / duration < minBleedOverlapFraction
    }
}
