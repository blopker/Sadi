import Foundation

/// Detection of utterances that are nothing but hesitation sounds ("Um.",
/// "uh, um"). The UI hides these rows; transcripts on disk keep them — the
/// filter is presentation-only, so nothing is lost and the policy can change
/// freely.
public enum FillerWords {
    /// Hesitation vocalizations only — deliberately excludes backchannel
    /// words that carry meaning alone ("yeah", "okay", "no", "huh?").
    private static let fillers: Set<String> = [
        "um", "umm", "ummm",
        "uh", "uhh", "uhhh",
        "er", "erm",
        "hm", "hmm", "hmmm",
        "mm", "mmm", "mhm", "mm-hmm", "mmhmm", "uh-huh", "uhhuh",
    ]

    /// True when the text contains no words beyond hesitation sounds.
    /// Empty/whitespace-only text is NOT filler (nothing to judge).
    public static func isFillerOnly(_ text: String) -> Bool {
        var sawWord = false
        // Split on anything that isn't a letter or an intra-word hyphen,
        // so "Um, uh." → ["um", "uh"] and "mm-hmm" survives intact.
        let tokens = text.lowercased().split { ch in
            !(ch.isLetter || ch == "-")
        }
        for token in tokens {
            let word = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if word.isEmpty { continue }
            sawWord = true
            if !fillers.contains(word) { return false }
        }
        return sawWord
    }
}
