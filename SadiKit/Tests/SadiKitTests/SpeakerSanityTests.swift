import Foundation
import Testing

@testable import SadiKit

@Suite("FillerWords")
struct FillerWordsTests {
    @Test("pure filler utterances are detected")
    func fillerOnly() {
        #expect(FillerWords.isFillerOnly("Um."))
        #expect(FillerWords.isFillerOnly("uh"))
        #expect(FillerWords.isFillerOnly("Um, uh."))
        #expect(FillerWords.isFillerOnly("Mm-hmm."))
        #expect(FillerWords.isFillerOnly("Hmm... umm"))
    }

    @Test("meaningful text is never filler-only")
    func meaningful() {
        #expect(!FillerWords.isFillerOnly("Um, I think so."))
        #expect(!FillerWords.isFillerOnly("Yeah."))
        #expect(!FillerWords.isFillerOnly("Okay"))
        #expect(!FillerWords.isFillerOnly("No"))
        #expect(!FillerWords.isFillerOnly("Huh?"))
    }

    @Test("empty or punctuation-only text is not filler")
    func empty() {
        #expect(!FillerWords.isFillerOnly(""))
        #expect(!FillerWords.isFillerOnly("   "))
        #expect(!FillerWords.isFillerOnly("..."))
    }
}

@Suite("SpeakerSanity")
struct SpeakerSanityTests {
    private let remoteID = UUID()
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func utterance(
        source: Source, speaker: Speaker, start: TimeInterval, end: TimeInterval
    ) -> Utterance {
        Utterance(
            source: source, speaker: speaker, text: "test",
            startedAt: base.addingTimeInterval(start),
            endedAt: base.addingTimeInterval(end)
        )
    }

    /// The local user talking while the far end is silent: a match against
    /// the far-end voiceprint is physically impossible bleed → rejected.
    @Test("far-end match without system overlap is rejected")
    func rejectsNonOverlappingFarEndMatch() {
        let system = [utterance(source: .system, speaker: .named("Remote", remoteID), start: 0, end: 5)]
        let mic = utterance(source: .mic, speaker: .you, start: 10, end: 14)
        #expect(SpeakerSanity.isImplausibleMicMatch(mic, voiceprintID: remoteID, systemUtterances: system))
    }

    /// Genuine bleed: the mic utterance rides on top of the system speech.
    @Test("far-end match fully overlapping system speech is plausible")
    func keepsOverlappingBleedMatch() {
        let system = [utterance(source: .system, speaker: .named("Remote", remoteID), start: 0, end: 10)]
        let mic = utterance(source: .mic, speaker: .you, start: 2, end: 6)
        #expect(!SpeakerSanity.isImplausibleMicMatch(mic, voiceprintID: remoteID, systemUtterances: system))
    }

    /// Brief crosstalk (small overlap fraction) is not bleed.
    @Test("marginal overlap below the bleed fraction is rejected")
    func rejectsMarginalOverlap() {
        let system = [utterance(source: .system, speaker: .named("Remote", remoteID), start: 0, end: 5)]
        // 10 s utterance, only 1 s under system speech → 10% < 50%.
        let mic = utterance(source: .mic, speaker: .you, start: 4, end: 14)
        #expect(SpeakerSanity.isImplausibleMicMatch(mic, voiceprintID: remoteID, systemUtterances: system))
    }

    /// Matching a voiceprint that is NOT a far-end speaker (the local user's
    /// own print) is always plausible.
    @Test("matching an identity not on the system track is untouched")
    func keepsLocalIdentity() {
        let localID = UUID()
        let system = [utterance(source: .system, speaker: .named("Remote", remoteID), start: 0, end: 5)]
        let mic = utterance(source: .mic, speaker: .you, start: 10, end: 14)
        #expect(!SpeakerSanity.isImplausibleMicMatch(mic, voiceprintID: localID, systemUtterances: system))
    }

    /// Mic-only mode (no system utterances): never reject.
    @Test("no system track means no constraint")
    func micOnlyUnconstrained() {
        let mic = utterance(source: .mic, speaker: .you, start: 0, end: 5)
        #expect(!SpeakerSanity.isImplausibleMicMatch(mic, voiceprintID: remoteID, systemUtterances: []))
    }
}
