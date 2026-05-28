import AVFoundation
import Foundation

/// Source-rate Float32 mono → 16 kHz Float32 mono converter. Wraps
/// `AVAudioConverter` and reuses internal scratch buffers across calls so the
/// consumer task's per-chunk hot path stays allocation-light.
///
/// Each pipeline (mic, system) has its own resampler.
public final class Resampler {
    public enum Error: Swift.Error {
        case formatCreationFailed
        case converterCreationFailed
        case conversionFailed(NSError?)
    }

    public static let targetRate: Double = 16_000

    private let converter: AVAudioConverter
    private let sourceFormat: AVAudioFormat
    private let targetFormat: AVAudioFormat
    private var inputBuffer: AVAudioPCMBuffer
    private var outputBuffer: AVAudioPCMBuffer
    private let inputCapacity: AVAudioFrameCount
    private let outputCapacity: AVAudioFrameCount

    private final class OneShotFeeder: @unchecked Sendable {
        var consumed = false
    }

    public init(sourceRate: Double, maxInputFrames: Int = 4096) throws {
        guard
            let src = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceRate,
                channels: 1,
                interleaved: false
            ),
            let dst = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Resampler.targetRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw Error.formatCreationFailed
        }
        guard let conv = AVAudioConverter(from: src, to: dst) else {
            throw Error.converterCreationFailed
        }
        self.converter = conv
        self.sourceFormat = src
        self.targetFormat = dst
        self.inputCapacity = AVAudioFrameCount(maxInputFrames)
        // 16 kHz / sourceRate ratio of output frames per input frame, plus
        // headroom for the converter's internal latency.
        let ratio = Resampler.targetRate / sourceRate
        self.outputCapacity = AVAudioFrameCount(Double(maxInputFrames) * ratio + 256)
        guard
            let inb = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: inputCapacity),
            let outb = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: outputCapacity)
        else {
            throw Error.converterCreationFailed
        }
        self.inputBuffer = inb
        self.outputBuffer = outb
    }

    /// Resample one chunk. Returns a freshly-allocated `[Float]` of 16 kHz
    /// samples so the caller can hand it off to async actors freely.
    public func resample(_ samples: UnsafeBufferPointer<Float>) throws -> [Float] {
        guard let base = samples.baseAddress, samples.count > 0 else { return [] }
        guard AVAudioFrameCount(samples.count) <= inputCapacity else {
            // Bigger than scratch — split and recurse. Caller normally feeds
            // chunks within the configured cap.
            let mid = samples.count / 2
            let first = UnsafeBufferPointer(start: base, count: mid)
            let second = UnsafeBufferPointer(start: base + mid, count: samples.count - mid)
            return try resample(first) + resample(second)
        }

        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        let dst = inputBuffer.floatChannelData![0]
        dst.update(from: base, count: samples.count)

        // Class-wrap the one-shot flag: AVAudioConverter's input block is
        // marked @Sendable so a local `var` flag trips the strict-concurrency
        // diagnostic, even though the block is invoked synchronously inside
        // `convert(to:error:)`.
        let feeder = OneShotFeeder()
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { [inputBuffer] _, status in
            if feeder.consumed {
                status.pointee = .noDataNow
                return nil
            }
            feeder.consumed = true
            status.pointee = .haveData
            return inputBuffer
        }

        switch status {
        case .haveData, .inputRanDry:
            let n = Int(outputBuffer.frameLength)
            guard n > 0 else { return [] }
            let out = outputBuffer.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: out, count: n))
        case .endOfStream:
            return []
        case .error:
            throw Error.conversionFailed(error)
        @unknown default:
            throw Error.conversionFailed(error)
        }
    }
}
