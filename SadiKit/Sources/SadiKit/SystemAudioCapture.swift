import CoreAudio
import Foundation
import OSLog
import Synchronization

/// System-audio capture per SPEC §5.2.
///
/// CoreAudio process tap (macOS 14.4+) wrapped in a private aggregate device
/// with drift compensation enabled. The OS calls our IOProc on a realtime
/// thread; we extract the mono Float32 channel and push into the SPSC ring.
///
/// Deliberately NOT using ScreenCaptureKit — the tap API does not require
/// Screen Recording permission. It does, however, require
/// `NSAudioCaptureUsageDescription` in Info.plist and prompts the user for
/// "System Audio Recording" the first time `AudioDeviceStart` runs against
/// the aggregate.
public final class SystemAudioCapture: @unchecked Sendable {
    public enum Error: Swift.Error {
        case tapCreationFailed(OSStatus)
        case tapUIDUnavailable(OSStatus)
        case tapFormatUnavailable(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)
    }

    public let ring: SPSCRingBuffer

    /// Nominal sample rate reported by the tap's format. The actual delivered
    /// rate can drift; SPEC §5.2 / Phase 9 covers the effective-rate
    /// correction. For Phase 2 (RMS meters) this nominal value is fine.
    public let sampleRate: Double

    private let firstHostTimeAtomic = Atomic<UInt64>(0)
    private let framesDeliveredAtomic = Atomic<UInt64>(0)
    /// Host time of the most recent IOProc callback. Paired with
    /// `framesDelivered` it gives a jitter-free effective rate — both are stamped
    /// on the realtime thread, so the rate measures actual delivery, not when the
    /// consumer happened to ask.
    private let lastHostTimeAtomic = Atomic<UInt64>(0)
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    nonisolated private static let log = Logger(subsystem: "io.kbl.sadi.Sadi", category: "systemaudio")

    public var firstHostTime: UInt64? {
        let raw = firstHostTimeAtomic.load(ordering: .acquiring)
        return raw == 0 ? nil : raw
    }

    /// Total frames the IOProc has pushed into the ring since `start()`. Used
    /// by the consumer side to compute the effective sample rate (SPEC §5.2)
    /// — CoreAudio process taps frequently deliver slightly off-nominal.
    public var framesDelivered: UInt64 {
        framesDeliveredAtomic.load(ordering: .acquiring)
    }

    /// Wall-clock-derived delivered rate: `framesDelivered / secondsSinceFirstHost`,
    /// where both endpoints are host times stamped on the realtime thread (first
    /// and most-recent callback) — so the measurement reflects actual delivery
    /// and doesn't jitter with consumer-thread scheduling. Returns nil until at
    /// least two callbacks have run. SPEC §5.2: re-tune the resampler when this
    /// drifts from nominal over a long session so mic and system stay aligned.
    public func effectiveSampleRate() -> Double? {
        guard let first = firstHostTime else { return nil }
        let last = lastHostTimeAtomic.load(ordering: .acquiring)
        guard last > first else { return nil }
        let elapsedSec = SystemAudioCapture.hostTimeSeconds(from: first, to: last)
        guard elapsedSec > 0 else { return nil }
        let frames = framesDelivered
        guard frames > 0 else { return nil }
        return Double(frames) / elapsedSec
    }

    private nonisolated(unsafe) static var cachedTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func hostTimeSeconds(from start: UInt64, to end: UInt64) -> Double {
        guard end >= start else { return 0 }
        let delta = end - start
        let info = cachedTimebase
        let ns = Double(delta) * Double(info.numer) / Double(info.denom)
        return ns / 1_000_000_000
    }

    public init() throws {
        let format = try SystemAudioCapture.buildTapAndAggregate(into: &tapID, aggregate: &aggregateID)
        self.sampleRate = format.mSampleRate
        // ~5 s of source-rate audio (~1 MB). See MicCapture.init for the
        // sizing rationale — long ASR + embedding stalls would otherwise
        // overflow a 1-second ring during normal operation.
        let cap = SystemAudioCapture.nextPowerOfTwo(Int(format.mSampleRate.rounded(.up)) * 5)
        self.ring = SPSCRingBuffer(capacity: cap)
    }

