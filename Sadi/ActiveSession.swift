import AVFoundation
import Foundation
import OSLog
import SadiKit
import Synchronization

/// The slice of a capture source `StreamPipeline` and the stop path need.
/// `MicCapture` and `SystemAudioCapture` already share this surface; the
/// protocol lets the session hold them uniformly. `nonisolated` because the
/// conforming types are SadiKit realtime sources — their members must stay
/// callable off the main actor (the app target defaults to MainActor).
nonisolated protocol CaptureSource: Sendable {
    /// Ring the realtime callback pushes source-rate Float32 mono samples into.
    var ring: SPSCRingBuffer { get }
    /// Client sample rate, fixed for the session.
    var sampleRate: Double { get }
    /// `mach_absolute_time` of the first sample pushed; nil until capture has
    /// actually produced audio.
    var firstHostTime: UInt64? { get }
    /// Cumulative frames lost to ring overflow since start. Monotonic; the
    /// archive loop polls it to keep the timeline and trip the stall failsafe.
    var droppedFrames: UInt64 { get }
    /// Blocking HAL teardown — call OFF the main thread.
    func stop()
}

extension MicCapture: CaptureSource {}
extension SystemAudioCapture: CaptureSource {}

/// What the archive loop forwards to the inference side. Ordered events:
/// `gap` stands in for samples that were lost (ring overflow) or deliberately
/// dropped (inference backlog full) so the processor's absolute sample
/// timeline — and therefore every utterance timestamp — stays aligned with
/// the archive's. `retune` rides the same channel so a resampler retune
/// applies at the right position in the sample stream.
private nonisolated enum InferenceEvent: Sendable {
    case samples([Float])
    case gap(frames: Int)
    case retune(sourceRate: Double)
}

/// Samples currently sitting in the inference channel. A class because
/// `Atomic` is noncopyable — the archiver (adds) and the inference task
/// (subtracts) share one counter through this reference.
private nonisolated final class InferenceBacklog: Sendable {
    private let samples = Atomic<Int>(0)

    var count: Int { samples.load(ordering: .relaxed) }
    func add(_ n: Int) { samples.wrappingAdd(n, ordering: .relaxed) }
    func subtract(_ n: Int) { samples.wrappingSubtract(n, ordering: .relaxed) }
}

/// One capture stream end-to-end, in two decoupled halves:
///
///   source ─▶ ring ─▶ archiver task ─▶ MP4 + RMS + bounded channel
///                                            │
///                                            ▼
///                          inference task ─▶ StreamProcessor ─▶ TranscriptStore
///
/// The archiver only does realtime-paced work (pull, disk append, RMS) and
/// never waits on inference, so an ASR stall can't back the ring up. The
/// inference side consumes the channel at whatever pace the models allow; if
/// it falls more than `inferenceCapSeconds` behind, transcription audio is
/// dropped (logged, replaced by a gap so timestamps stay sample-accurate)
/// while the archive is unaffected. Lost *archive* audio — ring overflow or
/// writer backpressure, i.e. the disk can't keep up — is backfilled as
/// encoded silence (keeping the file wall-clock true) and, past
/// `stallThresholdSeconds`, reported via `onStall`.
@MainActor
final class StreamPipeline {
    let source: Source
    let capture: any CaptureSource
    /// Filename of the segment archive opened for this stream — recorded into
    /// `session.json` so the metadata reflects what's actually on disk.
    let segmentFilename: String
    /// Drains the ring to the MP4. Cancel + await *after* `capture.stop()`:
    /// it drains the ring tail, finishes the inference channel, and finalizes
    /// the MP4 before returning.
    let archiver: Task<Void, Never>
    /// Feeds the StreamProcessor from the channel. Completes on its own once
    /// the archiver finishes the channel — await it (don't cancel) so every
    /// utterance reaches the store before the transcript persists.
    let inference: Task<Void, Never>

