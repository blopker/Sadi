import Accelerate
import Foundation
import OSLog

/// Neural acoustic echo cancellation via LocalVQE (v1.4-AEC, echo-only:
/// passes near-end voice, noise, and room through; removes only far-end
/// echo). Runs fully in-process — unlike the OS voice processing unit it has
/// zero footprint on other apps' audio (no ducking, no device gain changes).
///
/// Two layers:
///  - `LocalVQE`: a thin dlopen/dlsym wrapper over `liblocalvqe.dylib`'s C
///    API. One context per instance; streaming state lives in the context.
///  - `EchoCanceller`: an actor that time-aligns the mic stream against the
///    far-end reference (the system-audio tap) in wall-clock space and
///    drives `LocalVQE` hop by hop. Mic audio is buffered (bounded) until
///    the matching reference has arrived; when the model or the reference
///    is missing, mic passes through unchanged — AEC is an enhancement,
///    never a gate.
///
/// Sample rates: everything here is the pipeline's 16 kHz mono Float32.
public final class LocalVQE: @unchecked Sendable {
    /// Canonical file names — the single definition shared by the app's
    /// bundle locator and the test fixtures.
    public static let libraryFilename = "liblocalvqe.dylib"
    public static let modelFilename = "localvqe-v1.4-aec-200K-f32.gguf"

    public enum Error: Swift.Error, LocalizedError {
        case libraryLoadFailed(String)
        case symbolMissing(String)
        case modelLoadFailed(String)
        case unexpectedFormat(sampleRate: Int, hop: Int)

        public var errorDescription: String? {
            switch self {
            case .libraryLoadFailed(let m): "LocalVQE library load failed: \(m)"
            case .symbolMissing(let s): "LocalVQE symbol missing: \(s)"
            case .modelLoadFailed(let m): "LocalVQE model load failed: \(m)"
            case .unexpectedFormat(let sr, let hop):
                "LocalVQE runtime reports unsupported format (rate \(sr), hop \(hop))"
            }
        }
    }