    deinit {
        // Best-effort teardown if the user forgot stop().
        if isRunning, let proc = ioProcID {
            _ = AudioDeviceStop(aggregateID, proc)
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        if aggregateID != 0 { _ = AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != 0 { _ = AudioHardwareDestroyProcessTap(tapID) }
    }

    /// Create the process tap (tap-all, mono mixdown, private) and the private
    /// aggregate device wrapping it. Writes the new object ids into `tap` /
    /// `aggregate` and returns the tap's stream format. Shared by `init` and the
    /// device-change `restart()`.
    private static func buildTapAndAggregate(
        into tap: inout AudioObjectID, aggregate: inout AudioObjectID
    ) throws -> AudioStreamBasicDescription {
        // 1. Tap: every system output process, mono mixdown, private.
        let desc = CATapDescription()
        desc.name = "Sadi System Tap"
        desc.processes = []
        desc.isExclusive = true       // tap every process *except* the empty list = tap all
        desc.isMixdown = true
        desc.isMono = true
        desc.isPrivate = true
        desc.muteBehavior = .unmuted  // leave output audible while tapping

        var newTap: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let s1 = AudioHardwareCreateProcessTap(desc, &newTap)
        guard s1 == noErr, newTap != kAudioObjectUnknown else {
            throw Error.tapCreationFailed(s1)
        }

        // 2. Read tap UID + stream format (with the Sequoia object-not-ready retry).
        let tapUID: CFString
        let format: AudioStreamBasicDescription
        do {
            tapUID = try readString(newTap, kAudioTapPropertyUID)
            format = try readFormat(newTap)
        } catch {
            AudioHardwareDestroyProcessTap(newTap)
            throw error
        }

        // 3. Aggregate device wrapping just our tap, with drift comp on.
        let aggregateUID = UUID().uuidString
        let aggregateDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Sadi System Aggregate",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: tapUID,
                    kAudioSubTapDriftCompensationKey as String: true,
                ],
            ],
            kAudioAggregateDeviceTapAutoStartKey as String: true,
        ]
        var newAggregate: AudioObjectID = 0
        let s2 = AudioHardwareCreateAggregateDevice(aggregateDict as CFDictionary, &newAggregate)
        guard s2 == noErr, newAggregate != 0 else {
            AudioHardwareDestroyProcessTap(newTap)
            throw Error.aggregateDeviceCreationFailed(s2)
        }

        tap = newTap
        aggregate = newAggregate
        return format
    }

    public func start() throws {
        guard !isRunning else { return }
        try installAndStartIOProc()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        if let proc = ioProcID {
            _ = AudioDeviceStop(aggregateID, proc)
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
    }

    /// Create the IOProc on the aggregate and start it. Resets the timing
    /// counters so the effective-rate measurement anchors cleanly.
    private func installAndStartIOProc() throws {
        firstHostTimeAtomic.store(0, ordering: .releasing)
        framesDeliveredAtomic.store(0, ordering: .releasing)
        lastHostTimeAtomic.store(0, ordering: .releasing)

        var proc: AudioDeviceIOProcID?
        // Weak self: CoreAudio retains the IOProc block for the lifetime of
        // the installed handle (only freed by AudioDeviceDestroyIOProcID).
        // A strong capture would form a permanent cycle and make `deinit`
        // unreachable. The `guard let self` upgrade pins self for the
        // duration of one callback so the atomics and ring access are safe.
        let s1 = AudioDeviceCreateIOProcIDWithBlock(
            &proc, aggregateID, nil
        ) { [weak self] _, inInputData, inInputTime, _, _ in
            // Realtime CoreAudio thread: ring.push only.
            guard let self else { return }
            let listPtr = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData)
            )
            guard listPtr.count > 0 else { return }
            let buf = listPtr[0]
            guard let mData = buf.mData, buf.mDataByteSize > 0 else { return }
            let frames = Int(buf.mDataByteSize) / MemoryLayout<Float>.stride
            let ptr = mData.assumingMemoryBound(to: Float.self)
            _ = ring.push(data: UnsafeBufferPointer(start: ptr, count: frames))

            let hostTime = inInputTime.pointee.mHostTime
            _ = firstHostTimeAtomic.compareExchange(
                expected: 0,
                desired: hostTime,
                ordering: .acquiringAndReleasing
            )
            lastHostTimeAtomic.store(hostTime, ordering: .releasing)
            // SPEC §5.2: bump delivered-frame counter so the consumer side
            // can compute the effective sample rate without touching the
            // realtime thread for any locks/allocations.
            framesDeliveredAtomic.add(UInt64(frames), ordering: .relaxed)
        }
        guard s1 == noErr, let proc else { throw Error.ioProcCreationFailed(s1) }
        self.ioProcID = proc

        let s2 = AudioDeviceStart(aggregateID, proc)
        guard s2 == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
            self.ioProcID = nil
            throw Error.startFailed(s2)
        }
    }

    // MARK: - Property helpers

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        precondition(n > 0)
        var v = 1
        while v < n { v <<= 1 }
        return v
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> CFString {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { raw in
                AudioObjectGetPropertyData(object, &addr, 0, nil, &size, raw)
            }
        }
        guard status == noErr, let unwrapped = value?.takeRetainedValue() else {
            throw Error.tapUIDUnavailable(status)
        }
        return unwrapped
    }

    private static func readFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var format = AudioStreamBasicDescription()
        // Sequoia 15.x race: AudioHardwareCreateProcessTap can return a valid
        // tapID whose object isn't resolvable for a few tens of ms, yielding
        // kAudioHardwareBadObjectError. Retry briefly before giving up.
        var status: OSStatus = noErr
        for _ in 0..<10 {
            status = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format)
            if status == noErr { return format }
            if status != kAudioHardwareBadObjectError { break }
            usleep(50_000)  // 50 ms
        }
        throw Error.tapFormatUnavailable(status)
    }
}
