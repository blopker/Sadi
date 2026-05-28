import Foundation
import Testing
@testable import SadiKit

@Suite("EchoFilter")
struct EchoFilterTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func mic(
        text: String,
        startOffset: TimeInterval,
        duration: TimeInterval = 2.0,
        rms: Float? = 0.05
    ) -> Utterance {
        Utterance(
            source: .mic, speaker: .you, text: text,
            startedAt: now.addingTimeInterval(startOffset),
            endedAt: now.addingTimeInterval(startOffset + duration),
            rms: rms
        )
    }

    private func system(
        text: String,
        startOffset: TimeInterval,
        duration: TimeInterval = 2.0,
        rms: Float? = 0.30
    ) -> Utterance {
        Utterance(
            source: .system, speaker: .them, text: text,
            startedAt: now.addingTimeInterval(startOffset),
            endedAt: now.addingTimeInterval(startOffset + duration),
            rms: rms
        )
    }

    // MARK: - Load-bearing temporal precondition

    @Test("KEEP when no system utterance overlaps — even with identical text")
    func keepsMicWithIdenticalTextWhenNoOverlap() {
        let filter = EchoFilter()
        let m = mic(text: "the quick brown fox", startOffset: 0, duration: 2)
        // Sys far enough away to not overlap.
        let s = system(text: "the quick brown fox", startOffset: 10, duration: 2)
        #expect(filter.decide(mic: m, system: [s]) == .keep)
    }

    @Test("KEEP when overlap is below 100ms threshold")
    func keepsBelowMinOverlap() {
        let filter = EchoFilter()
        // Mic 0-2.0s, sys 1.95-3.95s → overlap = 50ms, below threshold.
        let m = mic(text: "the quick brown fox jumps", startOffset: 0, duration: 2)
        let s = system(text: "the quick brown fox jumps", startOffset: 1.95, duration: 2)
        #expect(filter.decide(mic: m, system: [s]) == .keep)
    }

    @Test("KEEP when local speaks during far-end silence — voices similar but no overlap")
    func keepLocalDuringFarEndSilence() {
        // Far-end clip at 0-3s, local speaks at 5-7s, similar voice but no overlap.
        let filter = EchoFilter()
        let s = system(text: "really interesting point", startOffset: 0, duration: 3)
        let m = mic(text: "really interesting point", startOffset: 5, duration: 2)
        #expect(filter.decide(mic: m, system: [s]) == .keep)
    }

    // MARK: - Text-similarity

    @Test("DROP on Jaccard match when overlapping")
    func dropsOnHighJaccardOverlap() {
        let filter = EchoFilter()
        let m = mic(text: "we should ship the new feature next week", startOffset: 0)
        let s = system(text: "we should ship the new feature next week", startOffset: 0.5)
        #expect(filter.decide(mic: m, system: [s]) == .drop(reason: .textMatch))
    }

    @Test("KEEP short utterance even with text match — minTokens guard")
    func keepShortUtteranceWithTextMatch() {
        let filter = EchoFilter()
        // 3 tokens, 19 chars — below both guards.
        let m = mic(text: "yeah okay sure", startOffset: 0, rms: 0.20)
        let s = system(text: "yeah okay sure", startOffset: 0, rms: 0.25)
        #expect(filter.decide(mic: m, system: [s]) == .keep)
    }

    @Test("DROP on substring containment when overlapping")
    func dropsOnSubstringContainment() {
        let filter = EchoFilter()
        // Mic transcribed a partial fragment of the system text.
        let m = mic(text: "the quick brown fox jumps", startOffset: 0)
        let s = system(
            text: "well anyway the quick brown fox jumps over the lazy dog right",
            startOffset: 0, duration: 4
        )
        #expect(filter.decide(mic: m, system: [s]) == .drop(reason: .textMatch))
    }

    // MARK: - Energy backstop

    @Test("DROP on energy ratio when overlapping and texts diverge")
    func dropsOnEnergyBackstopWithGarbledText() {
        let filter = EchoFilter()
        // Texts don't match — bleed got garbled by ASR — but system is way
        // louder than mic at the same instant.
        let m = mic(text: "garbled noise here and there", startOffset: 0, rms: 0.04)
        let s = system(text: "actual remote sentence content", startOffset: 0, rms: 0.30)
        #expect(filter.decide(mic: m, system: [s]) == .drop(reason: .energy))
    }

    @Test("KEEP when energy ratio is below 3×")
    func keepWhenEnergyBelowRatio() {
        let filter = EchoFilter()
        // 0.12 / 0.05 = 2.4× — below 3× threshold.
        let m = mic(text: "garbled noise content goes here", startOffset: 0, rms: 0.05)
        let s = system(text: "actual remote sentence content", startOffset: 0, rms: 0.12)
        #expect(filter.decide(mic: m, system: [s]) == .keep)
    }

    // MARK: - Non-overlapping system in the log

    @Test("Non-overlapping system utterances ignored in the filter input")
    func ignoresNonOverlappingSystemUtterancesInLog() {
        let filter = EchoFilter()
        let nonOverlap = system(text: "same text identical", startOffset: 50, duration: 2)
        // Quiet so it doesn't trip the energy signal.
        let overlapping = system(text: "totally unrelated content here", startOffset: 0, rms: 0.06)
        // Mic's text matches the *non*-overlapping system utterance.
        // The filter must ignore it (precondition) and KEEP m.
        let m = mic(text: "same text identical content phrase", startOffset: 0)
        #expect(filter.decide(mic: m, system: [nonOverlap, overlapping]) == .keep)
    }

    // MARK: - Helpers

    @Test("overlapSeconds: disjoint, touching, partial, contained")
    func overlapSecondsCases() {
        let a = now...now.addingTimeInterval(2)
        let disjoint = now.addingTimeInterval(3)...now.addingTimeInterval(5)
        let partial = now.addingTimeInterval(1)...now.addingTimeInterval(4)
        let contained = now.addingTimeInterval(0.5)...now.addingTimeInterval(1.5)
        #expect(EchoFilter.overlapSeconds(a, disjoint) == 0)
        #expect(abs(EchoFilter.overlapSeconds(a, partial) - 1.0) < 1e-9)
        #expect(abs(EchoFilter.overlapSeconds(a, contained) - 1.0) < 1e-9)
    }
}
