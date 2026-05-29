import Testing
@testable import SadiKit

@Suite("SPSCRingBuffer")
struct SPSCRingBufferTests {
    @Test("round-trip preserves samples in order")
    func roundTrip() {
        let ring = SPSCRingBuffer(capacity: 16)
        let input: [Float] = [1, 2, 3, 4, 5]
        let pushed = input.withUnsafeBufferPointer { ring.push(data: $0) }
        #expect(pushed)

        var output = [Float](repeating: 0, count: input.count)
        let pulled = output.withUnsafeMutableBufferPointer {
            ring.pull(count: input.count, into: $0)
        }
        #expect(pulled)
        #expect(output == input)
    }

    @Test("push returns false when ring is full")
    func overrun() {
        let ring = SPSCRingBuffer(capacity: 4)
        let first: [Float] = [1, 2, 3, 4]
        let second: [Float] = [5]
        #expect(first.withUnsafeBufferPointer { ring.push(data: $0) })
        #expect(!second.withUnsafeBufferPointer { ring.push(data: $0) })
    }

    @Test("pull returns false when not enough samples available")
    func underrun() {
        let ring = SPSCRingBuffer(capacity: 8)
        let input: [Float] = [1, 2]
        _ = input.withUnsafeBufferPointer { ring.push(data: $0) }

        var output = [Float](repeating: 0, count: 4)
        let pulled = output.withUnsafeMutableBufferPointer {
            ring.pull(count: 4, into: $0)
        }
        #expect(!pulled)
    }

    @Test("indices wrap correctly past capacity")
    func wrapAround() {
        let ring = SPSCRingBuffer(capacity: 4)
        var scratch = [Float](repeating: 0, count: 3)

        for round in 0..<5 {
            let base = Float(round) * 10
            let input: [Float] = [base, base + 1, base + 2]
            #expect(input.withUnsafeBufferPointer { ring.push(data: $0) })
            #expect(scratch.withUnsafeMutableBufferPointer { ring.pull(count: 3, into: $0) })
            #expect(scratch == input)
        }
    }

    @Test("single push and pull span the wrap boundary correctly")
    func singleCallSpansWrap() {
        // Capacity 8; advance write+read to offset 6, then push 5 samples in
        // one call so the bulk-copy fast path splits 2 before the wrap and
        // 3 after. Exercises the two-memcpy branch of push() and pull().
        let ring = SPSCRingBuffer(capacity: 8)
        var warmupOut = [Float](repeating: 0, count: 6)
        let warmup: [Float] = [1, 2, 3, 4, 5, 6]
        #expect(warmup.withUnsafeBufferPointer { ring.push(data: $0) })
        #expect(warmupOut.withUnsafeMutableBufferPointer { ring.pull(count: 6, into: $0) })

        // Now writeOffset and readOffset both at 6. Push 5 samples that
        // wrap: positions 6, 7, 0, 1, 2.
        let crossing: [Float] = [10, 20, 30, 40, 50]
        #expect(crossing.withUnsafeBufferPointer { ring.push(data: $0) })

        var out = [Float](repeating: 0, count: 5)
        #expect(out.withUnsafeMutableBufferPointer { ring.pull(count: 5, into: $0) })
        #expect(out == crossing)
    }
}
