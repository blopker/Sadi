import AVFoundation
import Testing

@testable import SadiKit

@Suite("SegmentArchiveWriter")
struct SegmentArchiveWriterTests {
    /// Capture losses must be repaid as *encoded silence* — a bare PTS gap is
    /// flattened by the AAC encode (verified empirically: a 12 s skip read
    /// back as a seamless file), which would silently compress the timeline
    /// and desync playback from transcript timestamps.
    @Test("lost frames backfill as silence, preserving wall-clock duration")
    func lossBackfillsAsSilence() async throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "sadi-archive-test-\(UUID().uuidString).mp4", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: url) }

        let rate = 16_000.0
        let writer = try SegmentArchiveWriter(url: url, sampleRate: rate)

        // 1 s tone, 1 s capture loss, 1 s tone => 3 s wall-clock.
        let tone = (0..<Int(rate)).map { Float(sin(2.0 * .pi * 440.0 * Double($0) / rate)) * 0.5 }
        try tone.withUnsafeBufferPointer { try writer.append($0) }
        writer.insertSilence(frames: Int(rate))
        try tone.withUnsafeBufferPointer { try writer.append($0) }
        await writer.finalize()

        let file = try AVAudioFile(forReading: url)
        #expect(file.processingFormat.sampleRate == rate)
        // AVAudioFile trims encoder priming via the edit list, so the decoded
        // length should be the exact wall-clock span. Allow one AAC packet
        // (1024 frames) of slack against codec flush behavior.
        #expect(abs(file.length - 3 * Int64(rate)) <= 1024)

        // The middle second must be silence and the outer seconds tone —
        // i.e. the loss landed *between* the chunks, not compressed away.
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]

        func rms(second: Int) -> Float {
            let lo = second * Int(rate)
            let hi = min(lo + Int(rate), Int(buffer.frameLength))
            var sum: Float = 0
            for i in lo..<hi { sum += samples[i] * samples[i] }
            return (sum / Float(hi - lo)).squareRoot()
        }
        // Sine at 0.5 amplitude has RMS ~0.35; AAC-encoded "silence" decodes
        // to near-zero but not exactly zero.
        #expect(rms(second: 0) > 0.2)
        #expect(rms(second: 1) < 0.02)
        #expect(rms(second: 2) > 0.2)
    }

    /// A trailing loss (recording stalls, then stops) must still be encoded:
    /// finalize settles the remaining silence debt.
    @Test("silence debt outstanding at finalize is settled")
    func trailingDebtSettledAtFinalize() async throws {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "sadi-archive-test-\(UUID().uuidString).mp4", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: url) }

        let rate = 16_000.0
        let writer = try SegmentArchiveWriter(url: url, sampleRate: rate)
        let tone = (0..<Int(rate)).map { Float(sin(2.0 * .pi * 440.0 * Double($0) / rate)) * 0.5 }
        try tone.withUnsafeBufferPointer { try writer.append($0) }
        writer.insertSilence(frames: Int(rate))
        await writer.finalize()

        let file = try AVAudioFile(forReading: url)
        #expect(abs(file.length - 2 * Int64(rate)) <= 1024)
    }
}
