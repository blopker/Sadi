import AVFoundation
import FluidAudio
import Foundation
import SadiKit

/// Drives the *live* `StreamProcessor` from recorded session files instead of
/// live capture. The only thing that differs from `CaptureController` is the
/// audio source: a session's `.mp4` track decoded to native-rate mono and fed
/// in small chunks, with no archive writer (we read recordings, never write
/// them) and no RMS meter. Everything downstream — resampling, streaming VAD,
/// diarization, ASR, labeling, echo filtering, voiceprint resolution — is the
/// exact same code path the GUI runs.
enum FileReplayDriver {
    /// One decoded track ready to feed.
    struct Track {
        let source: Source
        let samples: [Float]
        let sampleRate: Double
    }

    /// Decode an audio file to mono Float32 at its native sample rate. The
    /// `StreamProcessor`'s own `Resampler` then takes it to 16 kHz, exactly as
    /// it does for live capture — so replay exercises the real resample path.
    static func decodeMono(_ url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            return ([], format.sampleRate)
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        guard n > 0, let channels = buffer.floatChannelData else {
            return ([], format.sampleRate)
        }

        var out = [Float](repeating: 0, count: n)
        let channelCount = Int(format.channelCount)
        if channelCount == 1 {
            out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: channels[0], count: n) }
        } else {
            // Downmix to mono (captures are mono, but be robust).
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][i] }
                out[i] = sum / Float(channelCount)
            }
        }
        return (out, format.sampleRate)
    }

    /// Feed the given tracks through fresh `StreamProcessor`s wired to a shared
    /// `TranscriptStore`, interleaved in ~20 ms wall-clock steps so the store
    /// sees a realistic mic/system receive order (its call-mode detection and
    /// `.them`/`.remote(N)` relabel depend on that ordering). Returns when all
    /// audio has been consumed.
    static func feed(
        tracks: [Track],
        vad: VadManager,
        asr: AppleAsr,
        diarizerModel: LSEENDModel,
        embeddingDiarizer: DiarizerManager,
        store: TranscriptStore,
        startWallClock: Date
    ) async throws {
        // Build one StreamProcessor per track — same construction the live
        // CaptureController uses, minus the capture source and archive writer.
        let processors = try tracks.map { track -> (proc: StreamProcessor, track: Track) in
            let proc = try StreamProcessor(
                source: track.source,
                sourceRate: track.sampleRate,
                vad: vad,
                asr: asr,
                diarizerModel: diarizerModel,
                embeddingDiarizer: embeddingDiarizer,
                store: store,
                startWallClock: startWallClock
            )
            return (proc, track)
        }

        // ~20 ms per step keeps the interleave fine-grained and each per-track
        // chunk comfortably under the resampler's input cap at any sane rate.
        let stepSeconds = 0.02
        let totalSeconds = tracks.map { Double($0.samples.count) / $0.sampleRate }.max() ?? 0
        var elapsed = 0.0
        while elapsed < totalSeconds {
            let nextElapsed = elapsed + stepSeconds
            for (proc, track) in processors {
                let lo = Int(elapsed * track.sampleRate)
                let hi = min(Int(nextElapsed * track.sampleRate), track.samples.count)
                guard hi > lo else { continue }
                await proc.feed(Array(track.samples[lo..<hi]))
            }
            elapsed = nextElapsed
        }

        // Mirror the live pipeline's end-of-stream flush so speech still open
        // at the end of a track isn't dropped.
        for (proc, _) in processors {
            await proc.flush()
        }
    }
}
