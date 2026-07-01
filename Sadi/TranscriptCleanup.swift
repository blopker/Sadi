import Foundation
import OSLog
import SadiKit

/// Optional LLM cleanup pass over a finalized transcript: removes filler /
/// disfluencies and fixes obvious mis-transcriptions, producing a parallel set
/// of utterances with `text` rewritten (everything else preserved).
///
/// Strategy is "chunked-whole" — the whole transcript is the ideal unit for
/// cross-line consistency (one canonical spelling for a name, etc.), but a
/// single call doesn't scale to thousands of lines, so it's split into large
/// chunks processed concurrently. Each chunk is sent as numbered lines and
/// parsed back by index; any line the model drops falls back to its raw text,
/// so the result is always 1:1 with the input (the detail view can toggle
/// between raw and cleaned line-for-line). Callers gate on
/// `LLMSettings.currentIfConfigured()` — `config` is assumed usable here.
/// Throws on a hard failure (server error / cancellation) so the caller can
/// skip writing and leave any existing cleaned copy untouched.
nonisolated enum TranscriptCleanup {
    private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "cleanup")

    /// Lines per request. Large enough for in-chunk consistency, small enough
    /// to keep each generation well under the model's output ceiling.
    private static let chunkSize = 160
    /// Concurrent in-flight requests — the MoE server batches these, so a few
    /// at once is markedly faster than sequential without overrunning it.
    private static let maxConcurrent = 4

    private static let system =
        "You clean up verbatim speech-to-text transcripts. Remove filler words and disfluencies "
        + "(um, uh, 'you know', repeated words, false starts) and fix obvious mis-transcriptions "
        + "using context. Preserve the speaker's meaning, wording, and tone. Do not summarize, "
        + "shorten, paraphrase heavily, or add information."

    static func run(
        utterances: [Utterance],
        config: LLMSettings.Config,
        progress: @escaping @MainActor (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> [Utterance] {
        guard !utterances.isEmpty else { return utterances }

        let chunks = stride(from: 0, to: utterances.count, by: chunkSize).map {
            Array($0..<min($0 + chunkSize, utterances.count))
        }
        await progress(0, chunks.count)

        var cleaned: [Int: String] = [:]
        var done = 0
        try await withThrowingTaskGroup(of: [Int: String].self) { group in
            var iterator = chunks.makeIterator()
            var inFlight = 0
            func submitNext() {
                guard let chunk = iterator.next() else { return }
                inFlight += 1
                group.addTask { try await cleanChunk(chunk, utterances: utterances, config: config) }
            }
            for _ in 0..<maxConcurrent { submitNext() }
            while inFlight > 0, let partial = try await group.next() {
                inFlight -= 1
                cleaned.merge(partial) { _, new in new }
                done += 1
                // Awaited main-actor hop, so ticks can't render out of order.
                await progress(done, chunks.count)
                submitNext()
            }
        }

        // Stitch: rewritten text where the model returned a non-empty line,
        // raw text otherwise. `text` is immutable, so rebuild via init —
        // dropping wordTimings, which no longer match the rewritten words.
        return utterances.enumerated().map { index, u in
            guard let text = cleaned[index], !text.isEmpty, text != u.text else { return u }
            return Utterance(
                id: u.id, source: u.source, speaker: u.speaker, text: text,
                startedAt: u.startedAt, endedAt: u.endedAt, embedding: u.embedding,
                asrConfidence: u.asrConfidence, rms: u.rms, diarCluster: u.diarCluster,
                wordTimings: nil, assignmentKind: u.assignmentKind,
                embeddingAmbiguous: u.embeddingAmbiguous)
        }
    }

    /// Clean one chunk; returns a map of global utterance index → cleaned text.
    private static func cleanChunk(
        _ indices: [Int], utterances: [Utterance], config: LLMSettings.Config
    ) async throws -> [Int: String] {
        try Task.checkCancellation()
        let body = indices.map { "\($0): \(utterances[$0].text)" }.joined(separator: "\n")
        let user =
            "Clean every numbered line. Return the SAME numbered lines, one per line, as "
            + "\"<number>: <cleaned text>\" — same count and order, do not merge or drop lines.\n\n"
            + body
        let out = try await LLMClient.complete(
            config: config, system: system, user: user, maxTokens: 16_000)

        // Only accept this chunk's own line numbers — a hallucinated index
        // must not clobber another chunk's output in the shared map.
        let valid = Set(indices)
        var map: [Int: String] = [:]
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":"),
                let index = Int(line[..<colon].trimmingCharacters(in: .whitespaces)),
                valid.contains(index)
            else { continue }
            map[index] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return map
    }
}
