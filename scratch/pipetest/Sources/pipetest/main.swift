import AVFoundation
import FluidAudio
import Foundation
import SadiKit

// MARK: - CLI

struct CLI {
    let sessionDir: URL
    let cacheDir: URL
}

func parseCLI() throws -> CLI {
    let args = CommandLine.arguments
    var sessionArg: String?
    var cacheArg: String?
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--cache":
            i += 1
            cacheArg = i < args.count ? args[i] : nil
        case "--help", "-h":
            print(usage)
            exit(0)
        default:
            // Positional: session id or full path.
            sessionArg = args[i]
        }
        i += 1
    }

    let home = FileManager.default.homeDirectoryForCurrentUser
    let containerSupport = home
        .appending(path: "Library/Containers/io.kbl.sadi.Sadi/Data/Library/Application Support", directoryHint: .isDirectory)
    let recordingsRoot = containerSupport.appending(path: "Sadi/Recordings", directoryHint: .isDirectory)

    let cache = cacheArg
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? containerSupport.appending(path: "FluidAudio", directoryHint: .isDirectory)

    let session: URL
    if let arg = sessionArg {
        // Allow either a session id ("2026-05-28-10-59-00") or full path.
        let asPath = URL(fileURLWithPath: arg, isDirectory: true)
        if FileManager.default.fileExists(atPath: asPath.path(percentEncoded: false)) {
            session = asPath
        } else {
            session = recordingsRoot.appending(path: arg, directoryHint: .isDirectory)
        }
    } else {
        session = try newestSession(in: recordingsRoot)
    }
    return CLI(sessionDir: session, cacheDir: cache)
}

let usage = """
pipetest — replay a captured session through the v1 transcription pipeline.

USAGE:
  pipetest [SESSION_ID_OR_PATH] [--cache PATH]

Defaults:
  SESSION_ID_OR_PATH  newest session under ~/Library/Containers/io.kbl.sadi.Sadi/Data/Library/Application Support/Sadi/Recordings/
  --cache             ~/Library/Containers/io.kbl.sadi.Sadi/Data/Library/Application Support/FluidAudio
"""

func newestSession(in root: URL) throws -> URL {
    let fm = FileManager.default
    let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
    let sessions = entries
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .filter { $0.lastPathComponent.hasPrefix("2026-") || $0.lastPathComponent.hasPrefix("2027-") }
    guard let newest = sessions.max(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
        struct NoSession: Error {}
        throw NoSession()
    }
    return newest
}

// MARK: - Audio decode

func decodeMonoFloat16kHz(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let inputFormat = file.processingFormat
    guard let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ) else {
        struct FormatFail: Error {}
        throw FormatFail()
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
        struct ConvFail: Error {}
        throw ConvFail()
    }

    let inputCapacity: AVAudioFrameCount = 8192
    guard let inputBuf = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputCapacity) else {
        struct BufFail: Error {}
        throw BufFail()
    }

    let ratio = 16_000 / inputFormat.sampleRate
    let outputCapacity = AVAudioFrameCount(Double(inputCapacity) * ratio + 1024)
    guard let outputBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
        struct BufFail: Error {}
        throw BufFail()
    }

    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(file.length) * ratio + 1024))

    var done = false
    while !done {
        do {
            try file.read(into: inputBuf)
        } catch {
            break
        }
        if inputBuf.frameLength == 0 { done = true }

        let inputProvided = AtomicBool()
        var error: NSError?
        let status = converter.convert(to: outputBuf, error: &error) { _, status in
            if inputProvided.value || inputBuf.frameLength == 0 {
                status.pointee = .noDataNow
                return nil
            }
            inputProvided.value = true
            status.pointee = .haveData
            return inputBuf
        }
        if status == .error { throw error ?? NSError(domain: "convert", code: -1) }

        let n = Int(outputBuf.frameLength)
        if n > 0, let ch = outputBuf.floatChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
        }
        if status == .endOfStream { done = true }
    }
    return samples
}

final class AtomicBool: @unchecked Sendable {
    var value = false
}

// MARK: - Session id timestamp parsing

func parseSessionStart(from id: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    return formatter.date(from: id) ?? Date()
}

// MARK: - Run replay

