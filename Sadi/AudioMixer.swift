import AVFoundation

/// Mixes the microphone track and the system-audio track into a single
/// file. Diarization runs on this mixed file: with two callers it sees two
/// voice clusters and labels them, even though the mic track may contain a
/// faint bleed of the far-end voice — they cluster as the same speaker.
struct AudioMixer {

    /// Combines `micURL` and `systemURL` into a single .m4a at `outputURL`.
    func mix(micURL: URL, systemURL: URL, outputURL: URL) async throws {
        let composition = AVMutableComposition()

        for source in [micURL, systemURL] {
            let asset = AVURLAsset(url: source)
            // Skip a source that produced no audio track (e.g. capture failed).
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                continue
            }
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.seconds > 0 else { continue }

            let track = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid)
            try track?.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero)
        }

        guard !composition.tracks(withMediaType: .audio).isEmpty else {
            throw RecorderError.exportFailed
        }

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A) else {
            throw RecorderError.exportFailed
        }
        export.outputURL = outputURL
        export.outputFileType = .m4a

        // exportAsynchronously is deprecated on macOS 15+ but still works and
        // keeps the macOS 14 deployment target. Swap for `export(to:as:)`
        // if you raise the minimum to macOS 15.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously {
                continuation.resume()
            }
        }

        guard export.status == .completed else {
            throw RecorderError.exportFailed
        }
    }
}