    private typealias NewFn = @convention(c) (UnsafePointer<CChar>) -> UInt
    private typealias FrameFn = @convention(c) (
        UInt, UnsafePointer<Float>, UnsafePointer<Float>, Int32, UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias FreeFn = @convention(c) (UInt) -> Void
    private typealias ResetFn = @convention(c) (UInt) -> Void
    private typealias IntFn = @convention(c) (UInt) -> Int32
    private typealias ErrFn = @convention(c) (UInt) -> UnsafePointer<CChar>?

    private let ctx: UInt
    private let frameFn: FrameFn
    private let resetFn: ResetFn
    private let freeFn: FreeFn
    private let errFn: ErrFn

    /// Hop size in samples (256 = 16 ms at 16 kHz).
    public let hopLength: Int

    /// Load the dylib and a GGUF model. The handle from `dlopen` is process-
    /// global and never closed (contexts may outlive any one instance's view
    /// of it; dylibs are not meaningfully unloadable on Darwin anyway).
    public init(libraryURL: URL, modelURL: URL) throws {
        guard let lib = dlopen(libraryURL.path(percentEncoded: false), RTLD_NOW) else {
            throw Error.libraryLoadFailed(String(cString: dlerror()))
        }
        func sym<T>(_ name: String, as type: T.Type) throws -> T {
            guard let p = dlsym(lib, name) else { throw Error.symbolMissing(name) }
            return unsafeBitCast(p, to: T.self)
        }
        let newFn = try sym("localvqe_new", as: NewFn.self)
        self.frameFn = try sym("localvqe_process_frame_f32", as: FrameFn.self)
        self.resetFn = try sym("localvqe_reset", as: ResetFn.self)
        self.freeFn = try sym("localvqe_free", as: FreeFn.self)
        self.errFn = try sym("localvqe_last_error", as: ErrFn.self)
        let rateFn = try sym("localvqe_sample_rate", as: IntFn.self)
        let hopFn = try sym("localvqe_hop_length", as: IntFn.self)

        let ctx = modelURL.path(percentEncoded: false).withCString { newFn($0) }
        guard ctx != 0 else {
            throw Error.modelLoadFailed("localvqe_new returned null for \(modelURL.lastPathComponent)")
        }
        let rate = Int(rateFn(ctx)), hop = Int(hopFn(ctx))
        guard rate == Int(Resampler.targetRate), hop > 0 else {
            freeFn(ctx)
            throw Error.unexpectedFormat(sampleRate: rate, hop: hop)
        }
        self.ctx = ctx
        self.hopLength = hop
    }

    deinit { freeFn(ctx) }

    /// Process one hop. `mic`/`reference` must be exactly `hopLength` samples.
    /// Returns nil on an engine error (caller passes raw mic through).
    func processHop(mic: UnsafePointer<Float>, reference: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>) -> Bool {
        frameFn(ctx, mic, reference, Int32(hopLength), out) == 0
    }

    var lastError: String {
        errFn(ctx).map { String(cString: $0) } ?? ""
    }

    /// Reset streaming state (between sessions).
    public func reset() { resetFn(ctx) }
}

/// Wall-clock-aligned streaming AEC stage between the mic and system
/// pipelines. Both feeds are 16 kHz mono; each side declares its stream
/// anchor (the wall clock of its sample 0) on first use, letting the
/// canceller map mic sample i ↔ reference sample j without either side
/// knowing about the other. The residual acoustic delay (output buffer +
/// speaker→mic flight, ~40–100 ms) is left to the model's adaptive filter
/// front-end, which measured fine at up to a few hundred ms in the spike
/// (scratch/localvqe-spike).
public actor EchoCanceller {
    private let engine: LocalVQE
    private let hop: Int

    private var micAnchor: Date?
    private var referenceAnchor: Date?

    /// Mic samples not yet processed (waiting for hop fill or reference).
    private var pendingMic: [Float] = []
    /// Absolute index (in the mic stream) of pendingMic[0].
    private var pendingMicStart: Int64 = 0
    private var micSamplesReceived: Int64 = 0

    /// Retained reference history. Trimmed to what queued mic could need.
    private var reference: [Float] = []
    /// Absolute index (in the reference stream) of reference[0].
    private var referenceStart: Int64 = 0
    private var referenceSamplesReceived: Int64 = 0

    /// Bound on how long mic audio waits for its reference before being
    /// passed through raw (reference stream stalled or absent): 3 s.
    private let maxReferenceWaitSamples: Int64 = 3 * Int64(Resampler.targetRate)
    /// Reference history floor kept behind the oldest queued mic sample —
    /// must cover the refiner's negative search range plus slack.
    private let referenceSlackSamples: Int64 = 3 * Int64(Resampler.targetRate)

    // MARK: Delay refinement
    //
    // Anchors get the alignment into the right second; they cannot be
    // trusted to the tens of milliseconds the AEC's adaptive filter needs
    // (anchor stamping happens near — not at — each stream's sample 0, and
    // a mis-timed stream upstream shifts everything). So the canceller
    // *measures* the residual offset: 20 ms RMS envelopes of both streams,
    // cross-correlated over the trailing window across ±2 s of candidate
    // refinements, confidence-gated, and applied to future hops only.
    // (Same approach Muesli ships; validated in scratch/localvqe-spike.)

    /// Envelope frame: 20 ms at 16 kHz. Absolute frame indices are derived
    /// from the samples-received counters (frames ever produced minus the
    /// array length gives each array's base), so front-trimming is free.
    private let envFrame = 320
    private var micEnv: [Float] = []
    private var micEnvCarry: [Float] = []
    private var refEnv: [Float] = []
    private var refEnvCarry: [Float] = []
    /// Applied refinement, in samples, on top of the anchor offset.
    private var refinedOffsetSamples: Int64 = 0
    /// Recent accepted candidate refinements (frames), for consistency gating.
    private var recentEstimates: [Int] = []
    private var micFramesAtLastEstimate: Int = 0

    private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "aec")

    public init(engine: LocalVQE) {
        self.engine = engine
        self.hop = engine.hopLength
        // Each canceller expects virgin streaming state; clear anything a
        // previous user of this engine instance left behind.
        engine.reset()
    }

    /// Offset of the mic timeline into the reference timeline: the reference
    /// sample index that plays at the same wall instant as mic sample 0,
    /// anchor-derived plus the measured refinement.
    private var micToReferenceOffset: Int64? {
        guard let micAnchor, let referenceAnchor else { return nil }
        let anchorOffset = Int64(
            (micAnchor.timeIntervalSince(referenceAnchor) * Resampler.targetRate).rounded())
        return anchorOffset + refinedOffsetSamples
    }

    /// Feed far-end (system tap) samples. `anchor` is the wall clock of the
    /// stream's sample 0; constant per stream, only read on first call.
    public func feedReference(_ samples: [Float], anchor: Date) {
        if referenceAnchor == nil { referenceAnchor = anchor }
        appendEnvelope(samples, env: &refEnv, carry: &refEnvCarry)
        reference.append(contentsOf: samples)
        referenceSamplesReceived += Int64(samples.count)
        trimReference()
    }

