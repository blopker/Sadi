import AudioToolbox
import CoreAudio
import Foundation
import OSLog
import Synchronization

/// Microphone capture per SPEC §5.1, with the OS echo canceller in-line.
///
/// Uses a raw **VoiceProcessingIO unit** (`kAudioUnitSubType_VoiceProcessingIO`)
/// rather than `AVAudioEngine`: the raw unit lets us bind the input (element 1)
/// and output (element 0) devices explicitly and follow device changes with a
/// plain `kAudioOutputUnitProperty_CurrentDevice` set — no hidden aggregate, no
/// graph rebuild storms (the reasons the previous AUHAL implementation avoided
/// AVAudioEngine still apply).
///
/// VPIO applies Apple's AEC + noise suppression to the mic stream, using
/// *everything played to the bound output device* — including other apps like
/// Zoom/Meet — as the echo reference. Far-end audio bleeding from the speakers
/// into the mic is removed at capture time, so the archive, ASR, and voiceprint
/// stages all see echo-suppressed audio; the text-level `EchoFilter` remains as
/// a backstop. The output element must stay enabled (it IS the reference tap);
/// we render silence to it. AGC is disabled (honest archive levels) and
/// other-audio ducking is pinned to minimum so the user's call volume is not
/// ducked. Verified recipe: scratch/speech-compare/vpio_probe.swift.
///
/// The realtime input callback renders the processed (mono) mic signal into a
/// pre-allocated buffer list, back-fills any host-time gap with silence (so the
/// ring's sample count stays locked to wall-clock for echo alignment), and
/// pushes into the SPSC ring. Everything else — resampling, file writing, VAD,
/// ASR — runs on a normal-priority consumer that pulls from the ring.
public final class MicCapture: @unchecked Sendable {
    public enum Error: Swift.Error {
        case noInputDevice
        case sampleRateUnavailable
        case componentUnavailable
        case unitCreationFailed(OSStatus)
        case configurationFailed(OSStatus)
        case startFailed(OSStatus)
    }

    /// Ring buffer of source-rate Float mono samples. Producer = realtime input
    /// callback, consumer = whoever calls `ring.pull(...)`.
    public let ring: SPSCRingBuffer

    /// Client sample rate, fixed for the session. The AUHAL's internal converter
    /// resamples whatever the device runs at (e.g. 16 kHz AirPods HFP) up/down to
    /// this rate, so the archive writer, resampler, and host-time math downstream
    /// never see a rate change across a device switch.
    public let sampleRate: Double

    private var unit: AudioUnit?
    /// Pre-allocated render target for `AudioUnitRender`, sized to the current
    /// device's input channel count. Rebuilt when the channel count changes.
    private var renderABL: UnsafeMutableAudioBufferListPointer?
    private var renderChannels = 0
    private static let maxRenderFrames = 16384

    private let firstHostTimeAtomic = Atomic<UInt64>(0)
    /// Host time at which the *next* sample is expected (end of the last buffer
    /// pushed). A buffer arriving later than this means real time elapsed with no
    /// samples (a device switch, or a stall); the gap is back-filled with silence
    /// so the ring's sample count tracks wall-clock — echo correction aligns mic
    /// vs system in wall-clock space derived from that count. 0 = nothing pushed.
    private let nextExpectedHostTimeAtomic = Atomic<UInt64>(0)
    /// `mach_absolute_time` ticks per source-rate sample. Converts a host-time
    /// gap into a sample count.
    private let hostTicksPerSample: Double
    /// Pre-allocated zeros for realtime-safe gap fill (no allocation in callback).
    private let silence = [Float](repeating: 0, count: 4096)
    /// Source frames the realtime callback failed to push because the ring was
    /// full (audio + gap-fill silence). Monotonic per session. The consumer
    /// polls this to keep its sample-count↔wall-clock invariant (the failed
    /// frames are accounted as a timeline gap) and to trip the stall failsafe.
    private let droppedFramesAtomic = Atomic<UInt64>(0)
    /// Atomic because it crosses threads with no shared lock: `start()`/`stop()`
    /// run on the caller's (typically detached) thread while the device-follow
    /// listener reads it on `reconfigQueue`.
    private let isRunningAtomic = Atomic<Bool>(false)

