import AudioToolbox
import CoreAudio
import Foundation
import OSLog
import Synchronization

/// Microphone capture per SPEC §5.1.
///
/// Uses a raw **AUHAL input unit** (`kAudioUnitSubType_HALOutput`, input-enabled)
/// rather than `AVAudioEngine`. On macOS `AVAudioEngine` silently builds a hidden
/// input+output *aggregate* device the moment you touch it and can only address
/// one device for both directions — which forces Bluetooth headsets into their
/// low-quality full-duplex (HFP) mode and produces "config change pending" /
/// `kAudioUnitErr_InvalidElement` storms on any device change. An AUHAL unit sits
/// directly on a single `AudioDevice` with no aggregate and no graph, so
/// following the system default mic is just an `kAudioOutputUnitProperty_CurrentDevice`
/// set on the live unit — no rebuild, no feedback loop, and it survives hardware
/// vanishing mid-stream (Apple TN2091; this is what robust capture apps use).
///
/// The realtime input callback renders into a pre-allocated buffer list, extracts
/// channel 0 (averaging multi-mic arrays destroys the voice signal on MacBook
/// built-ins), back-fills any host-time gap with silence (so the ring's sample
/// count stays locked to wall-clock for echo alignment), and pushes into the SPSC
/// ring. Everything else — resampling, file writing, VAD, ASR — runs on a
/// normal-priority consumer that pulls from the ring.
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
    private var isRunning = false

    /// Serializes device-follow against itself; also the queue the CoreAudio
    /// default-input listener fires on.
    private let reconfigQueue = DispatchQueue(label: "io.kbl.sadi.miccapture.reconfig")
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    /// Device the unit is currently bound to.
    private var boundDeviceID: AudioDeviceID = 0
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

        // ~5 s of source-rate audio (~1 MB). See SPEC §5.0 — long ASR + embedding
        // stalls on the consumer would otherwise overflow a 1-second ring.
        let cap = MicCapture.nextPowerOfTwo(Int(hw.rounded(.up)) * 5)
        self.ring = SPSCRingBuffer(capacity: cap)
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard !isRunning else { return }
        firstHostTimeAtomic.store(0, ordering: .releasing)
        nextExpectedHostTimeAtomic.store(0, ordering: .releasing)

        let unit = try makeInputUnit()
        self.unit = unit

        try bringUp(unit, device: MicCapture.preferredInputDevice())

        isRunning = true
        registerDeviceChangeListener()
    }

    public func stop() {
        guard isRunning else { return }
        // Flag first so an in-flight/scheduled reconcile bails, drop the listener
        // so no new ones are scheduled, then tear down ON the reconfig queue so
        // we never operate the unit from two threads (and never race a switch
        // that's mid-`AudioOutputUnitStart`). The sync waits at most one
        // single-shot switch (~1 s on a balky Bluetooth device), not a beachball.
        isRunning = false
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
        if isRunning { teardownUnit() }
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

    // MARK: - AUHAL setup

    /// Create the HAL output unit, enable input / disable output, and install the
    /// input callback. Device + format are set later in `configure(_:forDevice:)`.
    private func makeInputUnit() throws -> AudioUnit {
        var acd = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
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

        // Enable input (element 1), disable output (element 0). Order matters:
        // the device can only be set after IO is enabled.
        if MicCapture.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1)) != noErr
            || MicCapture.set(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0)) != noErr {
            AudioComponentInstanceDispose(unit)
            throw Error.configurationFailed(-1)
        }

        // Allow large input buffers so AudioUnitRender never overruns our ABL.
        _ = MicCapture.set(
            unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
            UInt32(MicCapture.maxRenderFrames))

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
        return unit
    }

    /// Point the unit at `device`, read that device's native input channel count,
    /// set our client format (Float32, non-interleaved, fixed `sampleRate`) and
    /// (re)allocate the render buffer list. Must run while the unit is
    /// uninitialized (start, or stopped+uninitialized during a switch).
    private func configure(_ unit: AudioUnit, forDevice device: AudioDeviceID) throws {
        if device != 0 {
            let s = MicCapture.set(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, device)
            guard s == noErr else { throw Error.configurationFailed(s) }
        }
        boundDeviceID = device

        // Device's native input format lives on the input scope of element 1.
        var deviceFormat = AudioStreamBasicDescription()
        var dfSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &dfSize)
        let channels = max(1, Int(deviceFormat.mChannelsPerFrame))

        // Our desired output of the input bus: Float32, deinterleaved (so channel
        // 0 is its own buffer), at the fixed client rate. The AUHAL inserts an
        // AudioConverter to bridge device format → this.
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let fmtStatus = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard fmtStatus == noErr else { throw Error.configurationFailed(fmtStatus) }

        allocateRenderBuffers(channels: channels)
    }

    // MARK: - Realtime input callback

    /// Non-capturing trampoline → instance `render`. Non-capturing so it converts
    /// to the C `AURenderCallback` function pointer.
    private static let inputProc: AURenderCallback = { refCon, flags, timestamp, _, frames, _ in
        Unmanaged<MicCapture>.fromOpaque(refCon).takeUnretainedValue()
            .render(flags: flags, timestamp: timestamp, frames: frames)
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
                            else { break }  // ring full — best-effort, don't spin
                            gap -= c
                        }
                    }
                }
            }
        }

        _ = ring.push(data: UnsafeBufferPointer(start: ch0, count: n))

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
        var addr = MicCapture.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReconcile()  // already on reconfigQueue
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, reconfigQueue, block)
        if status == noErr {
            defaultInputListener = block
        } else {
            Self.log.error("Add default-input listener failed: \(status, privacy: .public)")
        }
    }

    private func removeDeviceChangeListener() {
        guard let block = defaultInputListener else { return }
        var addr = MicCapture.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, reconfigQueue, block)
        defaultInputListener = nil
    }

    private func scheduleReconcile() {
        guard isRunning else { return }
        reconcileGeneration &+= 1
        let generation = reconcileGeneration
        reconfigQueue.asyncAfter(deadline: .now() + MicCapture.reconcileDebounce) { [weak self] in
            guard let self, self.isRunning, generation == self.reconcileGeneration else { return }
            self.reconcile()
        }
    }

    /// Follow the system default input. Runs on `reconfigQueue`. No-op unless the
    /// default actually changed. Switching is a `CurrentDevice` set on the *live*
    /// unit (stop → uninitialize → reconfigure → initialize → start) — no engine,
    /// no aggregate, no graph reconfiguration, so no -10877 storm and no feedback
    /// loop (we change *our* unit, not the system default).
    private func reconcile() {
        guard isRunning, let unit else { return }
        let current = (try? MicCapture.defaultInputDevice()) ?? 0
        guard current != 0, current != boundDeviceID else { return }
        // Don't follow the mic onto a Bluetooth input. Activating an AirPods-style
        // HFP mic forces the whole device to low-quality full-duplex AND conflicts
        // with our system-audio output tap (the IO won't even start). The leading
        // meeting apps avoid this the same way: keep a built-in/wired mic and let
        // the system-audio tap capture the remote side. Stay on the current mic.
        guard !MicCapture.deviceIsBluetooth(current) else {
            Self.log.notice(
                "Default input \(current, privacy: .public) is Bluetooth; keeping current mic (HFP would conflict with system-audio capture)")
            return
        }
        guard MicCapture.deviceIsLiveInput(current) else {
            Self.log.notice("New default input \(current, privacy: .public) not a live input yet; deferring")
            return
        }

        let previous = boundDeviceID
        Self.log.notice("Default input changed (\(previous) → \(current)); switching mic device")
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        do {
            try bringUp(unit, device: current)
        } catch {
            // The new device wouldn't start (commonly a Bluetooth input mid-HFP
            // negotiation: StartIO returns 'nope'/ETIMEDOUT). Don't go dead —
            // restore the device we were just successfully recording from so
            // capture continues. We'll follow again on the next change.
            Self.log.error(
                "Mic switch to \(current, privacy: .public) failed (\(String(describing: error), privacy: .public)); restoring \(previous, privacy: .public)")
            if previous != 0, previous != current {
                do { try bringUp(unit, device: previous) } catch {
                    Self.log.error("Mic restore to \(previous, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    /// Configure the unit for `device`, initialize, and start — once. Throws on
    /// any failure, leaving the unit uninitialized so the caller can recover.
    /// One-shot by design: `AudioOutputUnitStart` blocks ~1 s on a not-ready
    /// device, so retrying in a loop would jam the serial queue for seconds and
    /// stall teardown.
    private func bringUp(_ unit: AudioUnit, device: AudioDeviceID) throws {
        try configure(unit, forDevice: device)
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

    private static func defaultInputDevice() throws -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = defaultInputAddress
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != 0 else { throw Error.noInputDevice }
        return deviceID
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
