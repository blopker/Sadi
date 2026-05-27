import AVFoundation
import OSLog
import ScreenCaptureKit

/// Captures system audio (everything playing through the Mac's output, e.g.
/// the far end of a Google Meet call) using ScreenCaptureKit and writes it
/// to an .m4a file.
///
/// NOTE: This is the most environment-sensitive file in the project.
/// ScreenCaptureKit's audio behaviour has shifted across macOS releases.
/// If audio never arrives, the usual culprits are:
///   1. Screen Recording permission not granted (System Settings ›
///      Privacy & Security › Screen Recording — add this app, then relaunch).
///   2. On some macOS versions an audio-only SCStream needs a video output
///      registered as well — this file registers a throwaway video output
///      for that reason.
@available(macOS 13.0, *)
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    private let log = Logger(subsystem: "Sadi", category: "SystemAudio")

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false

    private let sampleQueue = DispatchQueue(label: "Sadi.SystemAudio.samples")

    /// Starts system-audio capture into `outputURL` (a .m4a file).
    func start(outputURL: URL) async throws {
        // 1. Pick a display to attach the filter to. We only want its audio.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // 2. Configure the stream: audio on, current app excluded, tiny video.
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true  // don't record our own UI sounds
        config.sampleRate = 48_000
        config.channelCount = 2
        // SCStream still wants a video pipeline; keep it as small/slow as possible.
        config.width = 100
        config.height = 100
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // ~1 fps
        config.queueDepth = 6

        // 3. Set up the file writer for AAC audio.
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)

        // Crash safety: write a *fragmented* MP4. AVAssetWriter flushes a
        // self-contained, playable fragment every few seconds, so if the app
        // crashes before finishWriting() runs, the recording stays playable
        // up to the last completed fragment — instead of being an unreadable
        // stub with no moov atom.
        writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else {
            throw RecorderError.captureSetupFailed("Writer rejected the audio input.")
        }
        writer.add(audioInput)
        self.writer = writer
        self.audioInput = audioInput

        // 4. Build the stream and register outputs (audio + throwaway video).
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        self.stream = stream

        try await stream.startCapture()
        log.info("System audio capture started.")
    }

    /// Stops capture and finalizes the file.
    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        audioInput?.markAsFinished()
        if let writer, writer.status == .writing {
            await writer.finishWriting()
        }
        stream = nil
        writer = nil
        audioInput = nil
        sessionStarted = false
        log.info("System audio capture stopped.")
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        // We only persist audio; screen frames are discarded immediately.
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer),
            let writer, let audioInput
        else { return }

        if !sessionStarted {
            guard writer.startWriting() else {
                log.error("Writer failed to start: \(String(describing: writer.error))")
                return
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }

        if audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Stream stopped with error: \(error.localizedDescription)")
    }
}
