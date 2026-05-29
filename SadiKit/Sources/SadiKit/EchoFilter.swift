import Foundation

/// Post-ASR bleed filter per SPEC §7. Pure logic — given a candidate mic
/// utterance and the running log of system utterances seen so far, decide
/// whether the mic utterance is the local user (KEEP) or a re-transcription
/// of the far-end audio leaking through the speakers (DROP).
///
/// The temporal-overlap precondition is the load-bearing fix — SPEC §7.2
/// flags it as "the precondition we got wrong the first time around." All
/// content-based signals (text, energy, fingerprint) are only evaluated
/// against system utterances that actually overlap the candidate in time.
public struct EchoFilter: Sendable {
    public enum Decision: Equatable, Sendable {
        case keep
        case drop(reason: DropReason)
    }

    public enum DropReason: String, Equatable, Sendable {
        case textMatch
        case fingerprintMatch
        case energy
    }

    /// SPEC §7.2 tunables. Defaults mirror the spec text; tests pin them.
    public var minOverlapSeconds: Double = 0.1
    public var jaccardThreshold: Double = 0.6
    public var minTokensForTextSignal: Int = 4
    public var minCharsForTextSignal: Int = 20
    public var energyRatio: Float = 3.0

    public init() {}

    /// Decide whether `mic` is bleed of any of the `system` utterances.
    ///
    /// `system` should be every system-track utterance accumulated so far in
    /// the recording — the filter restricts itself to those that overlap
    /// `mic.timeRange` by `minOverlapSeconds`.
    public func decide(mic: Utterance, system: [Utterance]) -> Decision {
        precondition(mic.source == .mic, "EchoFilter.decide expects a mic-source utterance")

        // 1. Temporal-overlap precondition (load-bearing).
        let overlapping = system.filter { sys in
            sys.source == .system &&
                overlapSeconds(mic.startedAt...mic.endedAt, sys.startedAt...sys.endedAt)
                >= minOverlapSeconds
        }
        if overlapping.isEmpty { return .keep }

        // 2a. Text-similarity match.
        if textSignalFires(mic: mic, overlapping: overlapping) {
            return .drop(reason: .textMatch)
        }

        // 2c. Energy backstop. (2b fingerprint deferred to Phase 6.1.)
        if energySignalFires(mic: mic, overlapping: overlapping) {
            return .drop(reason: .energy)
        }

        return .keep
    }

    // MARK: - Signals

    private func textSignalFires(mic: Utterance, overlapping: [Utterance]) -> Bool {
        let micNorm = normalize(mic.text)
        let micTokens = tokenize(micNorm)
        // Short utterances are too noisy for text similarity (SPEC §7.2a).
        guard micTokens.count >= minTokensForTextSignal || micNorm.count >= minCharsForTextSignal else {
            return false
        }
        let micSet = Set(micTokens)

        for sys in overlapping {
            let sysNorm = normalize(sys.text)
            let sysTokens = tokenize(sysNorm)
            // Apply the same minimum on the system side. Without this a sys
            // utterance the ASR mangled to "i" or "uh" would substring-match
            // any mic line containing that letter — a catastrophic false
            // positive against normal English speech.
            guard sysTokens.count >= minTokensForTextSignal || sysNorm.count >= minCharsForTextSignal else {
                continue
            }
            let sysSet = Set(sysTokens)
            if jaccard(micSet, sysSet) >= jaccardThreshold { return true }
            // Token-set subset (was: character substring). Catches the
            // "ASR transcribed a fragment of the other" pattern at word
            // granularity, immune to single-letter / partial-word matches.
            if sysSet.isSubset(of: micSet) || micSet.isSubset(of: sysSet) { return true }
        }
        return false
    }

    private func energySignalFires(mic: Utterance, overlapping: [Utterance]) -> Bool {
        guard let micRMS = mic.rms, micRMS > 0 else { return false }
        for sys in overlapping {
            if let sysRMS = sys.rms, sysRMS > energyRatio * micRMS {
                return true
            }
        }
        return false
    }

    // MARK: - Pure helpers

    /// Overlap in seconds between two wall-clock ranges. Zero when disjoint.
    public static func overlapSeconds(_ a: ClosedRange<Date>, _ b: ClosedRange<Date>) -> Double {
        let lo = max(a.lowerBound, b.lowerBound)
        let hi = min(a.upperBound, b.upperBound)
        return max(0, hi.timeIntervalSince(lo))
    }

    private func overlapSeconds(_ a: ClosedRange<Date>, _ b: ClosedRange<Date>) -> Double {
        EchoFilter.overlapSeconds(a, b)
    }

    /// lowercased, punctuation stripped, whitespace collapsed.
    public static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == " " ? Character($0) : " " }
        let collapsed = String(stripped).split(separator: " ").joined(separator: " ")
        return collapsed
    }

    private func normalize(_ text: String) -> String { EchoFilter.normalize(text) }

    public static func tokenize(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    private func tokenize(_ normalized: String) -> [String] { EchoFilter.tokenize(normalized) }

    public static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 0 }
        let intersection = a.intersection(b).count
        let union = a.union(b).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }

    private func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double { EchoFilter.jaccard(a, b) }
}
