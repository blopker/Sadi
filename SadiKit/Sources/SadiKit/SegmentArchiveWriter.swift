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
    /// Nanoseconds per source-rate frame, pre-computed at init. Used to
    /// build a PTS in a nanosecond-precision CMTime so that a fractional
    /// `sampleRate` (e.g., a Phase 9 effective rate of 48000.15 Hz) does
    /// not get rounded out by `CMTimeScale`'s Int32 conversion — that
    /// truncation would otherwise accumulate into MP4 duration drift over
    /// a long meeting.
    private let nanosPerFrame: Double
    private static let nanosecondTimescale: CMTimeScale = 1_000_000_000
    /// Source frames *presented* to the writer — appended or dropped. PTS
    /// derives from this count, so a dropped chunk leaves a real gap in the
    /// MP4 timeline instead of silently compressing it: playback positions
    /// stay wall-clock aligned with the transcript even across drops.
    private var sourceFrames: Int64 = 0
    /// Frames dropped because the encoder/disk fell behind
    /// (`isReadyForMoreMediaData` false) or the writer latched `.failed`.
    /// Read by the archive loop's stall failsafe; same-thread as `append`.
    public private(set) var droppedFrames: Int64 = 0
    private var didStart = false
    /// Set once an append fails. `AVAssetWriter` latches to `.failed` on the
    /// first encode error, so every later append would fail too; short-circuit
    /// to surface the error exactly once instead of spamming it per buffer.
    private var didFail = false

    public init(url: URL, sampleRate: Double) throws {
        self.sampleRate = sampleRate
        self.nanosPerFrame = 1_000_000_000.0 / sampleRate

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

        // Output AAC encoder settings. 64 kbps mono per SPEC §10.6 — but only
        // at "normal" rates. AAC can't encode arbitrary input rates, and 64
        // kbps is an *invalid* bitrate at low sample rates: a Bluetooth /
        // AirPods mic in HFP mode reports 16 kHz (or 8 kHz), where the encoder
        // rejects 64 kbps with -12651 ("encoding parameters not supported") on
        // the first append and then latches `.failed` for the whole segment.
        // So snap the encode rate to a supported AAC rate (AVAssetWriter
        // resamples the source PCM for us — the PCM `format` below stays at the
        // true `sampleRate`, and PTS are wall-clock so timing is unaffected) and
        // scale the bitrate into the valid window for that rate. Mapping verified
        // across 8 k–48 k.
        let encodeRate = SegmentArchiveWriter.snappedAACRate(for: sampleRate)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: encodeRate,
            AVEncoderBitRateKey: SegmentArchiveWriter.aacBitRate(forOutputRate: encodeRate),
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
        let nFrames = samples.count
        if didFail {
            // Writer is latched `.failed`; account the loss so the caller's
            // stall failsafe sees it instead of audio vanishing silently.
            droppedFrames += Int64(nFrames)
            sourceFrames += Int64(nFrames)
            return
        }

        if !didStart {
            guard writer.startWriting() else {
                throw Error.startWritingFailed(writer.error as NSError?)
            }
            writer.startSession(atSourceTime: .zero)
            didStart = true
        }

        // Backpressure: encoder typically keeps up. If it falls behind we
        // drop — but still advance `sourceFrames`, so the loss shows up as a
        // PTS gap (timeline preserved) and in `droppedFrames` (failsafe).
        guard input.isReadyForMoreMediaData else {
            droppedFrames += Int64(nFrames)
            sourceFrames += Int64(nFrames)
            return
        }
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

        // Nanosecond-precision PTS: `value` stays in Double so fractional
        // sample rates round only at the ns floor (sub-microsecond), which
        // can't accumulate over any practical session length.
        let ptsValue = Int64((Double(sourceFrames) * nanosPerFrame).rounded())
        let pts = CMTime(value: ptsValue, timescale: SegmentArchiveWriter.nanosecondTimescale)
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
            didFail = true
            droppedFrames += Int64(nFrames)
            sourceFrames += Int64(nFrames)
            throw Error.appendFailed(writer.error as NSError?)
        }
        sourceFrames &+= Int64(nFrames)
    }

    /// Advance the timeline without data — used when the *capture* side lost
    /// frames (ring overflow), so subsequent appends keep wall-clock-aligned
    /// PTS. The skipped span plays back as a gap of the right duration.
    public func skip(frames: Int) {
        sourceFrames += Int64(frames)
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

    // MARK: - AAC parameter selection

    /// Sample rates the AAC encoder accepts. A device may report something off
    /// this list (exotic hardware, or a rate the driver rounds oddly); feeding
    /// such a rate to `AVAssetWriterInput` throws an *uncatchable* NSException,
    /// so we snap to the nearest supported rate and let AVAssetWriter resample.
    private static let supportedAACRates: [Double] = [
        8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000,
    ]

    static func snappedAACRate(for rate: Double) -> Double {
        supportedAACRates.min(by: { abs($0 - rate) < abs($1 - rate) }) ?? 48_000
    }

    /// Largest "safe" mono AAC bitrate for a given encode rate. The encoder
    /// rejects bitrates above a rate-dependent ceiling (e.g. 64 kbps is invalid
    /// at ≤16 kHz). These bands sit comfortably inside the valid window at every
    /// supported rate while keeping the original 64 kbps at normal rates.
    static func aacBitRate(forOutputRate rate: Double) -> Int {
        switch rate {
        case ..<12_001: return 16_000  // 8–12 kHz (HFP narrowband)
        case ..<16_001: return 32_000  // 16 kHz (HFP wideband / AirPods mic)
        case ..<24_001: return 48_000  // 22.05–24 kHz
        default: return 64_000         // 32 kHz and up
        }
    }
}