    /// Transcription backlog cap. 60 s of source-rate mono is ~12 MB — cheap
    /// enough to ride out long ASR stalls without dropping.
    nonisolated private static let inferenceCapSeconds: Double = 60
    /// Lost-archive-audio budget before the stall failsafe fires. One second
    /// of audio is already a real hole in the recording; past it, the disk is
    /// presumed wedged and continuing would only lose more.
    nonisolated private static let stallThresholdSeconds: Double = 1

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "capture")

    init(
        source: Source,
        capture: any CaptureSource,
        rateSource: SystemAudioCapture?,
        writer: SegmentArchiveWriter,
        processor: StreamProcessor,
        segmentFilename: String,
        publish: @escaping @MainActor (Float) -> Void,
        onStall: @escaping @MainActor () -> Void
    ) {
        self.source = source
        self.capture = capture
        self.segmentFilename = segmentFilename

        let (events, feed) = AsyncStream.makeStream(
            of: InferenceEvent.self, bufferingPolicy: .unbounded
        )
        // The producer enforces the backlog cap against this instead of
        // AsyncStream's element-count policies, because a drop must be
        // *observable* (logged + replaced by a gap), not silent.
        let backlog = InferenceBacklog()

        self.inference = StreamPipeline.runInference(
            source: source, events: events, processor: processor, backlog: backlog
        )
        self.archiver = StreamPipeline.archive(
            source: source,
            capture: capture,
            writer: writer,
            rateSource: rateSource,
            feed: feed,
            backlog: backlog,
            publish: publish,
            onStall: onStall
        )
    }

    // MARK: - Archive loop

    nonisolated private static func archive(
        source: Source,
        capture: any CaptureSource,
        writer: SegmentArchiveWriter,
        rateSource: SystemAudioCapture?,
        feed: AsyncStream<InferenceEvent>.Continuation,
        backlog: InferenceBacklog,
        publish: @escaping @MainActor (Float) -> Void,
        onStall: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            let label = source == .mic ? "mic" : "system"
            let ring = capture.ring
            var scratch = [Float](repeating: 0, count: 1024)
            // SPEC §5.2: re-measure system's effective sample rate every
            // ~10 s of wall-clock time. Time-based so it works the same
            // regardless of source-rate / pull-size.
            let rateCheckIntervalSec: Double = 10
            var lastRateCheckHostTime: UInt64 = mach_absolute_time()

            let inferenceCap = Int(capture.sampleRate * inferenceCapSeconds)
            let stallThreshold = Int64(capture.sampleRate * stallThresholdSeconds)
            // Ring-overflow frames already accounted (capture.droppedFrames is
            // cumulative); gap frames owed to the inference side but not yet
            // yielded; whether the stall failsafe already fired.
            var ringDropsSeen: UInt64 = 0
            var pendingGapFrames = 0
            var inferenceDropTotal = 0
            var inferenceDropping = false
            var stallSignaled = false

            // Forward a chunk to the inference side, flushing any owed gap
            // first so events stay in timeline order. Over the backlog cap,
            // the chunk becomes more gap: transcription-only loss, by policy
            // (the archive already has the samples); logged on each episode.
            func forward(_ chunk: [Float]) {
                if backlog.count + chunk.count > inferenceCap {
                    if !inferenceDropping {
                        inferenceDropping = true
                        Self.log.error(
                            "\(label, privacy: .public): inference backlog ≥ \(Int(inferenceCapSeconds))s — dropping transcription audio (archive unaffected)"
                        )
                    }
                    pendingGapFrames += chunk.count
                    inferenceDropTotal += chunk.count
                    return
                }
                if inferenceDropping {
                    inferenceDropping = false
                    Self.log.notice(
                        "\(label, privacy: .public): inference resumed; dropped \(Double(inferenceDropTotal) / capture.sampleRate, format: .fixed(precision: 1))s of transcription audio so far"
                    )
                }
                if pendingGapFrames > 0 {
                    feed.yield(.gap(frames: pendingGapFrames))
                    pendingGapFrames = 0
                }
                backlog.add(chunk.count)
                feed.yield(.samples(chunk))
            }

            // Account ring-overflow losses: the archive stands in encoded
            // silence for the hole and the inference side is owed an equal
            // gap. The position is approximate (the ring buffers ~10 s ahead
            // of detection), which is acceptable because the failsafe stops
            // the recording within ~1 s of loss anyway.
            func accountRingDrops() {
                let dropsNow = capture.droppedFrames
                guard dropsNow > ringDropsSeen else { return }
                let delta = Int(dropsNow - ringDropsSeen)
                ringDropsSeen = dropsNow
                writer.insertSilence(frames: delta)
                pendingGapFrames += delta
                Self.log.error(
                    "\(label, privacy: .public): ring overflow — lost \(Double(delta) / capture.sampleRate, format: .fixed(precision: 2))s of audio"
                )
            }

            while !Task.isCancelled {
                let pulled = scratch.withUnsafeMutableBufferPointer { buf in
                    ring.pull(count: buf.count, into: buf)
                }
                if !pulled {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }

                accountRingDrops()

                scratch.withUnsafeBufferPointer { buf in
                    do {
                        try writer.append(buf)
                    } catch {
                        Self.log.error("Archive append: \(String(describing: error), privacy: .public)")
                    }
                }

                forward(scratch)

                var sumSq: Float = 0
                for v in scratch { sumSq += v * v }
                let rms = (sumSq / Float(scratch.count)).squareRoot()
                await publish(rms)

                // Periodic effective-rate measurement for the system tap. The
                // retune rides the inference channel so it applies at the
                // right position in the (possibly backlogged) sample stream.
                if let rateSource {
                    let now = mach_absolute_time()
                    let elapsed = SystemAudioCapture.hostTimeSeconds(
                        from: lastRateCheckHostTime, to: now
                    )
                    if elapsed >= rateCheckIntervalSec {
                        lastRateCheckHostTime = now
                        // Measured against realtime-stamped host times inside the
                        // capture, not `now` — avoids consumer-thread jitter.
                        if let measured = rateSource.effectiveSampleRate() {
                            feed.yield(.retune(sourceRate: measured))
                        }
                    }
                }

                // Stall failsafe: lost *archive* audio (ring overflow or
                // writer backpressure) past the threshold means the disk
                // can't keep up — hand the decision to the coordinator, which
                // stops the recording and notifies the user. Fire-once; the
                // loop keeps draining normally until the stop tears it down.
                if !stallSignaled {
                    let lost = Int64(ringDropsSeen) + writer.droppedFrames
                    if lost >= stallThreshold {
                        stallSignaled = true
                        Self.log.error(
                            "\(label, privacy: .public): \(Double(lost) / capture.sampleRate, format: .fixed(precision: 2))s of archive audio lost — signaling stall stop"
                        )
                        await onStall()
                    }
                }
            }

            // Drain the tail. `capture.stop()` removed the tap before this task
            // was cancelled, so the producer is quiesced and `availableToRead`
            // is a stable, shrinking count. The main loop only pulls full
            // 1024-sample chunks, so the final sub-1024 fragment would
            // otherwise never reach the MP4 or the transcript.
            while ring.availableToRead > 0 {
                let n = min(ring.availableToRead, scratch.count)
                let pulled = scratch.withUnsafeMutableBufferPointer { buf in
                    ring.pull(count: n, into: buf)
                }
                // The producer is stopped, so `availableToRead` only shrinks
                // and a pull of `n <= availableToRead` can't underrun; the
                // guard is just belt-and-suspenders against a stuck pull.
                guard pulled else { break }
                let tail = Array(scratch[0 ..< n])
                tail.withUnsafeBufferPointer { buf in
                    do {
                        try writer.append(buf)
                    } catch {
                        Self.log.error("Archive tail append: \(String(describing: error), privacy: .public)")
                    }
                }
                forward(tail)
            }

            // Final accounting, then settle any gap still owed so the
            // processor's timeline runs through to the true end of capture.
            accountRingDrops()
            if pendingGapFrames > 0 {
                feed.yield(.gap(frames: pendingGapFrames))
                pendingGapFrames = 0
            }
            feed.finish()

            await writer.finalize()
        }
    }

    // MARK: - Inference loop

    /// Consume the channel into the StreamProcessor. Gaps are fed as zeros so
    /// the processor's absolute sample indices (and thus utterance wall-clock
    /// timestamps) stay aligned with the archive; the VAD just sees silence.
    nonisolated private static func runInference(
        source: Source,
        events: AsyncStream<InferenceEvent>,
        processor: StreamProcessor,
        backlog: InferenceBacklog
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            let silence = [Float](repeating: 0, count: 4096)
            for await event in events {
                switch event {
                case .samples(let chunk):
                    backlog.subtract(chunk.count)
                    await processor.feed(chunk)
                case .gap(let frames):
                    var remaining = frames
                    while remaining > 0 {
                        let n = min(remaining, silence.count)
                        await processor.feed(n == silence.count ? silence : Array(silence[0..<n]))
                        remaining -= n
                    }
                case .retune(let sourceRate):
                    await processor.retuneSourceRate(sourceRate)
                }
            }
            // Channel finished — capture is stopped and fully drained. Flush
            // speech still open mid-utterance so the final words make the
            // transcript.
            await processor.flush()
        }
    }
}

