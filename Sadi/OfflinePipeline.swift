import AVFoundation
import FluidAudio
import Foundation
import OSLog
import SadiKit

/// Post-recording transcript passes over a finalized session directory. Two
/// modes sharing one tail:
///
///   finalize — keep the draft transcript's text/timings (the live pipeline
///       already uses the batch ASR model per segment) and re-derive the
///       quality-critical rest: offline diarization (AHC+VBx+PLDA clustering
///       over the whole file, far better than live LS-EEND), voiceprint
///       matching per *cluster* instead of per utterance, and a deterministic
///       echo pass over the complete mic/system sets. Seconds of work.
///
///   rerun — regenerate everything from the audio: whole-file VAD
///       segmentation → batch ASR with word timings → the same tail. For
///       blank/lost transcripts and "regenerate from audio". Minutes of work.
///
/// Both honor the `AssignmentKind` contract: utterances the user pinned
/// (`.manual`) are never relabeled and never dropped by the echo pass.
///
/// The offline diarizer's embeddings live in a different space than our
/// WeSpeaker voiceprints (different CoreML export), so it contributes cluster
/// *boundaries only*; identification re-extracts WeSpeaker embeddings from
/// each cluster's cleanest windows via the same `extractSpeakerEmbedding` the
/// live pipeline uses, keeping the voiceprint book in one embedding space.
@MainActor
enum OfflinePipeline {
    enum Mode: String, Sendable {
        case finalize
        case rerun
    }

    struct Outcome: Sendable {
        let mode: Mode
        let utteranceCount: Int
        let droppedAsEcho: Int
        let voiceprintHits: Int
    }