    /// Serializes device-follow against itself; also the queue the CoreAudio
    /// default-device listeners fire on. Explicit `.userInitiated` QoS:
    /// `stop()` is called from user-initiated tasks and does a `sync` wait on
    /// this queue for the (blocking) VPIO teardown — an unspecified-QoS queue
    /// there trips the Thread Performance Checker's priority-inversion
    /// diagnostic.
    private let reconfigQueue = DispatchQueue(
        label: "io.kbl.sadi.miccapture.reconfig", qos: .userInitiated)
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?
    /// Input device the unit is currently bound to (element 1).
    private var boundDeviceID: AudioDeviceID = 0
    /// Output device the unit is currently bound to (element 0) — the AEC
    /// reference. Follows the default output so cancellation tracks wherever
    /// the far-end audio is actually playing.
    private var boundOutputDeviceID: AudioDeviceID = 0
    private var reconcileGeneration = 0
    /// Quiet window for the device-follow debounce — long enough to ride out a
    /// Bluetooth A2DP→HFP profile flap so we switch once, to the settled device.
    private static let reconcileDebounce: DispatchTimeInterval = .milliseconds(1000)

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "mic")

    /// `mach_absolute_time` of the very first sample pushed into the ring;
    /// nil until the first callback has run.
    public var firstHostTime: UInt64? {
        let raw = firstHostTimeAtomic.load(ordering: .acquiring)
        return raw == 0 ? nil : raw
    }

    /// Cumulative count of source frames lost to ring overflow since `start()`.
    public var droppedFrames: UInt64 {
        droppedFramesAtomic.load(ordering: .relaxed)
    }

    public init() throws {
        let device = MicCapture.preferredInputDevice()
        guard device != 0 else { throw Error.noInputDevice }
        let hw = try MicCapture.nominalSampleRate(of: device)
        self.sampleRate = hw

        // host ticks → nanoseconds is `ticks * numer/denom`, so one sample
        // (1/hw seconds) is `(1e9 / hw) * (denom/numer)` host ticks.
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        self.hostTicksPerSample = (1_000_000_000.0 / hw) * (Double(tb.denom) / Double(tb.numer))

        // ~10 s of source-rate audio (~2 MB). The consumer side only does disk
        // appends (transcription is decoupled behind its own buffer), so this
        // is pure headroom for disk-latency spikes; overflowing it trips the
        // stall failsafe (see `droppedFrames`) rather than silently desyncing.
        let cap = MicCapture.nextPowerOfTwo(Int(hw.rounded(.up)) * 10)
        self.ring = SPSCRingBuffer(capacity: cap)
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isRunningAtomic.load(ordering: .acquiring) else { return }
        firstHostTimeAtomic.store(0, ordering: .releasing)
        nextExpectedHostTimeAtomic.store(0, ordering: .releasing)
        droppedFramesAtomic.store(0, ordering: .releasing)

        let unit = try makeInputUnit()
        self.unit = unit

        try bringUp(
            unit,
            device: MicCapture.preferredInputDevice(),
            output: MicCapture.preferredOutputDevice())

        isRunningAtomic.store(true, ordering: .releasing)
        registerDeviceChangeListener()
    }

    public func stop() {
        // Flag first (exchange makes a concurrent double-stop single-winner)
        // so an in-flight/scheduled reconcile bails, drop the listener so no
        // new ones are scheduled, then tear down ON the reconfig queue so we
        // never operate the unit from two threads (and never race a switch
        // that's mid-`AudioOutputUnitStart`). The sync waits at most one
        // single-shot switch (~1 s on a balky Bluetooth device), not a beachball.
        guard isRunningAtomic.exchange(false, ordering: .acquiringAndReleasing) else { return }
        removeDeviceChangeListener()
        reconfigQueue.sync { teardownUnit() }
    }

    deinit {
        // Contract: call `stop()` before dropping a running capture. The input
        // callback holds an UNRETAINED pointer to self, so a callback firing
        // concurrently with deallocation would touch a dying object. `stop()`
        // calls `AudioOutputUnitStop` (synchronous — blocks until the current
        // callback exits and guarantees no more), closing that window. This
        // deinit teardown is only a best-effort backstop for misuse.
        removeDeviceChangeListener()
        if isRunningAtomic.load(ordering: .acquiring) { teardownUnit() }
    }

    private func teardownUnit() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        freeRenderBuffers()
    }

    // MARK: - VPIO setup

    /// Create the VoiceProcessingIO unit, enable input (element 1) *and* output
    /// (element 0 — required: the output stream is the AEC reference), install
    /// the input callback and a silence render callback, and set the voice-
    /// processing knobs. Devices + formats are set later in `configure`.
    private func makeInputUnit() throws -> AudioUnit {
        var acd = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &acd) else {
            throw Error.componentUnavailable
        }
        var unit: AudioUnit?
        let s = AudioComponentInstanceNew(component, &unit)
        guard s == noErr, let unit else { throw Error.unitCreationFailed(s) }

        // Enable input (element 1) and output (element 0). Order matters:
        // devices can only be set after IO is enabled.
        if MicCapture.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1)) != noErr
            || MicCapture.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(1)) != noErr {
            AudioComponentInstanceDispose(unit)
            throw Error.configurationFailed(-1)
        }

        // Allow large input buffers so AudioUnitRender never overruns our ABL.
        _ = MicCapture.set(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            UInt32(MicCapture.maxRenderFrames))

        // AGC off: the recorded level should be what the mic heard, not a
        // pumped chat level. (AEC + noise suppression stay on — they're the
        // point.) Best-effort: absence of AGC is not worth failing capture.
        _ = MicCapture.set(
            unit, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, UInt32(0))

        // Never duck other apps' audio: the "other audio" here is the call the
        // user is listening to. Default config ducks it for voice chat.
        var ducking = AUVoiceIOOtherAudioDuckingConfiguration(
            mEnableAdvancedDucking: false,
            mDuckingLevel: .min
        )
        let duckStatus = AudioUnitSetProperty(
            unit, kAUVoiceIOProperty_OtherAudioDuckingConfiguration, kAudioUnitScope_Global, 0,
            &ducking, UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))
        if duckStatus != noErr {
            Self.log.error("Ducking config failed: \(duckStatus, privacy: .public) — other audio may duck")
        }

        var cb = AURenderCallbackStruct(
            inputProc: MicCapture.inputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        let cbStatus = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
            &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard cbStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw Error.configurationFailed(cbStatus)
        }

        // Output element renders silence — it exists purely so the unit can
        // tap the output device as its echo reference.
        var renderCB = AURenderCallbackStruct(
            inputProc: MicCapture.silenceProc,
            inputProcRefCon: nil
        )
        let renderStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &renderCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard renderStatus == noErr else {
            AudioComponentInstanceDispose(unit)
            throw Error.configurationFailed(renderStatus)
        }
        return unit
    }

    /// Bind the input device (element 1) and the AEC-reference output device
    /// (element 0), set our client formats (Float32 mono, fixed `sampleRate` —
    /// VPIO's processed voice output is mono; its converters bridge whatever
    /// the devices run at), and (re)allocate the render buffer list. Must run
    /// while the unit is uninitialized (start, or stopped+uninitialized during
    /// a switch).
    private func configure(
        _ unit: AudioUnit, forDevice device: AudioDeviceID, outputDevice: AudioDeviceID
    ) throws {
        if device != 0 {
            var dev = device
            let s = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 1,
                &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard s == noErr else { throw Error.configurationFailed(s) }
        }
        boundDeviceID = device
        if outputDevice != 0 {
            var dev = outputDevice
            let s = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard s == noErr else { throw Error.configurationFailed(s) }
        }
        boundOutputDeviceID = outputDevice

        // Processed mic out of the input bus: Float32 mono at the fixed client
        // rate. (No per-channel handling: VPIO consumes the device's mic array
        // itself and emits one processed voice channel.)
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let fmtStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard fmtStatus == noErr else { throw Error.configurationFailed(fmtStatus) }

        // Format of the silence we feed the output element.
        var silenceFormat = client
        let silStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &silenceFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard silStatus == noErr else { throw Error.configurationFailed(silStatus) }

        allocateRenderBuffers(channels: 1)
    }

    // MARK: - Realtime input callback

    /// Non-capturing trampoline → instance `render`. Non-capturing so it converts
    /// to the C `AURenderCallback` function pointer.
    private static let inputProc: AURenderCallback = { refCon, flags, timestamp, _, frames, _ in
        Unmanaged<MicCapture>.fromOpaque(refCon).takeUnretainedValue()
            .render(flags: flags, timestamp: timestamp, frames: frames)
    }

    /// Render callback for the output element: zero-fill. The element only
    /// exists so VPIO can tap the output device as its echo reference; we
    /// never play anything.
    private static let silenceProc: AURenderCallback = { _, flags, _, _, _, ioData in
        if let ioData {
            let list = UnsafeMutableAudioBufferListPointer(ioData)
            for i in 0..<list.count {
                if let d = list[i].mData { memset(d, 0, Int(list[i].mDataByteSize)) }
            }
        }
        flags.pointee.insert(.unitRenderAction_OutputIsSilence)
        return noErr
    }

    private func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frames: UInt32
    ) -> OSStatus {
        // Realtime thread: no allocation, no locks, no logging, no ObjC.
        guard let unit, let abl = renderABL else { return noErr }
        let n = Int(frames)
        if n == 0 || n > MicCapture.maxRenderFrames { return noErr }

        let byteSize = UInt32(n * MemoryLayout<Float>.stride)
        for i in 0..<abl.count { abl[i].mDataByteSize = byteSize }

        let status = AudioUnitRender(unit, flags, timestamp, 1, frames, abl.unsafeMutablePointer)
        guard status == noErr else { return status }
        guard let ch0 = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

        let hostTime = timestamp.pointee.mHostTime

        let first = firstHostTimeAtomic.compareExchange(
            expected: 0, desired: hostTime, ordering: .acquiringAndReleasing)

        // Gap fill: if this buffer starts well after the last one ended, push
        // silence for the skipped time so the ring's sample count keeps tracking
        // wall-clock. Skipped on the first-ever buffer.
        if !first.exchanged {
            let expected = nextExpectedHostTimeAtomic.load(ordering: .acquiring)
            if expected != 0, hostTime > expected {
                var gap = Int(Double(hostTime - expected) / hostTicksPerSample)
                if gap > n {  // ignore sub-buffer jitter; only fill a genuine gap
                    silence.withUnsafeBufferPointer { sil in
                        while gap > 0 {
                            let c = min(gap, sil.count)
                            guard ring.push(data: UnsafeBufferPointer(start: sil.baseAddress, count: c))
                            else {
                                // Ring full — best-effort, don't spin. Account
                                // the unfilled remainder so the consumer can
                                // keep the timeline and trip the failsafe.
                                droppedFramesAtomic.add(UInt64(gap), ordering: .relaxed)
                                break
                            }
                            gap -= c
                        }
                    }
                }
            }
        }

        if !ring.push(data: UnsafeBufferPointer(start: ch0, count: n)) {
            droppedFramesAtomic.add(UInt64(n), ordering: .relaxed)
        }

        let bufferTicks = UInt64(Double(n) * hostTicksPerSample)
        nextExpectedHostTimeAtomic.store(hostTime &+ bufferTicks, ordering: .releasing)
        return noErr
    }

    // MARK: - Render buffer management

    private func allocateRenderBuffers(channels: Int) {
        if renderChannels == channels, renderABL != nil { return }
        freeRenderBuffers()
        let abl = AudioBufferList.allocate(maximumBuffers: channels)
        let bytes = MicCapture.maxRenderFrames * MemoryLayout<Float>.stride
        for i in 0..<channels {
            let mem = UnsafeMutableRawPointer.allocate(
                byteCount: bytes, alignment: MemoryLayout<Float>.alignment)
            mem.initializeMemory(as: UInt8.self, repeating: 0, count: bytes)
            abl[i] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: mem)
        }
        renderABL = abl
        renderChannels = channels
    }

    private func freeRenderBuffers() {
        if let abl = renderABL {
            for i in 0..<abl.count { abl[i].mData?.deallocate() }
            // `AudioBufferList.allocate` uses Swift's allocator — must pair with
            // `.deallocate()`, NOT libc `free()` (mismatched allocator = UB).
            abl.unsafeMutablePointer.deallocate()
        }
        renderABL = nil
        renderChannels = 0
    }

    // MARK: - Device following

    private func registerDeviceChangeListener() {
        var inAddr = MicCapture.defaultInputAddress
        let inBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReconcile()  // already on reconfigQueue
        }
        let inStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &inAddr, reconfigQueue, inBlock)
        if inStatus == noErr {
            defaultInputListener = inBlock
        } else {
            Self.log.error("Add default-input listener failed: \(inStatus, privacy: .public)")
        }

        // Also follow the default *output*: it's the AEC reference. If the user
        // moves call audio to another device mid-recording, cancellation has to
        // move with it.
        var outAddr = MicCapture.defaultOutputAddress
        let outBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReconcile()
        }
        let outStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &outAddr, reconfigQueue, outBlock)
        if outStatus == noErr {
            defaultOutputListener = outBlock
        } else {
            Self.log.error("Add default-output listener failed: \(outStatus, privacy: .public)")
        }
    }

    private func removeDeviceChangeListener() {
        if let block = defaultInputListener {
            var addr = MicCapture.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, reconfigQueue, block)
            defaultInputListener = nil
        }
        if let block = defaultOutputListener {
            var addr = MicCapture.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, reconfigQueue, block)
            defaultOutputListener = nil
        }
    }

    private func scheduleReconcile() {
        guard isRunningAtomic.load(ordering: .acquiring) else { return }
        reconcileGeneration &+= 1
        let generation = reconcileGeneration
        reconfigQueue.asyncAfter(deadline: .now() + MicCapture.reconcileDebounce) { [weak self] in
            guard let self,
                  self.isRunningAtomic.load(ordering: .acquiring),
                  generation == self.reconcileGeneration
            else { return }
            self.reconcile()
        }
    }

    /// Follow the system default input and output. Runs on `reconfigQueue`.
    /// No-op unless a bound device actually needs to change. Switching is a
    /// `CurrentDevice` set on the *live* unit (stop → uninitialize →
    /// reconfigure → initialize → start) — no engine, no aggregate, no graph
    /// reconfiguration, so no -10877 storm and no feedback loop (we change
    /// *our* unit, not the system default).
    private func reconcile() {
        guard isRunningAtomic.load(ordering: .acquiring), let unit else { return }

        // Desired input: the system default — unless it's Bluetooth (an
        // AirPods-style HFP mic forces the whole device to low-quality
        // full-duplex AND conflicts with our system-audio output tap; the
        // leading meeting apps also refuse it) or not yet a live input
        // (mid-creation during a profile transition).
        var targetInput = boundDeviceID
        let currentDefault = (try? MicCapture.defaultInputDevice()) ?? 0
        if currentDefault != 0, currentDefault != boundDeviceID {
            if MicCapture.deviceIsBluetooth(currentDefault) {
                Self.log.notice(
                    "Default input \(currentDefault, privacy: .public) is Bluetooth; keeping current mic (HFP would conflict with system-audio capture)")
            } else if !MicCapture.deviceIsLiveInput(currentDefault) {
                Self.log.notice(
                    "New default input \(currentDefault, privacy: .public) not a live input yet; deferring")
            } else {
                targetInput = currentDefault
            }
        }

        // Desired AEC reference: the (non-BT-preferred) default output.
        let targetOutput = MicCapture.preferredOutputDevice()

        guard targetInput != boundDeviceID
            || (targetOutput != 0 && targetOutput != boundOutputDeviceID)
        else { return }

        let previousInput = boundDeviceID
        let previousOutput = boundOutputDeviceID
        Self.log.notice(
            "Device follow: mic \(previousInput) → \(targetInput), AEC reference \(previousOutput) → \(targetOutput)")
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        do {
            try bringUp(unit, device: targetInput, output: targetOutput)
        } catch {
            // The new pair wouldn't start (commonly a device mid-transition:
            // StartIO returns 'nope'/ETIMEDOUT). Don't go dead — restore the
            // pair we were just successfully recording from so capture
            // continues. We'll follow again on the next change.
            Self.log.error(
                "Mic switch to (\(targetInput, privacy: .public), \(targetOutput, privacy: .public)) failed (\(String(describing: error), privacy: .public)); restoring (\(previousInput, privacy: .public), \(previousOutput, privacy: .public))")
            if previousInput != 0, (previousInput, previousOutput) != (targetInput, targetOutput) {
                do { try bringUp(unit, device: previousInput, output: previousOutput) } catch {
                    Self.log.error(
                        "Mic restore to (\(previousInput, privacy: .public), \(previousOutput, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Configure the unit for the device pair, initialize, and start — once.
    /// Throws on any failure, leaving the unit uninitialized so the caller can
    /// recover. One-shot by design: `AudioOutputUnitStart` blocks ~1 s on a
    /// not-ready device, so retrying in a loop would jam the serial queue for
    /// seconds and stall teardown.
    private func bringUp(_ unit: AudioUnit, device: AudioDeviceID, output: AudioDeviceID) throws {
        try configure(unit, forDevice: device, outputDevice: output)
        let s1 = AudioUnitInitialize(unit)
        guard s1 == noErr else { throw Error.configurationFailed(s1) }
        let s2 = AudioOutputUnitStart(unit)
        guard s2 == noErr else {
            AudioUnitUninitialize(unit)
            throw Error.startFailed(s2)
        }
    }

    // MARK: - Property helpers

    private static func set(
        _ unit: AudioUnit, _ id: AudioUnitPropertyID, _ scope: AudioUnitScope,
        _ element: AudioUnitElement, _ value: UInt32
    ) -> OSStatus {
        var v = value
        return AudioUnitSetProperty(unit, id, scope, element, &v, UInt32(MemoryLayout<UInt32>.size))
    }

    // MARK: - CoreAudio helpers

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

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func defaultInputDevice() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = defaultInputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { throw Error.noInputDevice }
        return deviceID
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = defaultOutputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : 0
    }

    /// True when `id` is a live device with at least one input stream. Guards
    /// against switching to a device that's mid-creation (a Bluetooth profile
    /// transition) or output-only.
    private static func deviceIsLiveInput(_ id: AudioDeviceID) -> Bool {
        var aliveAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var aliveSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &aliveAddr, 0, nil, &aliveSize, &alive) == noErr,
              alive == 1 else { return false }

        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize) == noErr else {
            return false
        }
        return streamsSize > 0
    }

    /// True when `id`'s transport is Bluetooth (classic or LE). We refuse to bind
    /// the mic to these while capturing system audio — see `reconcile`.
    private static func deviceIsBluetooth(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// All live input devices on the system.
    private static func allInputDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { deviceIsLiveInput($0) }
    }

    /// The mic device to bind. Prefers the system default input — unless it's
    /// Bluetooth (would force HFP and conflict with system-audio capture), in
    /// which case fall back to a non-Bluetooth input (built-in / USB). Last
    /// resort is the default itself, if Bluetooth is genuinely all that exists.
    private static func preferredInputDevice() -> AudioDeviceID {
        if let def = try? defaultInputDevice(), deviceIsLiveInput(def), !deviceIsBluetooth(def) {
            return def
        }
        if let nonBT = allInputDevices().first(where: { !deviceIsBluetooth($0) }) {
            return nonBT
        }
        return (try? defaultInputDevice()) ?? 0
    }

    /// The AEC-reference output device to bind. Prefers the system default
    /// output — unless it's Bluetooth: binding VPIO's output element to an
    /// A2DP device risks forcing it into low-quality HFP, and headphones mean
    /// there's no speaker→mic bleed to cancel anyway. Fall back to a non-BT
    /// output (built-in speakers), where the reference is simply quiet.
    private static func preferredOutputDevice() -> AudioDeviceID {
        let def = defaultOutputDevice()
        if def != 0, !deviceIsBluetooth(def) {
            return def
        }
        if let nonBT = allOutputDevices().first(where: { !deviceIsBluetooth($0) }) {
            return nonBT
        }
        return def
    }

    /// All devices with at least one output stream.
    private static func allOutputDevices() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sysObj = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sysObj, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sysObj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var sAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain)
            var sSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &sSize) == noErr && sSize > 0
        }
    }

    private static func nominalSampleRate(of device: AudioDeviceID) throws -> Double {
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let s = AudioObjectGetPropertyData(device, &rateAddr, 0, nil, &size, &rate)
        guard s == noErr, rate > 0 else { throw Error.sampleRateUnavailable }
        return rate
    }
}
