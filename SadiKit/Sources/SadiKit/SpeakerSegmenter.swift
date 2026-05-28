import Foundation

/// Per-token timing the ASR returns alongside text. Mirrors FluidAudio's
/// `TokenTiming` but is FluidAudio-free so SadiKit stays a pure library.
public struct TimedToken: Hashable, Sendable {
    /// Raw token form — may include SentencePiece-style `▁` word-boundary
    /// markers (Parakeet) which the run-text builder converts to spaces.
    public let text: String
    /// Start time of this token, in seconds relative to the segment.
    public let startTime: Double
    /// End time, in seconds relative to the segment.
    public let endTime: Double

    public init(text: String, startTime: Double, endTime: Double) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// One maximal span of consecutive tokens that the diarizer assigned to a
/// single speaker cluster.
public struct SpeakerRun: Hashable, Sendable {
    public let speakerIndex: Int
    public let tokens: [TimedToken]

    public var startTime: Double { tokens.first?.startTime ?? 0 }
    public var endTime: Double { tokens.last?.endTime ?? 0 }
    public var text: String { SpeakerSegmenter.joinTokenText(tokens) }
}

/// Split a single VAD-emitted ASR result into one `SpeakerRun` per speaker
/// turn. The pipeline is: VAD → one segment → one ASR pass (yields token
/// timings) → SpeakerSegmenter → N speaker-coherent runs → ASR text per run.
///
/// SPEC §6.2 / §6.4: VAD only splits on silence and rapid back-and-forth
/// conversation produces single merged segments with multiple speakers. The
/// diarizer can tell us *who* is talking at any time; this helper bridges
/// the two so a merged VAD segment can be emitted as multiple Utterances.
public enum SpeakerSegmenter {
    /// Build runs of consecutive same-speaker tokens.
    ///
    /// - Parameters:
    ///   - tokens: Per-token timings from the ASR.
    ///   - speakerAt: Lookup that returns the dominant speaker cluster id at
    ///     a given time (seconds relative to the same anchor as the tokens).
    ///     Return `nil` when the diarizer can't pin one (silence, low
    ///     confidence) — those tokens stick with the neighbor on either side.
    ///   - minTokensPerRun: Smoothing threshold. After the initial group, any
    ///     run shorter than this gets merged into the larger adjacent run.
    ///     Suppresses single-token attribution flickers near speaker
    ///     boundaries. Set to 1 to disable smoothing.
    public static func splitIntoRuns(
        tokens: [TimedToken],
        speakerAt: (Double) -> Int?,
        minTokensPerRun: Int = 3
    ) -> [SpeakerRun] {
        guard !tokens.isEmpty else { return [] }

        // 1. Initial assignment: per-token speaker (using midpoint for the
        // diarizer query so token-edge jitter doesn't dominate).
        var initial: [(speaker: Int?, token: TimedToken)] = tokens.map { tok in
            let midpoint = (tok.startTime + tok.endTime) / 2
            return (speakerAt(midpoint), tok)
        }

        // 2. Fill unknowns: a token whose speaker query returned nil takes the
        // most recent resolved speaker; if there's no left context, take the
        // first resolved right-side neighbor.
        var lastKnown: Int?
        for i in initial.indices {
            if initial[i].speaker == nil {
                initial[i].speaker = lastKnown
            } else {
                lastKnown = initial[i].speaker
            }
        }
        // backfill leading nils
        if initial.first?.speaker == nil, let firstResolved = initial.first(where: { $0.speaker != nil })?.speaker {
            for i in initial.indices where initial[i].speaker == nil {
                initial[i].speaker = firstResolved
            }
        }

        // 3. Group into raw runs.
        var raw: [(speaker: Int, tokens: [TimedToken])] = []
        for (spk, tok) in initial {
            let speaker = spk ?? raw.last?.speaker ?? 0
            if let last = raw.last, last.speaker == speaker {
                raw[raw.count - 1].tokens.append(tok)
            } else {
                raw.append((speaker, [tok]))
            }
        }

        // 4. Smoothing pass: short runs get absorbed into the bigger neighbor.
        if minTokensPerRun > 1 {
            var changed = true
            while changed && raw.count > 1 {
                changed = false
                for i in raw.indices {
                    guard raw[i].tokens.count < minTokensPerRun else { continue }
                    let leftCount = i > 0 ? raw[i - 1].tokens.count : 0
                    let rightCount = i < raw.count - 1 ? raw[i + 1].tokens.count : 0
                    if leftCount == 0 && rightCount == 0 { continue }
                    let mergeRight = rightCount >= leftCount
                    if mergeRight, i < raw.count - 1 {
                        let absorbed = raw[i].tokens
                        raw[i + 1] = (raw[i + 1].speaker, absorbed + raw[i + 1].tokens)
                        raw.remove(at: i)
                    } else if !mergeRight, i > 0 {
                        let absorbed = raw[i].tokens
                        raw[i - 1] = (raw[i - 1].speaker, raw[i - 1].tokens + absorbed)
                        raw.remove(at: i)
                    } else {
                        continue
                    }
                    changed = true
                    break
                }
            }
            // Coalesce any same-speaker neighbors that smoothing created.
            var coalesced: [(speaker: Int, tokens: [TimedToken])] = []
            for run in raw {
                if let last = coalesced.last, last.speaker == run.speaker {
                    coalesced[coalesced.count - 1] = (last.speaker, last.tokens + run.tokens)
                } else {
                    coalesced.append(run)
                }
            }
            raw = coalesced
        }

        return raw.map { SpeakerRun(speakerIndex: $0.speaker, tokens: $0.tokens) }
    }

    /// Reconstruct cleaned text from a token list using SentencePiece's
    /// `▁` → space convention (same as FluidAudio's internal vocab join).
    public static func joinTokenText(_ tokens: [TimedToken]) -> String {
        let joined = tokens.map(\.text).joined()
        return joined
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