/// Everything that exists only while a recording is live, in one place: the
/// session directory, the per-stream pipelines, and the session-scoped tasks.
/// `CaptureController` holds `ActiveSession?` — "a recording exists" has
/// exactly one representation, and teardown walks this object instead of a
/// scatter of nullable fields.
@MainActor
final class ActiveSession {
    let paths: SessionPaths
    /// Wall clock when the user started the recording (`session.json`'s
    /// `startedAt`). Each stream's sample-0 anchor is stamped separately at
    /// its own bring-up — see `StreamProcessor.startWallClock`.
    let startedAt: Date

    private(set) var pipelines: [StreamPipeline] = []
    /// Watches transcript activity and auto-stops after the configured idle
    /// window. Cancel-only on stop (no await) — when auto-stop fires, this
    /// task *is* the stop caller, so awaiting it would deadlock.
    var idleMonitor: Task<Void, Never>?
    /// Deferred system-audio bring-up (waits for the mic to settle). Cancel
    /// *and await* on stop so a system pipeline can't come up mid-teardown.
    var systemStartTask: Task<Void, Never>?

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "capture")

    init(paths: SessionPaths, startedAt: Date) {
        self.paths = paths
        self.startedAt = startedAt
    }

    func add(_ pipeline: StreamPipeline) {
        pipelines.append(pipeline)
    }

    func pipeline(for source: Source) -> StreamPipeline? {
        pipelines.first { $0.source == source }
    }

    /// Write `session.json` describing the finalized session, off the main
    /// thread. Single-segment for now (pause/resume is a later phase).
    /// `speakerClusters` is left empty — the diarizer timeline lives
    /// per-stream and exporting it is future Phase 10 work; the field is
    /// still written so the schema is stable.
    func writeMetadata(endedAt: Date) async {
        // Don't write metadata for a session where no pipeline ever opened an
        // archive — there's nothing on disk to describe.
        guard !pipelines.isEmpty else { return }
        let segment = Segment(
            index: 1,
            startedAt: startedAt,
            endedAt: endedAt,
            micFilename: pipeline(for: .mic)?.segmentFilename ?? "mic-001.mp4",
            systemFilename: pipeline(for: .system)?.segmentFilename
        )
        let metadata = Session(
            id: paths.id,
            title: "",
            startedAt: startedAt,
            endedAt: endedAt,
            segments: [segment],
            speakerClusters: []
        )
        let directory = paths.directory
        do {
            try await Task.detached(priority: .userInitiated) {
                try metadata.write(to: directory)
            }.value
        } catch {
            Self.log.error("Session metadata persist failed: \(String(describing: error), privacy: .public)")
        }
    }
}
