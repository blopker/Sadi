import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import OSLog
import Synchronization

/// Microphone capture per SPEC §5.1.
///
/// Installs an `AVAudioEngine` input-node tap on bus 0. Inside the realtime
/// tap callback we do exactly two things: extract channel 0 (multi-channel mic
/// arrays bleed/cancel if averaged) and push into the SPSC ring. Everything
/// else — resampling, file writing, VAD, ASR — happens on a normal-priority
/// consumer task that pulls from the ring.
///
/// The engine input node binds to the *system default* input device. macOS
/// does NOT automatically re-point it when the default changes (plug in
/// headphones / a USB interface and the old device goes silent), so we listen
/// for `kAudioHardwarePropertyDefaultInputDevice` and re-bind + restart on the
/// fly. The tap stays pinned to the original `sampleRate` and AVAudioEngine
/// resamples the new device for us, so every downstream consumer keeps its
/// clock contract even when the new device runs at a different native rate.
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
    /// Held fixed for the lifetime of the capture: if the default device later
    /// changes, the engine resamples the new device down/up to this rate so the
    /// archive writer and resampler downstream never see a rate change.
    public let sampleRate: Double

    private let engine = AVAudioEngine()
    private let firstHostTimeAtomic = Atomic<UInt64>(0)
    private var isRunning = false

    /// Serializes device re-binding against itself. Also the queue the
    /// CoreAudio property listener fires on.
    private let reconfigQueue = DispatchQueue(label: "io.kbl.sadi.miccapture.reconfig")
    /// Live CoreAudio listener block (kept so we can remove it on stop).
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    /// Observer token for `.AVAudioEngineConfigurationChange`.
    private var configObserver: NSObjectProtocol?
    /// The input device the engine is currently bound to.
    private var boundDeviceID: AudioDeviceID = 0

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "mic")

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

        try bindEngineInputToDefaultDevice()
        try installTapAndStartEngine()
        isRunning = true

        registerDeviceChangeListeners()
    }

    public func stop() {
        guard isRunning else { return }
        // Tear the listeners down first so a late device-change callback can't
        // resurrect the engine after we've stopped.
        removeDeviceChangeListeners()
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    deinit {
        removeDeviceChangeListeners()
        // Best-effort teardown if the user forgot `stop()`. Once the tap
        // closure captures self weakly, this path is actually reachable.
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - Engine wiring

    /// Install the bus-0 tap (pinned to `sampleRate`) and start the engine.
    /// Shared by `start()` and the device-change rebuild path.
    private func installTapAndStartEngine() throws {
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
        // differs from the bus format, so this stays correct even when a
        // freshly-plugged device runs at a different native rate.
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
    }

    /// Point the engine's input HAL unit at the current system default input
    /// device. Must be called while the engine is stopped. AVAudioEngine on
    /// macOS otherwise sticks to whichever device was default at first start,
    /// so without this an unplug/plug leaves the mic silent.
    private func bindEngineInputToDefaultDevice() throws {
        let device = try MicCapture.defaultInputDevice()
        boundDeviceID = device
        guard let unit = engine.inputNode.audioUnit else { return }
        var deviceID = device
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Self.log.error("Set input CurrentDevice failed: \(status, privacy: .public)")
        }
    }

    // MARK: - Device-change handling

    private func registerDeviceChangeListeners() {
        var addr = MicCapture.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Already on `reconfigQueue` (the listener's dispatch queue).
            self?.reconfigure(force: false)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, reconfigQueue, block
        )
        if status == noErr {
            defaultInputListener = block
        } else {
            Self.log.error("Add default-input listener failed: \(status, privacy: .public)")
        }

        // The engine also posts this when its current device's format changes
        // or the device disappears; rebuild unconditionally in that case.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.reconfigQueue.async { self.reconfigure(force: true) }
        }
    }

    private func removeDeviceChangeListeners() {
        if let block = defaultInputListener {
            var addr = MicCapture.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, reconfigQueue, block
            )
            defaultInputListener = nil
        }
        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }
    }

    /// Re-point the engine at the current default input device and restart.
    /// Always runs on `reconfigQueue`. `force` rebuilds even when the device
    /// id is unchanged (used for engine config-change events where only the
    /// format moved).
    private func reconfigure(force: Bool) {
        guard isRunning else { return }
        let newDevice = (try? MicCapture.defaultInputDevice()) ?? 0
        guard newDevice != 0 else { return }
        if !force, newDevice == boundDeviceID { return }

        Self.log.notice("Input device changed; re-binding mic capture to \(newDevice, privacy: .public)")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try bindEngineInputToDefaultDevice()
            try installTapAndStartEngine()
        } catch {
            Self.log.error("Re-bind after device change failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Helpers

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        precondition(n > 0)
        var v = 1
        while v < n { v <<= 1 }
        return v
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Resolve the system default input device id.
    private static func defaultInputDevice() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = defaultInputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { throw Error.noInputDevice }
        return deviceID
    }

    /// Resolve the system default input device and read its
    /// `kAudioDevicePropertyNominalSampleRate`. SPEC §5.1 calls this out as
    /// the authoritative rate; `inputNode.outputFormat` can stale-read across
    /// device switches.
    private static func hardwareInputSampleRate() throws -> Double {
        let deviceID = try defaultInputDevice()

        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
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
