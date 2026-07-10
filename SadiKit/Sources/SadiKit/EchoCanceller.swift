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
    /// generous slack for anchor error on either side.
    private let referenceSlackSamples: Int64 = Int64(Resampler.targetRate)

    private var passthroughHops = 0
    private var processedHops = 0

    private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "aec")

    public init(engine: LocalVQE) {
        self.engine = engine
        self.hop = engine.hopLength
    }

    /// Offset of the mic timeline into the reference timeline: the reference
    /// sample index that plays at the same wall instant as mic sample 0.
    private var micToReferenceOffset: Int64? {
        guard let micAnchor, let referenceAnchor else { return nil }
        return Int64((micAnchor.timeIntervalSince(referenceAnchor) * Resampler.targetRate).rounded())
    }

    /// Feed far-end (system tap) samples. `anchor` is the wall clock of the
    /// stream's sample 0; constant per stream, only read on first call.
    public func feedReference(_ samples: [Float], anchor: Date) {
        if referenceAnchor == nil { referenceAnchor = anchor }
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
        pendingMic.append(contentsOf: samples)
        micSamplesReceived += Int64(samples.count)
        return drain(force: false)
    }

    /// End of mic stream: process whatever reference exists, pass the rest raw.
    public func flushMic() -> [Float] {
        drain(force: true)
    }

    public func stats() -> (processed: Int, passthrough: Int) {
        (processedHops, passthroughHops)
    }

    private func drain(force: Bool) -> [Float] {
        guard let offset = micToReferenceOffset else {
            // No reference stream yet (mic-only mode, or system not up):
            // hold up to the wait bound, then pass through. Hold in *hop*
            // units so a late-starting system stream begins cleanly.
            if force || Int64(pendingMic.count) > maxReferenceWaitSamples {
                return passthrough(upTo: force ? pendingMic.count : pendingMic.count - Int(maxReferenceWaitSamples / 2))
            }
            return []
        }

        var out: [Float] = []
        var micBuf = [Float](repeating: 0, count: hop)
        var refBuf = [Float](repeating: 0, count: hop)
        var outBuf = [Float](repeating: 0, count: hop)

        while pendingMic.count >= hop {
            let hopStartInRef = pendingMicStart + offset
            let hopEndInRef = hopStartInRef + Int64(hop)

            if hopEndInRef > referenceSamplesReceived {
                // Reference hasn't caught up. Wait — unless the wait bound is
                // exceeded or we're flushing, in which case zero-fill the
                // missing reference (the model treats silence as "no echo",
                // which degrades to passthrough behavior for that span).
                let waited = micSamplesReceived - pendingMicStart
                if !force && waited <= maxReferenceWaitSamples { break }
            }

            for i in 0..<hop { micBuf[i] = pendingMic[i] }
            let lo = hopStartInRef - referenceStart
            for i in 0..<hop {
                let j = lo + Int64(i)
                refBuf[i] = (j >= 0 && j < Int64(reference.count)) ? reference[Int(j)] : 0
            }

            let ok = micBuf.withUnsafeBufferPointer { mp in
                refBuf.withUnsafeBufferPointer { rp in
                    outBuf.withUnsafeMutableBufferPointer { op in
                        engine.processHop(
                            mic: mp.baseAddress!, reference: rp.baseAddress!,
                            into: op.baseAddress!)
                    }
                }
            }
            if ok {
                out.append(contentsOf: outBuf)
                processedHops += 1
            } else {
                Self.log.error("AEC hop failed (\(self.engine.lastError, privacy: .public)); passing raw")
                out.append(contentsOf: micBuf)
                passthroughHops += 1
            }
            pendingMic.removeFirst(hop)
            pendingMicStart += Int64(hop)
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
        passthroughHops += n / max(1, hop)
        return out
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
        let needFrom = pendingMicStart + offset - referenceSlackSamples
        let drop = needFrom - referenceStart
        if drop > 0 {
            reference.removeFirst(Int(min(drop, Int64(reference.count))))
            referenceStart += drop
        }
    }
}
