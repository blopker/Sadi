import FluidAudio
import Foundation
import Observation
import OSLog
import SadiKit

/// Phases 2 + 3 + 4 orchestrator. Owns the two capture sources, opens one
/// archive writer per stream, and runs a consumer task per ring that:
///   1. Pulls source-rate Float32 mono samples
///   2. Appends to the segment's fragmented MP4 (Phase 3)
///   3. Hands the samples to the per-stream StreamProcessor (Phase 4): which
///      resamples to 16 kHz, segments via Silero VAD, transcribes via
///      Parakeet, and publishes Utterances to the shared TranscriptStore
///   4. Publishes RMS to the meter UI
@Observable
final class CaptureController {
    private(set) var isRunning = false
    private(set) var micLevel: Float = 0
    private(set) var systemLevel: Float = 0
    private(set) var micStatus: String = "idle"
    private(set) var systemStatus: String = "idle"
    private(set) var sessionID: String = ""
    private(set) var sessionDirectoryPath: String = ""

    private let modelHost: ModelHost
    private let transcript: TranscriptStore

    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var micConsumer: Task<Void, Never>?
    private var systemConsumer: Task<Void, Never>?
    private var systemStartTask: Task<Void, Never>?
    private var sessionDirectory: URL?
    private var sessionStartWallClock: Date?
    // Filenames of the segment archives actually opened this session, recorded
    // only on the success path so `session.json` reflects what's on disk
    // (nil if that pipeline failed to start).
    private var micSegmentFile: String?
    private var systemSegmentFile: String?

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "capture")

    init(modelHost: ModelHost, transcript: TranscriptStore) {
        self.modelHost = modelHost
        self.transcript = transcript
    }

    func start() {
        guard !isRunning else { return }
        guard let vad = modelHost.vad,
              let asrModels = modelHost.asrModels,
              let diarizerModel = modelHost.diarizerModel,
              let embeddingDiarizer = modelHost.embeddingDiarizer
        else {
            micStatus = "models not loaded"
            systemStatus = "models not loaded"
            return
        }

        let session: SessionPaths
        do {
            session = try SessionPaths.create()
        } catch {
            micStatus = "session-dir: \(error)"
            systemStatus = "session-dir: \(error)"
            return
        }
        sessionID = session.id
        sessionDirectory = session.directory
        sessionDirectoryPath = session.directory.path(percentEncoded: false)
        let startWallClock = Date()
        sessionStartWallClock = startWallClock
        transcript.reset()
        isRunning = true

        // Mic pipeline.
        do {
            let m = try MicCapture()
            let writer = try SegmentArchiveWriter(
                url: session.micURL(segment: 1),
                sampleRate: m.sampleRate
            )
            let proc = try StreamProcessor(
                source: .mic,
                sourceRate: m.sampleRate,
                vad: vad,
                asrModels: asrModels,
                diarizerModel: diarizerModel,
                embeddingDiarizer: embeddingDiarizer,
                store: transcript,
                startWallClock: startWallClock
            )
            try m.start()
            mic = m
            micSegmentFile = session.micURL(segment: 1).lastPathComponent
            micStatus = "running @ \(Int(m.sampleRate)) Hz"
            micConsumer = consume(
                ring: m.ring,
                writer: writer,
                processor: proc,
                rateSource: nil,
                publish: { [weak self] level in
                    self?.micLevel = level
                }
            )
        } catch {
            micStatus = "failed: \(error)"
            Self.log.error("Mic start failed: \(String(describing: error), privacy: .public)")
        }

        // System audio pipeline — deferred until the mic has actually started
        // producing audio. Opening the mic input can kick off a Bluetooth
        // A2DP→HFP profile switch that churns CoreAudio for ~1 s; creating the
        // system process tap during that window corrupts it (-10877 storms, a
        // collapsed effective rate). The mic's first delivered frame signals
        // the input device (and any profile switch) has settled.
        systemStatus = "waiting for mic"
        systemStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<40 {  // up to ~2 s
                if Task.isCancelled { return }
                if self.mic?.firstHostTime != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if Task.isCancelled { return }
            guard self.isRunning,
                  let vad = self.modelHost.vad,
                  let asrModels = self.modelHost.asrModels,
                  let diarizerModel = self.modelHost.diarizerModel,
                  let embeddingDiarizer = self.modelHost.embeddingDiarizer
            else { return }
            self.startSystemPipeline(
                session: session,
                startWallClock: startWallClock,
                vad: vad,
                asrModels: asrModels,
                diarizerModel: diarizerModel,
                embeddingDiarizer: embeddingDiarizer
            )
        }
    }

    /// Build and start the system-audio pipeline. Split out of `start()` so it
    /// can run after the mic has settled (see the deferred task in `start`).
    private func startSystemPipeline(
        session: SessionPaths,
        startWallClock: Date,
        vad: VadManager,
        asrModels: AsrModels,
        diarizerModel: LSEENDModel,
        embeddingDiarizer: DiarizerManager
    ) {
        do {
            let s = try SystemAudioCapture()
            let writer = try SegmentArchiveWriter(
                url: session.systemURL(segment: 1),
                sampleRate: s.sampleRate
            )
            let proc = try StreamProcessor(
                source: .system,
                sourceRate: s.sampleRate,
                vad: vad,
                asrModels: asrModels,
                diarizerModel: diarizerModel,
                embeddingDiarizer: embeddingDiarizer,
                store: transcript,
                startWallClock: startWallClock
            )
            try s.start()
            system = s
            systemSegmentFile = session.systemURL(segment: 1).lastPathComponent
            systemStatus = "running @ \(Int(s.sampleRate)) Hz"
            systemConsumer = consume(
                ring: s.ring,
                writer: writer,
                processor: proc,
                rateSource: s,
                publish: { [weak self] level in
                    self?.systemLevel = level
                }
            )
        } catch {
            systemStatus = "failed: \(error)"
            Self.log.error("System start failed: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() async {
        guard isRunning else { return }
        // Stamp the end the moment the user stopped, before the finalize awaits.
        let endedAt = Date()
        // Cancel the deferred system start and wait it out, so it can't bring a
        // system pipeline up after we've begun tearing down. `isRunning` stays
        // true until the end here, which also blocks a re-`start()` race.
        systemStartTask?.cancel()
        await systemStartTask?.value
        systemStartTask = nil
        // Tear the capture devices down OFF the main thread. `MicCapture.stop()`
        // / `SystemAudioCapture.stop()` make blocking HAL calls (AudioOutputUnitStop,
        // AudioDeviceStop, dispose) that can wedge for seconds when a Bluetooth
        // device is mid-transition — running them on the main actor beachballs the
        // UI. `await`ing a detached task suspends the main actor without blocking
        // the main thread. Both capture types are Sendable.
        let micToStop = self.mic
        let systemToStop = self.system
        await Task.detached(priority: .userInitiated) {
            micToStop?.stop()
            systemToStop?.stop()
        }.value
        micConsumer?.cancel()
        systemConsumer?.cancel()
        await micConsumer?.value
        await systemConsumer?.value
        // MP4s are finalized now (the consumers drain + `writer.finalize()`
        // before returning). Persist on-disk artifacts in SPEC §10.6 order:
        // audio (done) → transcript.json → session.json. A clean Stop and a
        // graceful quit (which routes through this same path) both leave a
        // fully self-describing session directory.
        if let dir = sessionDirectory {
            do {
                try await transcript.writeTranscript(to: dir)
            } catch {
                Self.log.error("Transcript persist failed: \(String(describing: error), privacy: .public)")
            }
            writeSessionMetadata(to: dir, endedAt: endedAt)
        }
        mic = nil
        system = nil
        micConsumer = nil
        systemConsumer = nil
        sessionDirectory = nil
        sessionStartWallClock = nil
        micSegmentFile = nil
        systemSegmentFile = nil
        micLevel = 0
        systemLevel = 0
        micStatus = "idle"
        systemStatus = "idle"
        isRunning = false
    }

    /// Write `session.json` describing the finalized session. Single-segment
    /// for now (pause/resume is a later phase). `speakerClusters` is left empty
    /// — the diarizer timeline lives per-stream and exporting it is future
    /// Phase 10 work; the field is still written so the schema is stable.
    private func writeSessionMetadata(to directory: URL, endedAt: Date) {
        guard let start = sessionStartWallClock else { return }
        // Don't write metadata for a session where neither pipeline ever
        // produced a file — there's nothing to describe.
        guard micSegmentFile != nil || systemSegmentFile != nil else { return }
        let segment = Segment(
            index: 1,
            startedAt: start,
            endedAt: endedAt,
            micFilename: micSegmentFile ?? "mic-001.mp4",
            systemFilename: systemSegmentFile
        )
        let session = Session(
            id: sessionID,
            title: "",
            startedAt: start,
            endedAt: endedAt,
            segments: [segment],
            speakerClusters: []
        )
        do {
            try session.write(to: directory)
        } catch {
            Self.log.error("Session metadata persist failed: \(String(describing: error), privacy: .public)")
        }
    }

    private nonisolated func consume(
        ring: SPSCRingBuffer,
        writer: SegmentArchiveWriter,
        processor: StreamProcessor,
        rateSource: SystemAudioCapture?,
        publish: @escaping @MainActor (Float) -> Void
    ) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            var scratch = [Float](repeating: 0, count: 1024)
            // SPEC §5.2: re-measure system's effective sample rate every
            // ~10 s of wall-clock time. Time-based so it works the same
            // regardless of source-rate / pull-size.
            let rateCheckIntervalSec: Double = 10
            var lastRateCheckHostTime: UInt64 = mach_absolute_time()
            while !Task.isCancelled {
                let pulled = scratch.withUnsafeMutableBufferPointer { buf in
                    ring.pull(count: buf.count, into: buf)
                }
                if !pulled {
                    try? await Task.sleep(for: .milliseconds(10))
                    continue
                }

                scratch.withUnsafeBufferPointer { buf in
                    do {
                        try writer.append(buf)
                    } catch {
                        Self.log.error("Archive append: \(String(describing: error), privacy: .public)")
                    }
                }

                // Hand the same chunk to the transcription pipeline.
                await processor.feed(scratch)

                var sumSq: Float = 0
                for v in scratch { sumSq += v * v }
                let rms = (sumSq / Float(scratch.count)).squareRoot()
                await publish(rms)

                // Periodic effective-rate measurement for the system tap.
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
                            await processor.retuneSourceRate(measured)
                        }
                    }
                }
            }

            // Drain the tail. `mic.stop()` / `system.stop()` removed the tap
            // before this task was cancelled, so the producer is quiesced and
            // `availableToRead` is a stable, shrinking count. The main loop
            // only pulls full 1024-sample chunks, so the final sub-1024
            // fragment would otherwise never reach the MP4 or the transcript.
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
                await processor.feed(tail)
            }

            await writer.finalize()
        }
    }
}
