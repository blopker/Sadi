import AVFoundation
import FluidAudio
import Foundation
import SadiKit

// MARK: - CLI

struct CLI {
    let sessionDir: URL
    let cacheDir: URL
    let voiceprintsURL: URL
}

func parseCLI() throws -> CLI {
    let args = CommandLine.arguments
    var sessionArg: String?
    var cacheArg: String?
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--cache":
            i += 1
            cacheArg = i < args.count ? args[i] : nil
        case "--help", "-h":
            print(usage)
            exit(0)
        default:
            sessionArg = args[i]
        }
        i += 1
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let containerSupport = home
        .appending(path: "Library/Containers/io.kbl.sadi.Sadi/Data/Library/Application Support", directoryHint: .isDirectory)
    let recordingsRoot = containerSupport.appending(path: "Sadi/Recordings", directoryHint: .isDirectory)

    let cache = cacheArg
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? containerSupport.appending(path: "FluidAudio", directoryHint: .isDirectory)

    let voiceprints = containerSupport
        .appending(path: "Sadi/Voiceprints/book.json", directoryHint: .notDirectory)

    let session: URL
    if let arg = sessionArg {
        let asPath = URL(fileURLWithPath: arg, isDirectory: true)
        if FileManager.default.fileExists(atPath: asPath.path(percentEncoded: false)) {
            session = asPath
        } else {
            session = recordingsRoot.appending(path: arg, directoryHint: .isDirectory)
        }
    } else {
        session = try newestSession(in: recordingsRoot)
    }
    return CLI(sessionDir: session, cacheDir: cache, voiceprintsURL: voiceprints)
}

let usage = """
pipetest — replay a captured session through the full v1 transcription
pipeline (VAD + ASR + LS-EEND diarization + WeSpeaker embedding +
EchoFilter + voiceprint resolution).

USAGE:
  pipetest [SESSION_ID_OR_PATH] [--cache PATH]

Defaults:
  SESSION_ID_OR_PATH  newest session under
                      ~/Library/Containers/io.kbl.sadi.Sadi/Data/Library/Application Support/Sadi/Recordings/
  --cache             ~/Library/Containers/io.kbl.sadi.Sadi/Data/Library/Application Support/FluidAudio

Voiceprints book is read (read-only) from the same sandbox path the live
app writes to:
  ~/Library/Containers/io.kbl.sadi.Sadi/Data/Library/Application Support/Sadi/Voiceprints/book.json
"""

func newestSession(in root: URL) throws -> URL {
    let fm = FileManager.default
    let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    let sessions = entries
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .filter { $0.lastPathComponent.hasPrefix("2026-") || $0.lastPathComponent.hasPrefix("2027-") }
    guard let newest = sessions.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
        struct NoSession: Error {}
        throw NoSession()
    }
    return newest
}

// MARK: - Audio decode

func decodeMonoFloat16kHz(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let inputFormat = file.processingFormat
    guard let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ) else {
        struct FormatFail: Error {}
        throw FormatFail()
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        struct ConvFail: Error {}
        throw ConvFail()
    }

    let inputCapacity: AVAudioFrameCount = 8192
    guard let inputBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
        struct BufFail: Error {}
        throw BufFail()
    }

    let ratio = 16_000 / inputFormat.sampleRate
    let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * ratio + 1024)
    guard let outputBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
        struct BufFail: Error {}
        throw BufFail()
    }

    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(file.length) * ratio + 1024))

    var done = false
    while !done {
        do {
            try file.read(into: inputBuf)
        } catch {
            break
        }
        if inputBuf.frameLength == 0 { done = true }

        let inputProvided = AtomicBool()
        var error: NSError?
        let status = converter.convert(to: outputBuf, error: &error) { _, status in
            if inputProvided.value || inputBuf.frameLength == 0 {
                status.pointee = .noDataNow
                return nil
            }
            inputProvided.value = true
            status.pointee = .haveData
            return inputBuf
        }
        if status == .error { throw error ?? NSError(domain: "convert", code: -1) }

        let n = Int(outputBuf.frameLength)
        if n > 0, let ch = outputBuf.floatChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        }
        if status == .endOfStream { done = true }
    }
    return samples
}