@main
struct PipeTest {
    static func main() async throws {
        let cli = try parseCLI()
        let sessionID = cli.sessionDir.lastPathComponent
        let sessionStart = parseSessionStart(from: sessionID)

        let micURL = cli.sessionDir.appending(path: "mic-001.mp4", directoryHint: .notDirectory)
        let systemURL = cli.sessionDir.appending(path: "system-001.mp4", directoryHint: .notDirectory)

        print("Session: \(sessionID)")
        print("  dir:    \(cli.sessionDir.path(percentEncoded: false))")
        print("  cache:  \(cli.cacheDir.path(percentEncoded: false))")

        print("\nLoading models from cache…")
        // VadManager expects the FluidAudio root and appends "Models" itself.
        let vad = try await VadManager(modelDirectory: cli.cacheDir)
        // AsrModels.load wants the leaf model directory; under the sandbox
        // container that's <cache>/Models/parakeet-tdt-0.6b-v2.
        let parakeetDir = cli.cacheDir.appending(path: "Models/parakeet-tdt-0.6b-v2", directoryHint: .isDirectory)
        let asrModels = try await AsrModels.load(from: parakeetDir, version: .v2)
        let asr = AsrManager(config: .default, models: asrModels)
        print("Models ready.")

        let mic = try await transcribe(
            url: micURL, source: .mic, vad: vad, asr: asr,
            sessionStart: sessionStart, label: "MIC"
        )
        let system = try await transcribe(
            url: systemURL, source: .system, vad: vad, asr: asr,
            sessionStart: sessionStart, label: "SYS"
        )

        // Merge, sort by start time.
        let merged = (mic + system).sorted { $0.startedAt < $1.startedAt }

        // Offline replay: pass the FULL system list to every mic decision so
        // VAD-timing jitter (mic onset detected a few ms before sys) doesn't
        // accidentally early-exit into the "mic-only mode" branch. The
        // filter's own temporal-overlap precondition still restricts the
        // comparison to actually-overlapping system utterances.
        let filter = EchoFilter()
        let systemAll = system  // full list, not incremental
        var kept: [Utterance] = []
        var dropped: [(Utterance, EchoFilter.DropReason)] = []

        for u in merged {
            if u.source == .system {
                kept.append(u)
                continue
            }
            if systemAll.isEmpty {
                kept.append(u)
                continue
            }
            switch filter.decide(mic: u, system: systemAll) {
            case .keep: kept.append(u)
            case .drop(let r): dropped.append((u, r))
            }
        }

        // Output
        print("\n────── Kept (\(kept.count)) ──────")
        for u in kept { printRow(u, marker: "✓") }

        print("\n────── Dropped (\(dropped.count)) ──────")
        for (u, r) in dropped { printRow(u, marker: "✗", trailer: "[\(r.rawValue)]") }

        let micKept = kept.filter { $0.source == .mic }.count
        let micDropped = dropped.count
        let sysKept = kept.filter { $0.source == .system }.count
        print("""

        ────── Summary ──────
        mic    utterances: \(mic.count) → kept \(micKept), dropped \(micDropped)
        system utterances: \(system.count) → kept \(sysKept)
        """)
    }
}

func transcribe(
    url: URL,
    source: Source,
    vad: VadManager,
    asr: AsrManager,
    sessionStart: Date,
    label: String
) async throws -> [Utterance] {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
        print("  \(label): missing \(url.lastPathComponent), skipping.")
        return []
    }
    print("\n\(label) ► decoding \(url.lastPathComponent)…")
    let samples = try decodeMonoFloat16kHz(url)
    let durationSec = Double(samples.count) / 16_000
    print("  \(label): \(samples.count) samples (\(String(format: "%.1f", durationSec)) s)")

    let segments = try await vad.segmentSpeech(samples)
    print("  \(label): VAD → \(segments.count) speech segments")

    var utterances: [Utterance] = []
    for seg in segments {
        let startIdx = seg.startSample(sampleRate: 16_000)
        let endIdx = seg.endSample(sampleRate: 16_000)
        guard endIdx > startIdx, endIdx <= samples.count else { continue }
        guard endIdx - startIdx >= 4_800 else { continue } // 300 ms min

        let slice = Array(samples[startIdx..<endIdx])
        var state = try TdtDecoderState()
        let result: ASRResult
        do {
            result = try await asr.transcribe(slice, decoderState: &state)
        } catch {
            print("  \(label): ASR failed @\(String(format: "%.1f", seg.startTime))s: \(error)")
            continue
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }

        var sumSq: Float = 0
        for v in slice { sumSq += v * v }
        let rms = slice.isEmpty ? Float(0) : (sumSq / Float(slice.count)).squareRoot()

        let startedAt = sessionStart.addingTimeInterval(seg.startTime)
        let endedAt = sessionStart.addingTimeInterval(seg.endTime)
        utterances.append(Utterance(
            source: source,
            speaker: source == .mic ? .you : .them,
            text: text,
            startedAt: startedAt,
            endedAt: endedAt,
            asrConfidence: result.confidence,
            rms: rms
        ))
    }
    print("  \(label): \(utterances.count) non-empty utterances")
    return utterances
}

func printRow(_ u: Utterance, marker: String, trailer: String = "") {
    let elapsed = u.startedAt.timeIntervalSinceReferenceDate
    let tag = u.source == .mic ? "MIC" : "SYS"
    let trail = trailer.isEmpty ? "" : " \(trailer)"
    print("  \(marker) [\(tag) \(String(format: "rms=%.3f", u.rms ?? 0))]\(trail) \(u.text)")
    _ = elapsed
}
