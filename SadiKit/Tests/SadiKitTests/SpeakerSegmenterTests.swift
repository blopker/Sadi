import Foundation
import Testing
@testable import SadiKit

@Suite("SpeakerSegmenter")
struct SpeakerSegmenterTests {
    private func t(_ text: String, _ start: Double, _ end: Double) -> TimedToken {
        TimedToken(text: text, startTime: start, endTime: end)
    }

    @Test("empty input returns empty runs")
    func emptyInput() {
        let runs = SpeakerSegmenter.splitIntoRuns(
            tokens: [],
            speakerAt: { _ in 0 }
        )
        #expect(runs.isEmpty)
    }

    @Test("single-speaker segment stays as one run")
    func singleSpeaker() {
        let tokens = (0..<6).map { t("▁word\($0)", Double($0), Double($0) + 1) }
        let runs = SpeakerSegmenter.splitIntoRuns(
            tokens: tokens,
            speakerAt: { _ in 0 }
        )
        #expect(runs.count == 1)
        #expect(runs[0].speakerIndex == 0)
        #expect(runs[0].tokens.count == 6)
    }

    @Test("clean A→B→A split with sufficient tokens per run")
    func cleanThreeRuns() {
        let speakers: [Int] = [0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0]
        let tokens = speakers.enumerated().map { i, _ in t("▁tok\(i)", Double(i), Double(i) + 0.4) }
        let runs = SpeakerSegmenter.splitIntoRuns(
            tokens: tokens,
            speakerAt: { time in
                let idx = min(speakers.count - 1, max(0, Int(time)))
                return speakers[idx]
            },
            minTokensPerRun: 3
        )
        #expect(runs.count == 3)
        #expect(runs[0].speakerIndex == 0)
        #expect(runs[1].speakerIndex == 1)
        #expect(runs[2].speakerIndex == 0)
        #expect(runs[0].tokens.count == 4)
        #expect(runs[1].tokens.count == 4)
        #expect(runs[2].tokens.count == 4)
    }

    @Test("single-token speaker flicker is smoothed into the larger neighbor")
    func smoothesSingleTokenFlicker() {
        // 8 tokens of speaker 0, then 1 token of speaker 1, then 8 more of speaker 0.
        // Should collapse to one run of speaker 0.
        let pattern: [Int] = Array(repeating: 0, count: 8) + [1] + Array(repeating: 0, count: 8)
        let tokens = pattern.enumerated().map { i, _ in t("▁t\(i)", Double(i), Double(i) + 0.4) }
        let runs = SpeakerSegmenter.splitIntoRuns(
            tokens: tokens,
            speakerAt: { time in
                let idx = min(pattern.count - 1, max(0, Int(time)))
                return pattern[idx]
            },
            minTokensPerRun: 3
        )
        #expect(runs.count == 1)
        #expect(runs[0].speakerIndex == 0)
        #expect(runs[0].tokens.count == pattern.count)
    }

    @Test("nil speaker lookups fall back to surrounding context")
    func nilSpeakersFillFromContext() {
        // Speakers: 0 0 0 nil nil 1 1 1
        let lookup: [Int?] = [0, 0, 0, nil, nil, 1, 1, 1]
        let tokens = lookup.enumerated().map { i, _ in t("▁t\(i)", Double(i), Double(i) + 0.4) }
        let runs = SpeakerSegmenter.splitIntoRuns(
            tokens: tokens,
            speakerAt: { time in
                let idx = min(lookup.count - 1, max(0, Int(time)))
                return lookup[idx]
            },
            minTokensPerRun: 3
        )
        // The two `nil` tokens should adopt the prior speaker (0), giving runs:
        //   speaker 0 × 5 tokens, speaker 1 × 3 tokens.
        #expect(runs.count == 2)
        #expect(runs[0].speakerIndex == 0)
        #expect(runs[0].tokens.count == 5)
        #expect(runs[1].speakerIndex == 1)
        #expect(runs[1].tokens.count == 3)
    }

    @Test("text reconstruction joins ▁ tokens with spaces and trims")
    func textReconstruction() {
        let tokens = [
            t("▁hello", 0, 0.5),
            t("▁world", 0.5, 1.0),
            t("!", 1.0, 1.1),
        ]
        let runs = SpeakerSegmenter.splitIntoRuns(
            tokens: tokens,
            speakerAt: { _ in 0 }
        )
        #expect(runs.count == 1)
        #expect(runs[0].text == "hello world!")
    }

    @Test("disabling smoothing keeps every flicker")
    func smoothingDisabled() {
        let pattern: [Int] = [0, 0, 0, 1, 0, 0, 0]
        let tokens = pattern.enumerated().map { i, _ in t("▁t\(i)", Double(i), Double(i) + 0.4) }
        let runs = SpeakerSegmenter.splitIntoRuns(
            tokens: tokens,
            speakerAt: { time in pattern[min(pattern.count - 1, max(0, Int(time)))] },
            minTokensPerRun: 1
        )
        #expect(runs.count == 3)
    }
}