final class AtomicBool: @unchecked Sendable {
    var value = false
}

// MARK: - Session id timestamp

func parseSessionStart(from id: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    return formatter.date(from: id) ?? Date()
}

// MARK: - Speaker resolution helpers
//
// MIRROR of Sadi/StreamProcessor.resolveSpeaker. Keep this in sync with the
// live pipeline. We can't reuse the app's StreamProcessor here because it
// lives in the app target (where FluidAudio is wired) and pipetest is a
// standalone executable.

/// Map a cluster id to the visible speaker label. MIRRORS the live
/// `StreamProcessor.label`: system gets a `.them` placeholder only — final
/// `.them`/`.remote(N)` numbering is derived later from the set of clusters
/// across all system utterances (see `labelSystemUtterances`, mirroring
/// TranscriptStore). Mic-only multi-speaker numbering stays here.
func speakerLabelFor(
    source: Source,
    clusterID: Int?,
    timeline: DiarizerTimeline
) -> SadiKit.Speaker {
    switch source {
    case .system:
        return .them
    case .mic:
        let speakers = timeline.speakers
        guard !speakers.isEmpty, let cid = clusterID else { return .localSpeaker(1) }
        let displayIndex = (speakers.keys.sorted().firstIndex(of: cid) ?? 0) + 1
        return .localSpeaker(displayIndex)
    }
}

/// MIRROR of TranscriptStore's system relabel: derive `.them`/`.remote(N)`
/// from the distinct diarizer clusters seen across all system utterances.
/// One distinct cluster → `.them`; two or more → `.remote(rank+1)`.
func labelSystemUtterances(_ system: [Utterance]) -> [Utterance] {
    let distinct = Set(system.compactMap { $0.diarCluster })
    return system.map { u in
        var copy = u
        copy.speaker = .remoteLabel(forCluster: u.diarCluster, among: distinct)
        return copy
    }
}

/// Dominant cluster id within a time range (used as fallback when no token
/// timings are available).
func dominantCluster(
    diarizer: LSEENDDiarizer,
    startSec: Double,
    endSec: Double
) -> Int? {
    let frameDur = Double(diarizer.modelFrameHz.map { 1 / $0 } ?? 0.1)
    var overlap: [Int: Int] = [:]
    for (idx, speaker) in diarizer.timeline.speakers {
        for seg in speaker.finalizedSegments + speaker.tentativeSegments {
            let segStartSec = Double(seg.startFrame) * frameDur
            let segEndSec = Double(seg.endFrame) * frameDur
            let lo = max(segStartSec, startSec)
            let hi = min(segEndSec, endSec)
            if hi > lo { overlap[idx, default: 0] += Int((hi - lo) / frameDur) }
        }
    }
    return overlap.max(by: { $0.value < $1.value })?.key
}

/// Speaker cluster at a specific instant (used per token by SpeakerSegmenter).
func clusterAtInstant(
    diarizer: LSEENDDiarizer,
    timeSec: Double
) -> Int? {
    let frameDur = Double(diarizer.modelFrameHz.map { 1 / $0 } ?? 0.1)
    let frame = Int(timeSec / frameDur)
    for (idx, speaker) in diarizer.timeline.speakers {
        for seg in speaker.finalizedSegments + speaker.tentativeSegments {
            if seg.startFrame <= frame && frame <= seg.endFrame {
                return idx
            }
        }
    }
    return nil
}

// MARK: - Per-track pipeline

struct TrackResult {
    let label: String
    let utterances: [Utterance]
    let sampleCount: Int
}

