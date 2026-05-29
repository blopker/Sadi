import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Microphone capture per SPEC §5.1.
///
/// Installs an `AVAudioEngine` input-node tap on bus 0. Inside the realtime
/// tap callback we do exactly two things: extract channel 0 (multi-channel mic
/// arrays bleed/cancel if averaged) and push into the SPSC ring. Everything
/// else — resampling, file writing, VAD, ASR — happens on a normal-priority
/// consumer task that pulls from the ring.
///
/// `setVoiceProcessingEnabled` is never touched (see SPEC Appendix A).
public final class MicCapture: @unchecked Sendable {
    public enum Error: Swift.Error {
        case noInputDevice
        case sampleRateUnavailable
    }

    /// Ring buffer of source-rate Float mono samples. Producer = realtime tap
    /// thread, consumer = whoever calls `ring.pull(...)`.
    public let ring: SPSCRingBuffer

    /// Hardware nominal sample rate of the resolved input device, in Hz.
    /// Read once at init from `kAudioDevicePropertyNominalSampleRate` because
    /// `inputNode.outputFormat` can lag the hardware after device switches.
    public let sampleRate: Double

    private let engine = AVAudioEngine()
    private let firstHostTimeAtomic = Atomic<UInt64>(0)
    private var isRunning = false

    /// `mach_absolute_time` of the very first sample pushed into the ring;
    /// nil until the first tap callback has run.
    public var firstHostTime: UInt64? {
        let raw = firstHostTimeAtomic.load(ordering: .acquiring)
        return raw == 0 ? nil : raw
    }

    public init() throws {
        let hw = try MicCapture.hardwareInputSampleRate()
        self.sampleRate = hw
        // SPEC §5.0 budgets "~1 s" but the realistic stall on the consumer
        // side is `await processor.feed(...)` blocking while the per-track
        // actor runs ASR transcribe + WeSpeaker embedding for a long
        // segment — both can spike past a second on a busy machine. Size
        // at ~5 s of source-rate audio (~1 MB) so transient stalls don't
        // overflow the ring and drop samples on the archive + ASR paths.
        let cap = MicCapture.nextPowerOfTwo(Int(hw.rounded(.up)) * 5)
        self.ring = SPSCRingBuffer(capacity: cap)
    }

    public func start() throws {
        guard !isRunning else { return }
        firstHostTimeAtomic.store(0, ordering: .releasing)

        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)

        // SPEC §5.1: pin the tap rate to the hardware nominal rate we
        // resolved at init (`self.sampleRate`). `inputNode.outputFormat`
        // can lag the hardware after device switches; if we install the
        // tap at `nativeFormat` the ring buffer would carry samples at a
        // rate that disagrees with `self.sampleRate`, and every consumer
        // (resampler, AAC writer, host-time math) would be mis-clocked —
        // pitch-shifted output and accumulating drift. AVAudioEngine
        // inserts an internal sample-rate conversion when the tap format
        // differs from the bus format, so this stays correct even mid-lag.
        // Channels stay native so the channel-0 extract still has a
        // multi-channel buffer to work with.
        guard let tapFormat = AVAudioFormat(
            commonFormat: nativeFormat.commonFormat,
            sampleRate: sampleRate,
            channels: nativeFormat.channelCount,
            interleaved: nativeFormat.isInterleaved
        ) else {
            throw Error.sampleRateUnavailable
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, when in
            // Realtime thread: no allocation, no locks, no logging, no ObjC.
            guard let self else { return }
            guard let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            if frames == 0 { return }

            // Channel-0 extraction: SPEC §5.1 — averaging multi-channel mic
            // arrays destroys the voice signal on MacBook built-ins.
            let ch0 = channels[0]
            let buf = UnsafeBufferPointer(start: ch0, count: frames)
            _ = ring.push(data: buf)

            // Anchor the wall-clock conversion on the very first sample.
            _ = firstHostTimeAtomic.compareExchange(
                expected: 0,
                desired: when.hostTime,
                ordering: .acquiringAndReleasing
            )
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    deinit {
        // Best-effort teardown if the user forgot `stop()`. Once the tap
        // closure captures self weakly, this path is actually reachable.
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - Helpers

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        precondition(n > 0)
        var v = 1
        while v < n { v <<= 1 }
        return v
    }

    /// Resolve the system default input device and read its
    /// `kAudioDevicePropertyNominalSampleRate`. SPEC §5.1 calls this out as
    /// the authoritative rate; `inputNode.outputFormat` can stale-read across
    /// device switches.
    private static func hardwareInputSampleRate() throws -> Double {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let s1 = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard s1 == noErr, deviceID != 0 else { throw Error.noInputDevice }

        var rate: Double = 0
        size = UInt32(MemoryLayout<Double>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let s2 = AudioObjectGetPropertyData(deviceID, &rateAddr, 0, nil, &size, &rate)
        guard s2 == noErr, rate > 0 else { throw Error.sampleRateUnavailable }
        return rate
    }
}