    enum Failure: Error, LocalizedError {
        case noSessionMetadata
        case noAudio
        case modelsNotLoaded
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSessionMetadata: "No session.json in the recording directory."
            case .noAudio: "No audio tracks found for this recording."
            case .modelsNotLoaded: "Transcription models are not loaded."
            case .decodeFailed(let detail): "Audio decode failed: \(detail)"
            }
        }
    }

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "offline")

    /// Off-main hop that *forwards cancellation*: `Task.detached` deliberately
    /// doesn't inherit the awaiting task's cancellation, so without this a
    /// cancelled pass would keep diarizing/transcribing to completion in the
    /// background. Used for every interruptible stage; the final saves go
    /// through the file coordinator and a plain detached task, neither of
    /// which observes cancellation, so a last-instant cancel can't tear them.
    nonisolated private static func hop<T: Sendable>(
        _ body: @escaping @Sendable @concurrent () async throws -> T
    ) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: body)
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Entry point

    static func run(
        mode: Mode,
        sessionDirectory: URL,
        modelHost: ModelHost,
        voiceprints: VoiceprintBook,
        llmConfig: LLMSettings.Config? = nil,
        progress: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> Outcome {
        guard let embedder = modelHost.embeddingDiarizer,
              let vad = modelHost.vad,
              let asr = modelHost.asr
        else { throw Failure.modelsNotLoaded }

        progress("Reading session…")
        var session = try await hop {
            try readSession(in: sessionDirectory)
        }
        guard let segment = session.segments.first else { throw Failure.noSessionMetadata }

        // Offline diarizer models — lazy, may download on first use. NOT
        // routed through `hop`: the load task is shared/memoized, and one
        // cancelled pass must not abort it for the next.
        progress("Loading offline diarizer…")
        let offlineModels = try await modelHost.loadOfflineDiarizerModels()
        try Task.checkCancellation()

        progress("Decoding audio…")
        let sessionStart = session.startedAt
        var tracks = try await hop {
            try await decodeTracks(segment: segment, sessionStart: sessionStart, directory: sessionDirectory)
        }
        guard !tracks.isEmpty else { throw Failure.noAudio }

        // Acoustic echo cancellation over the decoded mic track, system track
        // as the far-end reference — the same LocalVQE stage the live pipeline
        // runs, applied batch and BEFORE diarization so echo can't seed
        // phantom mic clusters or pollute embeddings. Archives are raw, so
        // every pass re-derives the cleaned mic from scratch (benefiting from
        // whatever model ships at that time). Best-effort: without the engine
        // the pass proceeds on raw mic + the text-level echo filter.
        if let aec = modelHost.aec,
           let micIdx = tracks.firstIndex(where: { $0.source == .mic }),
           let sys = tracks.first(where: { $0.source == .system }) {
            progress("Cancelling echo…")
            let micTrack = tracks[micIdx]
            let cleaned = try await hop {
                let canceller = EchoCanceller(engine: aec)
                await canceller.feedReference(sys.samples, anchor: sys.anchor)
                var out = await canceller.processMic(micTrack.samples, anchor: micTrack.anchor)
                out += await canceller.flushMic()
                return out
            }
            tracks[micIdx] = Track(source: .mic, anchor: micTrack.anchor, samples: cleaned)
        }

        // Post-AEC track set is immutable from here; snapshot for the
        // Sendable hop closures.
        let finalTracks = tracks

        progress("Diarizing…")
        let diar = try await hop {
            try await diarize(tracks: finalTracks, models: offlineModels)
        }

        // The utterance set: draft from disk (finalize) or from audio (rerun).
        var utterances: [Utterance]
        switch mode {
        case .finalize:
            utterances = try await hop {
                RecordingsStore.loadTranscript(from: sessionDirectory)
            }
        case .rerun:
            // Manual pins survive a full rerun: carry them over from the old
            // transcript verbatim; freshly transcribed utterances that overlap
            // a pinned one substantially are skipped to avoid duplicates.
            let pinned = try await hop {
                RecordingsStore.loadTranscript(from: sessionDirectory)
                    .filter { $0.assignmentKind == .manual }
            }

            progress("Transcribing…")
            // Both tracks at once; each track internally fans its segments
            // out over an ASR worker pool (see `transcribe`).
            let diarSnapshot = diar
            let trackSnapshot = finalTracks
            let fresh = try await hop {
                try await withThrowingTaskGroup(of: [Utterance].self) { group in
                    for track in trackSnapshot {
                        group.addTask {
                            try await transcribe(
                                track: track, diar: diarSnapshot[track.source] ?? [],
                                vad: vad, asr: asr, embedder: embedder)
                        }
                    }
                    var all: [Utterance] = []
                    for try await result in group { all.append(contentsOf: result) }
                    return all
                }
            }
            utterances = pinned + fresh.filter { u in
                !pinned.contains { p in
                    p.source == u.source
                        && EchoFilter.overlapSeconds(
                            p.startedAt...max(p.startedAt, p.endedAt),
                            u.startedAt...max(u.startedAt, u.endedAt)) > 0.5
                }
            }
        }
        try Task.checkCancellation()

        // Tail: clusters → labels → voiceprints → echo. Pure value passes.
        utterances = reassignClusters(utterances, diar: diar, tracks: finalTracks)
        utterances = relabel(utterances)

        progress("Matching voiceprints…")
        let centroids = try await hop {
            clusterCentroids(tracks: finalTracks, diar: diar, embedder: embedder)
        }
        // Apply matches system-first so the mic pass can ask "is this
        // identity a far-end speaker?" against final system labels. A mic
        // utterance matching a far-end print without overlapping system
        // speech is a mis-match, not bleed — keep its track label instead of
        // mislabeling the local user as the remote person (SpeakerSanity).
        var voiceprintHits = 0
        let matches = centroids.compactMapValues { voiceprints.match(embedding: $0) }
        for (key, match) in matches where key.source == .system {
            for i in utterances.indices
            where utterances[i].source == .system
                && utterances[i].diarCluster == key.cluster
                && utterances[i].assignmentKind != .manual {
                utterances[i].speaker = .named(match.voiceprint.name, match.voiceprint.id)
                utterances[i].assignmentKind = .matched
                voiceprintHits += 1
            }
        }
        let systemUtterances = utterances.filter { $0.source == .system }
        for (key, match) in matches where key.source == .mic {
            for i in utterances.indices
            where utterances[i].source == .mic
                && utterances[i].diarCluster == key.cluster
                && utterances[i].assignmentKind != .manual {
                guard !SpeakerSanity.isImplausibleMicMatch(
                    utterances[i], voiceprintID: match.voiceprint.id,
                    systemUtterances: systemUtterances)
                else { continue }
                utterances[i].speaker = .named(match.voiceprint.name, match.voiceprint.id)
                utterances[i].assignmentKind = .matched
                voiceprintHits += 1
            }
        }

        progress("Echo filtering…")
        let (kept, echoDropped) = echoPass(utterances)
        let final = kept.sorted { $0.startedAt < $1.startedAt }

        // Last interruption point — past here the (atomic) writes go through
        // unconditionally so a cancel can never leave half-updated files.
        try Task.checkCancellation()
        progress("Saving…")
        let doc = TranscriptDocument(
            schemaVersion: 2,
            sessionID: sessionDirectory.lastPathComponent,
            generator: mode == .finalize ? .finalize : .rerun,
            utterances: final
        )
        session.needsFinalize = false
        let sessionSnapshot = session
        // Transcript rewrite goes through the coordinator so it can't race a
        // manual pin's save; session.json has no competing writers.
        try await TranscriptDocumentFileCoordinator.shared.save(doc, to: sessionDirectory)
        try await Task.detached(priority: .userInitiated) {
            try sessionSnapshot.write(to: sessionDirectory)
        }.value

        // Optional LLM cleanup pass — best effort, run after the raw transcript
        // is safely persisted. Writes transcript.cleaned.json only on a fully
        // successful pass; a server outage or cancellation leaves any existing
        // cleaned copy untouched (never overwritten with a partial result).
        if let llmConfig {
            await runCleanup(
                final, sessionID: sessionDirectory.lastPathComponent,
                directory: sessionDirectory, config: llmConfig, progress: progress)
        }

        Self.log.notice(
            "Offline \(mode.rawValue, privacy: .public) done: \(final.count) utterances, \(echoDropped) echo-dropped, \(voiceprintHits) voiceprint hits"
        )
        return Outcome(
            mode: mode, utteranceCount: final.count, droppedAsEcho: echoDropped,
            voiceprintHits: voiceprintHits)
    }

    // MARK: - Inputs

    /// One decoded track: 16 kHz mono samples plus the wall clock of sample 0.
    nonisolated struct Track: Sendable {
        let source: Source
        let anchor: Date
        let samples: [Float]
    }

    /// One offline-diarizer segment, cluster ids re-mapped to stable Ints.
    nonisolated struct DiarSegment: Sendable {
        let cluster: Int
        let startSec: Double
        let endSec: Double
        let quality: Float
    }

    nonisolated private struct ClusterKey: Hashable, Sendable {
        let source: Source
        let cluster: Int
    }

    nonisolated private static func readSession(in directory: URL) throws -> Session {
        let url = directory.appending(path: "session.json", directoryHint: .notDirectory)
        guard let data = try? Data(contentsOf: url) else { throw Failure.noSessionMetadata }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Session.self, from: data)
    }

    nonisolated private static func decodeTracks(
        segment: Segment, sessionStart: Date, directory: URL
    ) async throws -> [Track] {
        var specs: [(Source, String, Date)] = [
            (.mic, segment.micFilename, segment.micAnchor ?? sessionStart)
        ]
        if let systemFile = segment.systemFilename {
            // Older sessions have no per-track anchor; fall back to the
            // session start and accept the ~2 s system bring-up skew.
            specs.append((.system, systemFile, segment.systemAnchor ?? sessionStart))
        }
        var tracks: [Track] = []
        for (source, filename, anchor) in specs {
            let url = directory.appending(path: filename, directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                continue
            }
            let samples = try await decode16kMono(url)
            if !samples.isEmpty {
                tracks.append(Track(source: source, anchor: anchor, samples: samples))
            }
        }
        return tracks
    }

    /// Decode an archive MP4 to 16 kHz mono Float32 in one pass —
    /// AVAssetReader does the AAC decode and the resample for us. Whole-file
    /// in memory: ~230 MB per hour of audio, acceptable for typical sessions.
    nonisolated static func decode16kMono(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        // Async track load (the only non-deprecated accessor); the sample-read
        // loop below stays synchronous. Always runs inside a detached task.
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure.decodeFailed("no audio track in \(url.lastPathComponent)")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw Failure.decodeFailed("reader rejected output for \(url.lastPathComponent)")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw Failure.decodeFailed(String(describing: reader.error))
        }
        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.stride
            guard count > 0 else { continue }
            let insertAt = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: length,
                    destination: raw.baseAddress!.advanced(by: insertAt * MemoryLayout<Float>.stride)
                )
            }
            guard status == kCMBlockBufferNoErr else {
                throw Failure.decodeFailed("CMBlockBuffer copy failed (\(status))")
            }
        }
        if reader.status == .failed {
            throw Failure.decodeFailed(String(describing: reader.error))
        }
        return samples
    }

    // MARK: - Diarization

    /// Run offline diarization, tracks in parallel. Tracks are independent
    /// cluster namespaces (matching the live pipeline's source-local
    /// `diarCluster`), each with its own (non-Sendable) manager built from
    /// the shared Sendable model set. FluidAudio's string speaker ids are
    /// re-mapped to Ints by first appearance order.
    nonisolated private static func diarize(
        tracks: [Track], models: OfflineDiarizerModels
    ) async throws -> [Source: [DiarSegment]] {
        try await withThrowingTaskGroup(of: (Source, [DiarSegment]).self) { group in
            for track in tracks {
                group.addTask {
                    try Task.checkCancellation()
                    let manager = OfflineDiarizerManager()
                    manager.initialize(models: models)
                    let result = try await manager.process(audio: track.samples)
                    var clusterIds: [String: Int] = [:]
                    var segments: [DiarSegment] = []
                    for seg in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) {
                        let id: Int
                        if let existing = clusterIds[seg.speakerId] {
                            id = existing
                        } else {
                            id = clusterIds.count
                            clusterIds[seg.speakerId] = id
                        }
                        segments.append(
                            DiarSegment(
                                cluster: id,
                                startSec: Double(seg.startTimeSeconds),
                                endSec: Double(seg.endTimeSeconds),
                                quality: seg.qualityScore
                            ))
                    }
                    Self.log.info(
                        "Offline diarization (\(track.source == .mic ? "mic" : "system", privacy: .public)): \(segments.count) segments, \(clusterIds.count) speakers"
                    )
                    return (track.source, segments)
                }
            }
            var out: [Source: [DiarSegment]] = [:]
            for try await (source, segments) in group {
                out[source] = segments
            }
            return out
        }
    }

    // MARK: - Rerun transcription

    /// ASR worker tasks per track. Apple's speech service does its own
    /// scheduling; each `AppleAsr.transcribe` call is an independent
    /// analyzer session, so a few concurrent workers overlap the per-call
    /// setup cost without contending on shared state.
    nonisolated private static let asrWorkersPerTrack = 4

    /// Full from-audio transcription of one track: whole-file VAD
    /// segmentation (sequential — the VAD RNN is stateful) → batch ASR over
    /// the segments on a small worker pool → split into speaker-coherent
    /// runs against the *offline* diarizer timeline (the live pipeline does
    /// the same against LS-EEND). Mirrors `StreamProcessor.emit`; output
    /// order is restored by segment index, so parallelism never reorders
    /// the transcript.
    nonisolated private static func transcribe(
        track: Track,
        diar: [DiarSegment],
        vad: VadManager,
        asr: AppleAsr,
        embedder: DiarizerManager
    ) async throws -> [Utterance] {
        let rate = Resampler.targetRate  // 16_000
        let minSpeechSamples = Int(rate * 0.3)
        let segments = try await vad.segmentSpeech(track.samples).filter { seg in
            let lo = max(0, Int(seg.startTime * rate))
            let hi = min(track.samples.count, Int(seg.endTime * rate))
            return hi - lo >= minSpeechSamples
        }
        guard !segments.isEmpty else { return [] }

        let workers = min(asrWorkersPerTrack, segments.count)
        let indexed: [[(Int, [Utterance])]] = try await withThrowingTaskGroup(
            of: [(Int, [Utterance])].self
        ) { group in
            for w in 0..<workers {
                group.addTask {
                    var results: [(Int, [Utterance])] = []
                    for i in stride(from: w, to: segments.count, by: workers) {
                        // Cancellation lands within one segment's latency
                        // (~a second), not at the end of the recording.
                        try Task.checkCancellation()
                        let utterances = try await transcribeSegment(
                            segments[i], track: track, diar: diar, asr: asr,
                            embedder: embedder)
                        results.append((i, utterances))
                    }
                    return results
                }
            }
            var all: [[(Int, [Utterance])]] = []
            for try await chunk in group { all.append(chunk) }
            return all
        }
        return indexed.flatMap { $0 }.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
    }

    /// One VAD segment through ASR and run-splitting — the unit of work the
    /// transcription pool distributes.
    nonisolated private static func transcribeSegment(
        _ seg: VadSegment,
        track: Track,
        diar: [DiarSegment],
        asr: AppleAsr,
        embedder: DiarizerManager
    ) async throws -> [Utterance] {
        let rate = Resampler.targetRate
        let lo = max(0, Int(seg.startTime * rate))
        let hi = min(track.samples.count, Int(seg.endTime * rate))
        let segmentSamples = Array(track.samples[lo..<hi])

        let result = try await asr.transcribe(segmentSamples)
        let fullText = result.text
        guard !fullText.isEmpty else { return [] }

        let words = result.words
        guard !words.isEmpty else {
            let cluster = dominantCluster(startSec: seg.startTime, endSec: seg.endTime, in: diar)
            return [
                makeUtterance(
                    track: track, text: fullText, words: nil,
                    runAudio: segmentSamples, fallbackAudio: segmentSamples,
                    startSec: seg.startTime, endSec: seg.endTime,
                    cluster: cluster, embedder: embedder
                )
            ]
        }

        let runs = SpeakerSegmenter.splitIntoRuns(
            tokens: words,
            speakerAt: { wordTimeRelative in
                clusterAt(timeSec: seg.startTime + wordTimeRelative, in: diar)
            },
            minTokensPerRun: 2
        )
        var out: [Utterance] = []
        for run in runs {
            let runText = run.text
            if runText.isEmpty { continue }
            let runStartIdx = max(0, Int(run.startTime * rate))
            let runEndIdx = min(segmentSamples.count, Int(run.endTime * rate))
            let runAudio =
                runEndIdx > runStartIdx
                ? Array(segmentSamples[runStartIdx..<runEndIdx])
                : segmentSamples
            out.append(
                makeUtterance(
                    track: track, text: runText, words: run.tokens,
                    runAudio: runAudio, fallbackAudio: segmentSamples,
                    startSec: seg.startTime + run.startTime,
                    endSec: seg.startTime + run.endTime,
                    cluster: run.speakerIndex,
                    embedder: embedder
                ))
        }
        return out
    }

    nonisolated private static func makeUtterance(
        track: Track,
        text: String,
        words: [TimedToken]?,
        runAudio: [Float],
        fallbackAudio: [Float],
        startSec: Double,
        endSec: Double,
        cluster: Int?,
        embedder: DiarizerManager
    ) -> Utterance {
        var sumSq: Float = 0
        for v in runAudio { sumSq += v * v }
        let rms = runAudio.isEmpty ? Float(0) : (sumSq / Float(runAudio.count)).squareRoot()

        let usedFallback = runAudio.count < 4_800 && fallbackAudio.count > runAudio.count
        let embedAudio = usedFallback ? fallbackAudio : runAudio
        let embedding = try? embedder.extractSpeakerEmbedding(from: embedAudio)

        let timings = words.map { ws -> [WordTiming] in
            let base = ws.first?.startTime ?? 0
            return ws.map { tok in
                WordTiming(
                    word: tok.text.trimmingCharacters(in: .whitespaces),
                    start: tok.startTime - base,
                    end: tok.endTime - base
                )
            }
        }

        // Placeholder labels; `relabel` derives the final ones from the full
        // cluster sets, same as the live store does.
        return Utterance(
            source: track.source,
            speaker: track.source == .mic ? .localSpeaker(1) : .them,
            text: text,
            startedAt: track.anchor.addingTimeInterval(startSec),
            endedAt: track.anchor.addingTimeInterval(endSec),
            embedding: embedding,
            rms: rms,
            diarCluster: cluster,
            wordTimings: timings,
            assignmentKind: .auto,
            embeddingAmbiguous: embedding == nil ? nil : usedFallback
        )
    }

    // MARK: - Cluster re-assignment + labels

    /// Re-pin every non-manual utterance's `diarCluster` to the offline
    /// timeline's dominant overlapping cluster. No overlap → keep the
    /// existing cluster (the utterance may sit in audio the diarizer judged
    /// non-speech; its draft cluster is still the best information we have).
    nonisolated private static func reassignClusters(
        _ utterances: [Utterance], diar: [Source: [DiarSegment]], tracks: [Track]
    ) -> [Utterance] {
        let anchors = Dictionary(uniqueKeysWithValues: tracks.map { ($0.source, $0.anchor) })
        return utterances.map { u in
            guard u.assignmentKind != .manual,
                  let segments = diar[u.source],
                  let anchor = anchors[u.source]
            else { return u }
            let startSec = u.startedAt.timeIntervalSince(anchor)
            let endSec = u.endedAt.timeIntervalSince(anchor)
            guard let cluster = dominantCluster(startSec: startSec, endSec: endSec, in: segments)
            else { return u }
            var copy = u
            copy.diarCluster = cluster
            return copy
        }
    }

    nonisolated private static func dominantCluster(
        startSec: Double, endSec: Double, in segments: [DiarSegment]
    ) -> Int? {
        var overlap: [Int: Double] = [:]
        for s in segments {
            let lo = max(s.startSec, startSec)
            let hi = min(s.endSec, endSec)
            if hi > lo { overlap[s.cluster, default: 0] += hi - lo }
        }
        return overlap.max(by: { $0.value < $1.value })?.key
    }

    nonisolated private static func clusterAt(timeSec: Double, in segments: [DiarSegment]) -> Int? {
        for s in segments where s.startSec <= timeSec && timeSec <= s.endSec {
            return s.cluster
        }
        return nil
    }

    /// Final visible labels from the re-assigned clusters — the same rules
    /// the live `TranscriptStore` applies, but over the complete sets:
    /// system → `.them` / `.remote(N)`; mic → `.you` in call mode,
    /// `.localSpeaker(N)` in mic-only mode. Manual pins untouched; `.named`
    /// labels are applied afterwards by the voiceprint pass.
    nonisolated private static func relabel(_ utterances: [Utterance]) -> [Utterance] {
        let callMode = utterances.contains { $0.source == .system }
        let systemClusters = Set(
            utterances.filter { $0.source == .system }.compactMap(\.diarCluster))
        let micClusters = Set(utterances.filter { $0.source == .mic }.compactMap(\.diarCluster))
            .sorted()
        return utterances.map { u in
            guard u.assignmentKind != .manual else { return u }
            var copy = u
            switch u.source {
            case .system:
                copy.speaker = .remoteLabel(forCluster: u.diarCluster, among: systemClusters)
            case .mic:
                if callMode {
                    copy.speaker = .you
                } else if micClusters.count > 1, let c = u.diarCluster,
                    let rank = micClusters.firstIndex(of: c) {
                    copy.speaker = .localSpeaker(rank + 1)
                } else {
                    copy.speaker = .localSpeaker(1)
                }
            }
            copy.assignmentKind = .auto
            return copy
        }
    }

    // MARK: - Voiceprint identification

    /// WeSpeaker centroid per (track, cluster), extracted from the cluster's
    /// highest-quality diarizer windows. This is deliberately NOT the offline
    /// diarizer's own embedding — that model lives in a different space than
    /// the voiceprint book (see type doc).
    nonisolated private static func clusterCentroids(
        tracks: [Track], diar: [Source: [DiarSegment]], embedder: DiarizerManager
    ) -> [ClusterKey: [Float]] {
        let rate = Resampler.targetRate
        var out: [ClusterKey: [Float]] = [:]
        for track in tracks {
            guard let segments = diar[track.source] else { continue }
            let byCluster = Dictionary(grouping: segments, by: \.cluster)
            for (cluster, segs) in byCluster {
                // Up to 3 windows ≥ 1 s, best quality first, each capped at
                // 10 s — enough audio for a stable embedding without paying
                // for a long monologue.
                let windows = segs
                    .filter { $0.endSec - $0.startSec >= 1.0 }
                    .sorted { $0.quality > $1.quality }
                    .prefix(3)
                var embeddings: [[Float]] = []
                for w in windows {
                    let lo = max(0, Int(w.startSec * rate))
                    let hi = min(track.samples.count, Int(min(w.endSec, w.startSec + 10) * rate))
                    guard hi > lo else { continue }
                    if let e = try? embedder.extractSpeakerEmbedding(from: track.samples[lo..<hi]) {
                        embeddings.append(e)
                    }
                }
                guard !embeddings.isEmpty, let dim = embeddings.first?.count else { continue }
                var centroid = [Float](repeating: 0, count: dim)
                for e in embeddings where e.count == dim {
                    for i in 0..<dim { centroid[i] += e[i] }
                }
                let n = Float(embeddings.count)
                for i in 0..<dim { centroid[i] /= n }
                out[ClusterKey(source: track.source, cluster: cluster)] = centroid
            }
        }
        return out
    }

    // MARK: - Echo pass

    /// Deterministic two-pass echo filter: every non-manual mic utterance is
    /// judged against the *complete* system log, so the live store's
    /// ASR-latency arrival race can't exist here.
    nonisolated private static func echoPass(_ utterances: [Utterance]) -> ([Utterance], Int) {
        let systemLog = utterances
            .filter { $0.source == .system }
            .sorted { $0.startedAt < $1.startedAt }
        guard !systemLog.isEmpty else { return (utterances, 0) }
        let filter = EchoFilter()
        var kept: [Utterance] = []
        kept.reserveCapacity(utterances.count)
        var dropped = 0
        for u in utterances {
            guard u.source == .mic, u.assignmentKind != .manual else {
                kept.append(u)
                continue
            }
            if case .drop = filter.decide(mic: u, system: systemLog) {
                dropped += 1
            } else {
                kept.append(u)
            }
        }
        return (kept, dropped)
    }

    // MARK: - Output

    /// Best-effort LLM cleanup over the finalized utterances. Errors and
    /// cancellation are swallowed (logged): the raw transcript is already
    /// saved, and we never overwrite an existing cleaned copy with a partial
    /// or failed result. The `sourceHash` stamps which raw transcript this was
    /// derived from so the UI can flag it stale after a later rerun.
    private static func runCleanup(
        _ final: [Utterance], sessionID: String, directory: URL,
        config: LLMSettings.Config, progress: @escaping @MainActor (String) -> Void
    ) async {
        progress("Cleaning up transcript…")
        do {
            let cleaned = try await TranscriptCleanup.run(
                utterances: final, config: config
            ) { done, total in
                progress("Cleaning up transcript… \(done)/\(total)")
            }
            let doc = TranscriptDocument(
                schemaVersion: 2, sessionID: sessionID, generator: .cleaned,
                utterances: cleaned, sourceHash: TranscriptDocument.contentHash(final))
            try await TranscriptDocumentFileCoordinator.shared.save(
                doc, to: directory, filename: TranscriptDocument.cleanedFilename)
            Self.log.notice("Cleanup wrote \(cleaned.count) utterances for \(sessionID, privacy: .public)")
        } catch {
            Self.log.notice(
                "Cleanup skipped for \(sessionID, privacy: .public) (\(String(describing: error), privacy: .public)) — existing cleaned copy kept"
            )
        }
    }
}