func processTrack(
    url: URL,
    source: Source,
    label: String,
    sessionStart: Date,
    vad: VadManager,
    asr: AsrManager,
    embedder: DiarizerManager,
    lseendModel: LSEENDModel
) async throws -> TrackResult {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
        print("  \(label): missing \(url.lastPathComponent), skipping.")
        return TrackResult(label: label, utterances: [], sampleCount: 0)
    }
    print("\n\(label) ► decoding \(url.lastPathComponent)…")
    let samples = try decodeMonoFloat16kHz(url)
    let durationSec = Double(samples.count) / 16_000
    print("  \(label): \(samples.count) samples (\(String(format: "%.1f", durationSec)) s)")

    let segments = try await vad.segmentSpeech(samples)
    print("  \(label): VAD → \(segments.count) speech segments")

    // Feed full audio to a fresh diarizer for this track, in chunks. The
    // diarizer accepts any chunk size; 1 s chunks let us call
    // finalizeSession() afterwards to flush right-context padding.
    let diarizer = try LSEENDDiarizer(model: lseendModel)
    let diarChunk = 16_000
    var pos = 0
    while pos < samples.count {
        let end = min(pos + diarChunk, samples.count)
        let chunk = Array(samples[pos..<end])
        _ = try diarizer.process(samples: chunk, sourceSampleRate: 16_000.0)
        pos = end
    }
    _ = try diarizer.finalizeSession()
    print("  \(label): diarizer → \(diarizer.timeline.speakers.count) speaker clusters")

    // Per segment: ASR once, then split into speaker-coherent runs via the
    // SadiKit SpeakerSegmenter, emitting one Utterance per run.
    var utterances: [Utterance] = []
    for seg in segments {
        let startIdx = seg.startSample(sampleRate: 16_000)
        let endIdx = seg.endSample(sampleRate: 16_000)
        guard endIdx > startIdx, endIdx <= samples.count else { continue }
        guard endIdx - startIdx >= 4_800 else { continue } // 300 ms min

        let slice = Array(samples[startIdx..<endIdx])
        let segmentStartSec = seg.startTime

        var state = try TdtDecoderState()
        let result: ASRResult
        do {
            result = try await asr.transcribe(slice, decoderState: &state)
        } catch {
            print("  \(label): ASR failed @\(String(format: "%.1f", segmentStartSec))s: \(error)")
            continue
        }
        let fullText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if fullText.isEmpty { continue }

        // No token timings → fallback to single Utterance with dominant speaker.
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            utterances.append(buildUtterance(
                source: source,
                text: fullText,
                segmentSlice: slice,
                segmentStartSec: segmentStartSec,
                runStartSec: segmentStartSec,
                runEndSec: seg.endTime,
                sessionStart: sessionStart,
                cluster: dominantCluster(diarizer: diarizer, startSec: segmentStartSec, endSec: seg.endTime),
                diarizer: diarizer,
                confidence: result.confidence,
                embedder: embedder,
                runAudio: slice,
                fallback: true
            ))
            continue
        }

        // Group Parakeet's SentencePiece subword tokens into whole words
        // before handing to the segmenter. A word starts at a token whose
        // raw text begins with `▁`; subsequent tokens without that prefix
        // are continuations. This avoids mid-word speaker splits and gives
        // the segmenter coarser, more diarization-stable units.
        let words = groupTokensIntoWords(timings)
        let runs = SpeakerSegmenter.splitIntoRuns(
            tokens: words,
            speakerAt: { wordTimeRelative in
                let absolute = segmentStartSec + wordTimeRelative
                return clusterAtInstant(diarizer: diarizer, timeSec: absolute)
            },
            minTokensPerRun: 2
        )
        _ = timings // suppress unused warning

        for run in runs {
            let runText = run.text
            if runText.isEmpty { continue }
            let runStartIdx = max(0, Int(run.startTime * 16_000))
            let runEndIdx = min(slice.count, Int(run.endTime * 16_000))
            let runAudio = runEndIdx > runStartIdx
                ? Array(slice[runStartIdx..<runEndIdx])
                : slice

            utterances.append(buildUtterance(
                source: source,
                text: runText,
                segmentSlice: slice,
                segmentStartSec: segmentStartSec,
                runStartSec: segmentStartSec + run.startTime,
                runEndSec: segmentStartSec + run.endTime,
                sessionStart: sessionStart,
                cluster: run.speakerIndex,
                diarizer: diarizer,
                confidence: result.confidence,
                embedder: embedder,
                runAudio: runAudio,
                fallback: false
            ))
        }
    }
    print("  \(label): \(utterances.count) non-empty utterances")
    return TrackResult(label: label, utterances: utterances, sampleCount: samples.count)
}

