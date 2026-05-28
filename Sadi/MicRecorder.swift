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
    /// input (automatic gain control + noise suppression).
    ///
    /// Off by default: under the App Sandbox the voice processor can't reach
    /// its analytics daemon, so it logs continuous downlink faults, and driving
    /// the downlink to silence those faults overloads the I/O thread and
    /// degrades capture (diarization then extracts zero speaker embeddings).
    /// Its echo cancellation also only cancels audio *this* engine renders, so
    /// it can't remove another app's speaker output (e.g. a Meet call) from the
    /// mic regardless — diarization clusters that bleed as one speaker instead.
    /// Flip to true only if you can live with the log noise.
    var echoCancellationEnabled = false

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

        // Persist a single mono channel instead of the input node's native
        // layout. With voice processing enabled, some devices expose the
        // processed mic duplicated across several "discrete" channels (e.g. 9).
        // A discrete multi-channel file has no standard layout, so it collapses
        // to near-silence when AudioMixer downmixes it to stereo AAC — which
        // surfaces downstream as "No speech detected." Channel 0 is the
        // processed near-end mic, so we keep just that.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false)
        else {
            throw RecorderError.captureSetupFailed("Couldn't create a mono recording format.")
        }

        let audioFile = try AVAudioFile(forWriting: outputURL, settings: monoFormat.settings)
        self.file = audioFile

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            // Writes happen on a real-time audio thread; keep this cheap.
            guard let mono = MicRecorder.monoBuffer(fromChannel: 0, of: buffer, as: monoFormat)
            else { return }
            try? self?.file?.write(from: mono)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Copies one channel of `buffer` into a fresh mono buffer in `format`.
    /// Returns nil for interleaved/non-float sources; input-node tap buffers
    /// are deinterleaved float, so this path is the expected one.
    private static func monoBuffer(
        fromChannel channel: Int,
        of buffer: AVAudioPCMBuffer,
        as format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData,
            channel < Int(buffer.format.channelCount)
        else { return nil }

        let frames = buffer.frameLength
        guard frames > 0,
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
            let dst = out.floatChannelData
        else { return nil }

        out.frameLength = frames
        memcpy(dst[0], src[channel], Int(frames) * MemoryLayout<Float>.size)
        return out
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
