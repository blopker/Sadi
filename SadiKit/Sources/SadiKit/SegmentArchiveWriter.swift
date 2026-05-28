import AVFoundation
import CoreMedia
import Foundation

/// Per-segment audio archive writer per SPEC §6.1 + §10.6.
///
/// Wraps `AVAssetWriter` so each call to `append(_:)` feeds source-rate
/// Float32 mono PCM through Apple's hardware AAC encoder into a fragmented
/// MP4 (one moof/mdat fragment every 10 s — a hard crash loses at most that
/// fragment). Output: mono AAC at 64 kbps, container `.mp4`.
public final class SegmentArchiveWriter: @unchecked Sendable {
    public enum Error: Swift.Error {
        case startWritingFailed(NSError?)
        case appendFailed(NSError?)
        case formatDescriptionFailed(OSStatus)
        case blockBufferCreationFailed(OSStatus)
        case sampleBufferCreationFailed(OSStatus)
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription
    private let sampleRate: Double
    private var framesWritten: Int64 = 0
    private var didStart = false

    public init(url: URL, sampleRate: Double) throws {
        self.sampleRate = sampleRate

        // Source PCM format: Float32 mono, packed, native endian. This is the
        // format of buffers we hand to `append(_:)`; AVAssetWriter transcodes
        // to AAC for us.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatOut: CMAudioFormatDescription?
        let fdStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatOut
        )
        guard fdStatus == noErr, let format = formatOut else {
            throw Error.formatDescriptionFailed(fdStatus)
        }
        self.format = format

        // Output AAC encoder settings. 64 kbps mono per SPEC §10.6.
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
            AVEncoderBitRateKey: 64_000,
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true
        self.input = input

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Fragmented MP4: each 10 s chunk is a complete moof+mdat pair, so
        // a file that wasn't cleanly closed is still playable up to its last
        // finalized fragment (§10.5 crash recovery).
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 1)
        guard writer.canAdd(input) else {
            throw Error.startWritingFailed(nil)
        }
        writer.add(input)
        self.writer = writer
    }

    /// Append a chunk of source-rate Float32 mono samples. Safe to call from
    /// the consumer task; blocks briefly during encode (Apple HW AAC is fast).
    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard samples.count > 0, let base = samples.baseAddress else { return }

        if !didStart {
            guard writer.startWriting() else {
                throw Error.startWritingFailed(writer.error as NSError?)
            }
            writer.startSession(atSourceTime: .zero)
            didStart = true
        }

        // Backpressure: encoder typically keeps up. If it falls behind we drop
        // — same best-effort posture as the realtime ring.
        guard input.isReadyForMoreMediaData else { return }

        let nFrames = samples.count
        let dataSize = nFrames * MemoryLayout<Float>.stride

        // Copy into a CMBlockBuffer's own memory so we own the lifetime.
        // CMBlockBufferCreateWithMemoryBlock with a nil memoryBlock allocates
        // the block for us; we then copy into its data via accessDataBytes.
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let block = blockBuffer else {
            throw Error.blockBufferCreationFailed(bbStatus)
        }
        let copyStatus = CMBlockBufferReplaceDataBytes(
            with: UnsafeRawPointer(base),
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: dataSize
        )
        guard copyStatus == kCMBlockBufferNoErr else {
            throw Error.blockBufferCreationFailed(copyStatus)
        }

        let pts = CMTime(value: framesWritten, timescale: CMTimeScale(sampleRate))
        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: nFrames,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr, let sample = sampleBuffer else {
            throw Error.sampleBufferCreationFailed(sbStatus)
        }

        if !input.append(sample) {
            throw Error.appendFailed(writer.error as NSError?)
        }
        framesWritten &+= Int64(nFrames)
    }

    /// Mark input finished and wait for AVAssetWriter to flush the final
    /// fragment and finalize the moov atom. Safe to call once.
    public func finalize() async {
        guard didStart else {
            // Nothing was ever written; nothing to finalize.
            return
        }
        input.markAsFinished()
        await writer.finishWriting()
    }
}