    /// Feed mic samples; returns cleaned audio (may lag the input by up to
    /// the buffered amount — output order and count are preserved across
    /// calls, so callers can treat this as a streaming filter). Call
    /// `flushMic()` at end of stream for the tail.
    public func processMic(_ samples: [Float], anchor: Date) -> [Float] {
        if micAnchor == nil { micAnchor = anchor }
        appendEnvelope(samples, env: &micEnv, carry: &micEnvCarry)
        pendingMic.append(contentsOf: samples)
        micSamplesReceived += Int64(samples.count)
        refineOffsetIfDue()
        return drain(force: false)
    }

    /// End of mic stream: process whatever reference exists, pass the rest raw.
    public func flushMic() -> [Float] {
        drain(force: true)
    }

    private func drain(force: Bool) -> [Float] {
        guard let offset = micToReferenceOffset else {
            // No reference stream yet (mic-only mode, or system not up):
            // pass through immediately. Holding would only add latency —
            // samples from before the reference stream's sample 0 map to
            // negative reference indices and zero-fill (passthrough) anyway.
            return passthrough(upTo: pendingMic.count)
        }

        var out: [Float] = []
        var refBuf = [Float](repeating: 0, count: hop)
        var outBuf = [Float](repeating: 0, count: hop)
        // Local read cursor into pendingMic; consumed samples are removed in
        // ONE removeFirst after the loop (per-hop removeFirst is O(n) each,
        // quadratic over a batch-fed track).
        var cursor = 0

        while pendingMic.count - cursor >= hop {
            let hopStart = pendingMicStart + Int64(cursor)
            let hopStartInRef = hopStart + offset
            let hopEndInRef = hopStartInRef + Int64(hop)

            if hopEndInRef > referenceSamplesReceived {
                // Reference hasn't caught up. Wait — unless the wait bound is
                // exceeded or we're flushing, in which case zero-fill the
                // missing reference (the model treats silence as "no echo",
                // which degrades to passthrough behavior for that span).
                let waited = Int64(pendingMic.count - cursor)
                if !force && waited <= maxReferenceWaitSamples { break }
            }

            let lo = hopStartInRef - referenceStart
            for i in 0..<hop {
                let j = lo + Int64(i)
                refBuf[i] = (j >= 0 && j < Int64(reference.count)) ? reference[Int(j)] : 0
            }

            let ok = pendingMic.withUnsafeBufferPointer { mp in
                refBuf.withUnsafeBufferPointer { rp in
                    outBuf.withUnsafeMutableBufferPointer { op in
                        engine.processHop(
                            mic: mp.baseAddress! + cursor, reference: rp.baseAddress!,
                            into: op.baseAddress!)
                    }
                }
            }
            if ok {
                out.append(contentsOf: outBuf)
            } else {
                Self.log.error("AEC hop failed (\(self.engine.lastError, privacy: .public)); passing raw")
                out.append(contentsOf: pendingMic[cursor..<(cursor + hop)])
            }
            cursor += hop
        }
        if cursor > 0 {
            pendingMic.removeFirst(cursor)
            pendingMicStart += Int64(cursor)
        }

        if force && !pendingMic.isEmpty {
            // Sub-hop tail: too short for the model, emit raw.
            out.append(contentsOf: passthrough(upTo: pendingMic.count))
        }
        trimReference()
        return out
    }

    private func passthrough(upTo count: Int) -> [Float] {
        let n = max(0, min(count, pendingMic.count))
        guard n > 0 else { return [] }
        let out = Array(pendingMic.prefix(n))
        pendingMic.removeFirst(n)
        pendingMicStart += Int64(n)
        return out
    }

    // MARK: - Delay refinement internals

    private func appendEnvelope(_ samples: [Float], env: inout [Float], carry: inout [Float]) {
        carry.append(contentsOf: samples)
        var i = 0
        carry.withUnsafeBufferPointer { buf in
            while i + envFrame <= buf.count {
                var rms: Float = 0
                vDSP_rmsqv(buf.baseAddress! + i, 1, &rms, vDSP_Length(envFrame))
                env.append(rms)
                i += envFrame
            }
        }
        carry.removeFirst(i)
        // Cap envelope history at ~40 s (2000 frames) per side.
        let cap = 2000
        if env.count > cap {
            env.removeFirst(env.count - cap)
        }
    }

