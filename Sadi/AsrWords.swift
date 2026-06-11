import FluidAudio
import Foundation
import SadiKit

/// Group Parakeet's subword tokens into whole words. FluidAudio's ASR
/// normalizes `▁` → " " before populating TokenTiming.token, so a word
/// starts at any token whose text begins with a space (or, defensively,
/// the raw `▁` marker if a future version stops normalizing).
///
/// Shared by the live `StreamProcessor` and the offline finalize/rerun
/// pipeline so both produce identical word boundaries.
nonisolated enum AsrWords {
    static func group(_ timings: [TokenTiming]) -> [TimedToken] {
        var words: [TimedToken] = []
        var currentTexts: [String] = []
        var currentStart: TimeInterval = 0
        var currentEnd: TimeInterval = 0
        for tt in timings {
            let startsWord = tt.token.hasPrefix(" ") || tt.token.hasPrefix("▁")
            if startsWord && !currentTexts.isEmpty {
                words.append(
                    TimedToken(
                        text: currentTexts.joined(),
                        startTime: currentStart,
                        endTime: currentEnd
                    ))
                currentTexts = []
            }
            if currentTexts.isEmpty {
                currentStart = tt.startTime
            }
            currentTexts.append(tt.token)
            currentEnd = tt.endTime
        }
        if !currentTexts.isEmpty {
            words.append(
                TimedToken(
                    text: currentTexts.joined(),
                    startTime: currentStart,
                    endTime: currentEnd
                ))
        }
        return words
    }
}
