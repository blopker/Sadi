import AVFoundation

/// Captures the default microphone to a file using AVAudioEngine.
///
/// The file is written in the input device's native format; `AudioMixer`
/// and FluidAudio's `AudioConverter` handle resampling later, so we don't
/// need to fix the sample rate here.
final class MicRecorder {

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private(set) var isRecording = false

    /// When true, macOS's voice-processing audio unit is enabled on the mic
    /// input. It applies acoustic echo cancellation (plus automatic gain
    /// control and noise suppression), so the far-end voice bleeding out of
    /// your speakers is largely removed from the mic track — no headphones
    /// needed. The AGC/noise-suppression side effects are fine for
    /// transcription; turn this off if you want unprocessed audio.
    var echoCancellationEnabled = true

    /// Reflects whether AEC actually engaged after the last `start()`.
    /// Some virtual / aggregate input devices don't support it.
    private(set) var echoCancellationActive = false

    /// Requests microphone permission. Returns `true` if granted.
    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Starts capturing the microphone into `outputURL` (a .caf file).
    func start(outputURL: URL) throws {
        let input = engine.inputNode

        // Enable echo cancellation BEFORE reading the format — voice
        // processing changes the input node's output format. If the device
        // doesn't support it, fall back gracefully to plain capture.
        echoCancellationActive = false
        if echoCancellationEnabled {
            do {
                try input.setVoiceProcessingEnabled(true)
                echoCancellationActive = true
            } catch {
                echoCancellationActive = false   // non-fatal: record without AEC
            }
        }

        let format = input.outputFormat(forBus: 0)

        // Guard against a zero/invalid format (can happen if no input device).
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.captureSetupFailed("Microphone reported an invalid audio format.")
        }

        let audioFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        self.file = audioFile

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            // Writes happen on a real-time audio thread; keep this cheap.
            try? self?.file?.write(from: buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops capture and finalizes the file.
    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        isRecording = false
    }
}