/// Collapse Parakeet's subword tokens into whole words. FluidAudio's
/// `AsrManager` runs each token's text through `normalizedTimingToken`,
/// which already converts the SentencePiece `▁` marker to a leading space —
/// so a word starts at any token whose text begins with " ". Continuations
/// (contractions, common subword pieces) lack the leading space and get
/// appended to the current word.
func groupTokensIntoWords(_ timings: [TokenTiming]) -> [TimedToken] {
    var words: [TimedToken] = []
    var currentTexts: [String] = []
    var currentStart: TimeInterval = 0
    var currentEnd: TimeInterval = 0
    for tt in timings {
        // Either form, in case a future FluidAudio version stops normalizing.
        let startsWord = tt.token.hasPrefix(" ") || tt.token.hasPrefix("▁")
        if startsWord && !currentTexts.isEmpty {
            words.append(TimedToken(
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
        words.append(TimedToken(
            text: currentTexts.joined(),
            startTime: currentStart,
            endTime: currentEnd
        ))
    }
    return words
}

/// Build one Utterance from a speaker-coherent run (or a fallback segment).
func buildUtterance(
    source: Source,
    text: String,
    segmentSlice: [Float],
    segmentStartSec: Double,
    runStartSec: Double,
    runEndSec: Double,
    sessionStart: Date,
    cluster: Int?,
    diarizer: LSEENDDiarizer,
    confidence: Float?,
    embedder: DiarizerManager,
    runAudio: [Float],
    fallback: Bool
) -> Utterance {
    var sumSq: Float = 0
    for v in runAudio { sumSq += v * v }
    let rms = runAudio.isEmpty ? Float(0) : (sumSq / Float(runAudio.count)).squareRoot()

    let embedding: [Float]?
    if runAudio.count >= 4_800 {  // 300 ms minimum for a stable embedding
        embedding = try? embedder.extractSpeakerEmbedding(from: runAudio)
    } else {
        // Run too short for a per-run embedding — fall back to the full segment.
        embedding = try? embedder.extractSpeakerEmbedding(from: segmentSlice)
    }

    let speaker = speakerLabelFor(source: source, clusterID: cluster, timeline: diarizer.timeline)
    return Utterance(
        source: source,
        speaker: speaker,
        text: text,
        startedAt: sessionStart.addingTimeInterval(runStartSec),
        endedAt: sessionStart.addingTimeInterval(runEndSec),
        embedding: embedding,
        asrConfidence: confidence,
        rms: rms,
        diarCluster: cluster
    )
}

// MARK: - Output

func speakerLabel(_ speaker: SadiKit.Speaker) -> String {
    switch speaker {
    case .you: return "You"
    case .them: return "Them"
    case .remote(let n): return "Remote \(n)"
    case .localSpeaker(let n): return "Speaker \(n)"
    case .named(let name, _): return name
    }
}

@MainActor
func printRow(_ u: Utterance, marker: String, trailer: String = "") {
    let tag = u.source == .mic ? "MIC" : "SYS"
    let trail = trailer.isEmpty ? "" : " \(trailer)"
    let speaker = speakerLabel(u.speaker)
    let hasEmbed = u.embedding != nil ? "e" : "·"
    print("  \(marker) [\(tag) \(String(format: "rms=%.3f", u.rms ?? 0)) \(hasEmbed)] [\(speaker)]\(trail) \(u.text)")
}

// MARK: - Main

@main
struct PipeTest {
    @MainActor
    static func main() async throws {
        let cli = try parseCLI()
        let sessionID = cli.sessionDir.lastPathComponent
        let sessionStart = parseSessionStart(from: sessionID)

        let micURL = cli.sessionDir.appending(path: "mic-001.mp4", directoryHint: .notDirectory)
        let systemURL = cli.sessionDir.appending(path: "system-001.mp4", directoryHint: .notDirectory)

        print("Session: \(sessionID)")
        print("  dir:    \(cli.sessionDir.path(percentEncoded: false))")
        print("  cache:  \(cli.cacheDir.path(percentEncoded: false))")
        print("  book:   \(cli.voiceprintsURL.path(percentEncoded: false))")

        // 1. Load models.
        print("\nLoading models from cache…")
        let vad = try await VadManager(modelDirectory: cli.cacheDir)
        let parakeetDir = cli.cacheDir.appending(path: "Models/parakeet-tdt-0.6b-v2", directoryHint: .isDirectory)
        let asrModels = try await AsrModels.load(from: parakeetDir, version: .v2)
        let asr = AsrManager(config: .default, models: asrModels)

        // LSEENDModel.loadFromHuggingFace appends `<repo.folderName>/<file>`
        // to `cacheDirectory`, so this must point at the `Models/` directory
        // where the app already stores it (e.g. .../FluidAudio/Models/).
        let modelsDir = cli.cacheDir.appending(path: "Models", directoryHint: .isDirectory)
        let lseend = try await LSEENDModel.loadFromHuggingFace(
            variant: .dihard3,
            stepSize: .step100ms,
            cacheDirectory: modelsDir
        )

        let diarCache = cli.cacheDir.appending(path: "Models/speaker-diarization", directoryHint: .isDirectory)
        let diarModels = try await DiarizerModels.load(from: diarCache)
        let embedder = DiarizerManager(config: .default)
        embedder.initialize(models: consume diarModels)

        let book = VoiceprintBook(
            storeURL: cli.voiceprintsURL,
            modelVersion: "fluidaudio-wespeaker-256d-v1"
        )
        print("Models ready. Voiceprints loaded: \(book.prints.count) (\(book.prints.map(\.name).sorted().joined(separator: ", ")))")

        // 2. Per-track processing.
        let micResult = try await processTrack(
            url: micURL, source: .mic, label: "MIC",
            sessionStart: sessionStart, vad: vad, asr: asr,
            embedder: embedder, lseendModel: lseend
        )
        let sysResult = try await processTrack(
            url: systemURL, source: .system, label: "SYS",
            sessionStart: sessionStart, vad: vad, asr: asr,
            embedder: embedder, lseendModel: lseend
        )

        // 3. Cross-track: call mode, echo filter, voiceprint match.
        // Derive final system `.them`/`.remote(N)` numbering from the full set
        // of system clusters (mirrors TranscriptStore's retroactive relabel).
        let systemLabeled = labelSystemUtterances(sysResult.utterances)
        let allUtterances = (micResult.utterances + systemLabeled)
            .sorted { $0.startedAt < $1.startedAt }
        let callMode = !systemLabeled.isEmpty
        let filter = EchoFilter()
        let systemAll = systemLabeled

        var kept: [Utterance] = []
        var dropped: [(Utterance, EchoFilter.DropReason)] = []

        for u in allUtterances {
            if u.source == .system {
                kept.append(applyVoiceprint(u, book: book))
                continue
            }
            // mic
            if !callMode {
                // Mic-only mode: keep .localSpeaker label intact.
                kept.append(applyVoiceprint(u, book: book))
                continue
            }
            // Call mode: filter for bleed; survivors collapse to .you.
            switch filter.decide(mic: u, system: systemAll) {
            case .keep:
                var collapsed = u
                collapsed.speaker = .you
                kept.append(applyVoiceprint(collapsed, book: book))
            case .drop(let r):
                dropped.append((u, r))
            }
        }

        // 4. Output.
        let micKept = kept.filter { $0.source == .mic }.count
        let micDropped = dropped.count
        let sysKept = kept.filter { $0.source == .system }.count
        let mode = callMode ? "call" : "mic-only"

        print("\n────── Kept (\(kept.count)) ──────")
        for u in kept { printRow(u, marker: "✓") }

        if !dropped.isEmpty {
            print("\n────── Dropped (\(dropped.count)) ──────")
            for (u, r) in dropped { printRow(u, marker: "✗", trailer: "[\(r.rawValue)]") }
        }

        print("""

        ────── Summary ──────
        mode:              \(mode)
        mic    utterances: \(micResult.utterances.count) → kept \(micKept), dropped \(micDropped)
        system utterances: \(sysResult.utterances.count) → kept \(sysKept)
        voiceprint hits:   \(kept.filter { if case .named = $0.speaker { return true } else { return false } }.count)
        """)
    }

    @MainActor
    static func applyVoiceprint(_ u: Utterance, book: VoiceprintBook) -> Utterance {
        guard let embedding = u.embedding,
              let match = book.match(embedding: embedding)
        else { return u }
        var copy = u
        copy.speaker = .named(match.voiceprint.name, match.voiceprint.id)
        return copy
    }
}