    /// Re-estimate the residual offset every ~4 s of mic audio, over the
    /// trailing ~16 s, searching ±2 s around the current total offset.
    /// Accepted only on confident, consistent estimates; applied to future
    /// hops (the model's adaptive filter reconverges in ~0.3 s).
    private func refineOffsetIfDue() {
        guard micAnchor != nil, referenceAnchor != nil else { return }
        let estimateEveryFrames = 200  // 4 s
        // Gate on CUMULATIVE frames produced, not the array length — micEnv
        // is capped, so its count stops growing after ~40 s and an
        // array-length gate would silence the refiner for good.
        let framesProduced = Int(micSamplesReceived) / envFrame
        guard framesProduced - micFramesAtLastEstimate >= estimateEveryFrames else { return }
        micFramesAtLastEstimate = framesProduced

        guard let offset = micToReferenceOffset else { return }
        let offsetFrames = Int(offset) / envFrame

        let windowFrames = min(800, micEnv.count)  // ≤16 s
        let micLo = micEnv.count - windowFrames
        let searchFrames = 100  // ±2 s

        // Active gating on the reference: only frames with real far-end
        // energy participate, so silence doesn't reward every candidate.
        let refPeak = refEnv.suffix(windowFrames + 2 * searchFrames).max() ?? 0
        guard refPeak > 1e-4 else { return }
        let active = 0.15 * refPeak

        var best = (refinement: 0, score: -1.0)
        var zeroScore = -1.0
        // Envelope-frame indexing: micEnv is trimmed from the front, so map
        // local index → absolute frame via the counts consumed so far.
        let micAbsBase = Int(micSamplesReceived) / envFrame - micEnv.count
        let refAbsBase = Int(referenceSamplesReceived) / envFrame - refEnv.count
        for r in -searchFrames...searchFrames {
            var num = 0.0, denM = 0.0, denR = 0.0
            var count = 0
            for k in micLo..<micEnv.count {
                let refAbs = (micAbsBase + k) + offsetFrames + r
                let refLocal = refAbs - refAbsBase
                guard refLocal >= 0, refLocal < refEnv.count else { continue }
                let rv = Double(refEnv[refLocal])
                guard rv > Double(active) else { continue }
                let mv = Double(micEnv[k])
                num += mv * rv
                denM += mv * mv
                denR += rv * rv
                count += 1
            }
            guard count > 100, denM > 0, denR > 0 else { continue }
            let score = num / (denM.squareRoot() * denR.squareRoot())
            if r == 0 { zeroScore = score }
            if score > best.score { best = (r, score) }
        }

        guard best.score >= 0.55 else { return }
        // Keep the current alignment unless the winner clearly beats it.
        if best.refinement != 0 && zeroScore > 0 && best.score - zeroScore < 0.05 { return }

        recentEstimates.append(best.refinement)
        if recentEstimates.count > 5 { recentEstimates.removeFirst() }
        // Consistency: at least 2 of the last 3 estimates within 100 ms of
        // the newest before we move.
        let recent = recentEstimates.suffix(3)
        let agreeing = recent.filter { abs($0 - best.refinement) <= 5 }.count
        guard agreeing >= 2 || recentEstimates.count == 1 else { return }
        guard best.refinement != 0 else { return }

        let shift = Int64(best.refinement * envFrame)
        refinedOffsetSamples += shift
        // The applied shift moves the mapping; recorded estimates are
        // relative to the *old* offset, so rebase them.
        recentEstimates = recentEstimates.map { $0 - best.refinement }
        Self.log.notice(
            "AEC delay refined by \(Double(shift) / Resampler.targetRate * 1000, format: .fixed(precision: 0)) ms (total \(Double(self.refinedOffsetSamples) / Resampler.targetRate * 1000, format: .fixed(precision: 0)) ms, score \(best.score, format: .fixed(precision: 2)))"
        )
    }

    private func trimReference() {
        // Keep everything the oldest queued mic sample could still need,
        // minus generous slack; drop the rest.
        guard let offset = micToReferenceOffset else {
            // No mic side yet: cap raw retention at ~30 s.
            let cap = Int64(30) * Int64(Resampler.targetRate)
            if Int64(reference.count) > cap {
                let drop = Int64(reference.count) - cap
                reference.removeFirst(Int(drop))
                referenceStart += drop
            }
            return
        }
        // Advance referenceStart by exactly what was removed — clamping the
        // removal but not the index would desync referenceStart from
        // reference[0] whenever the mic drains past the received reference.
        let needFrom = pendingMicStart + offset - referenceSlackSamples
        let drop = min(needFrom - referenceStart, Int64(reference.count))
        if drop > 0 {
            reference.removeFirst(Int(drop))
            referenceStart += drop
        }
    }
}
