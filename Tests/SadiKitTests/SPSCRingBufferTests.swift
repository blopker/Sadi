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
}
