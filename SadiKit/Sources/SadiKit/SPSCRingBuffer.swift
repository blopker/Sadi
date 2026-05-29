import Foundation
import Synchronization

/// A strictly wait-free, single-producer / single-consumer ring buffer.
/// Safe for use inside real-time AVAudioEngine capture callbacks.
///
/// `@unchecked Sendable` because the unsafe pointer hides the synchronisation
/// from the compiler: the contract is that exactly one thread calls `push` and
/// exactly one (possibly different) thread calls `pull`. Violating that —
/// e.g. two producers — is undefined behaviour.
public final class SPSCRingBuffer: @unchecked Sendable {
    private let buffer: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let mask: Int

    // Swift 6 native atomics bypass ARC and heap locks
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    /// Capacity must be a power of 2 (e.g., 8192, 16384).
    public init(capacity: Int) {
        precondition((capacity & (capacity - 1)) == 0, "Capacity must be power of 2")
        self.capacity = capacity
        self.mask = capacity &- 1

        // Manual memory allocation to guarantee zero runtime interference
        self.buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0.0)
    }

    deinit {
        // `.initialize(repeating:)` in init makes the memory initialized; the
        // API contract is to deinitialize before deallocating. For `Float` this
        // is a no-op, but it's the right shape and future-proofs a type swap.
        buffer.deinitialize().deallocate()
    }

    /// Called strictly by the AVAudioEngine real-time thread (Wait-free)
    public func push(data: UnsafeBufferPointer<Float>) -> Bool {
        let n = data.count

        let currentWrite = writeIndex.load(ordering: .relaxed)
        let currentRead = readIndex.load(ordering: .acquiring)

        // Wrap-safe calculation of available space (Two's Complement)
        let availableSpace = capacity &- (currentWrite &- currentRead)
        guard availableSpace >= n else { return false } // Overrun
        guard n > 0, let src = data.baseAddress else { return true }

        // Wrap-aware bulk copy: at most two `update(from:count:)` calls,
        // which lower to memcpy for Float. Replaces a scalar masked-index
        // loop the optimizer wasn't reliably vectorizing — material on the
        // realtime audio thread.
        let dst = buffer.baseAddress!
        let writeOffset = currentWrite & mask
        let untilWrap = capacity - writeOffset
        if n <= untilWrap {
            dst.advanced(by: writeOffset).update(from: src, count: n)
        } else {
            dst.advanced(by: writeOffset).update(from: src, count: untilWrap)
            dst.update(from: src.advanced(by: untilWrap), count: n - untilWrap)
        }

        // Wrap-safe index advancement
        writeIndex.store(currentWrite &+ n, ordering: .releasing)
        return true
    }

    /// Called strictly by the GCD/Task processing thread (Wait-free)
    public func pull(count: Int, into destination: UnsafeMutableBufferPointer<Float>) -> Bool {
        precondition(destination.count >= count, "destination buffer is smaller than requested count")

        let currentWrite = writeIndex.load(ordering: .acquiring)
        let currentRead = readIndex.load(ordering: .relaxed)

        // Wrap-safe calculation of available data (Two's Complement)
        let availableData = currentWrite &- currentRead
        guard availableData >= count else { return false } // Underrun
        guard count > 0, let dst = destination.baseAddress else { return true }

        // Wrap-aware bulk copy — symmetric with `push`.
        let src = buffer.baseAddress!
        let readOffset = currentRead & mask
        let untilWrap = capacity - readOffset
        if count <= untilWrap {
            dst.update(from: src.advanced(by: readOffset), count: count)
        } else {
            dst.update(from: src.advanced(by: readOffset), count: untilWrap)
            dst.advanced(by: untilWrap).update(from: src, count: count - untilWrap)
        }

        // Wrap-safe index advancement
        readIndex.store(currentRead &+ count, ordering: .releasing)
        return true
    }
}
