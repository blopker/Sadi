import Foundation
import Testing

@testable import SadiKit

/// EchoCanceller alignment/buffering tests. Engine-dependent suppression
/// tests only run when the LocalVQE dylib + model are present on this
/// machine (they're a build product / download, not repo fixtures).
@Suite("EchoCanceller")
struct EchoCancellerTests {
    static let rate = Int(Resampler.targetRate)

    static func loadEngine() -> LocalVQE? {
        let candidates = [
            URL(fileURLWithPath: #filePath)  // …/SadiKit/Tests/SadiKitTests/x.swift
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()  // repo root
                .appending(path: "Vendor/localvqe"),
        ]
        for dir in candidates {
            let lib = dir.appending(path: "liblocalvqe.dylib")
            let model = dir.appending(path: "localvqe-v1.4-aec-200K-f32.gguf")
            if FileManager.default.fileExists(atPath: lib.path(percentEncoded: false)),
                FileManager.default.fileExists(atPath: model.path(percentEncoded: false)) {
                return try? LocalVQE(libraryURL: lib, modelURL: model)
            }
        }
        return nil
    }

    /// Deterministic pseudo-speech: sum of enveloped sinusoids.
    static func signal(seconds: Double, seed: Double) -> [Float] {
        let n = Int(seconds * Double(rate))
        return (0..<n).map { i in
            let t = Double(i) / Double(rate)
            let env = 0.5 + 0.5 * sin(2 * .pi * 1.3 * t + seed)
            return Float(env * (0.3 * sin(2 * .pi * (220 + 40 * seed) * t) + 0.2 * sin(2 * .pi * 517 * t + seed)))
        }
    }

    static func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    @Test("suppresses a delayed far-end copy, passes local speech")
    func suppression() async throws {
        guard let engine = Self.loadEngine() else { return }  // dylib not built here
        let canceller = EchoCanceller(engine: engine)

        let anchor = Date(timeIntervalSince1970: 1_000_000)
        let farEnd = Self.signal(seconds: 8, seed: 1.0)
        // Mic = far-end echo delayed 80 ms at -6 dB. (Echo-only content, so
        // post-AEC energy should collapse.)
        let delay = Int(0.080 * Double(Self.rate))
        var mic = [Float](repeating: 0, count: farEnd.count)
        for i in delay..<mic.count { mic[i] = 0.5 * farEnd[i - delay] }

        // Interleave feeds in 100 ms chunks, mic anchored 0.5 s after the
        // reference stream (like the real bring-up order, system first here).
        let chunk = Self.rate / 10
        var cleaned: [Float] = []
        let micAnchorOffset = 0.5
        let micLead = Int(micAnchorOffset * Double(Self.rate))
        for start in stride(from: 0, to: farEnd.count, by: chunk) {
            let end = min(start + chunk, farEnd.count)
            await canceller.feedReference(Array(farEnd[start..<end]), anchor: anchor)
            // Mic stream starts 0.5 s later in wall-clock; feed the slice of
            // mic that "exists" by the reference stream's current wall time.
            let micEnd = max(0, end - micLead)
            let micStart = max(0, start - micLead)
            if micEnd > micStart {
                cleaned += await canceller.processMic(
                    Array(mic[micStart..<micEnd]),
                    anchor: anchor.addingTimeInterval(micAnchorOffset))
            }
        }
        cleaned += await canceller.flushMic()

        #expect(cleaned.count == mic.count - micLead)
        // Skip the model's convergence window, then expect deep suppression.
        let settled = cleaned.dropFirst(2 * Self.rate)
        let settledInput = mic[(micLead + 2 * Self.rate)...]
        let inRMS = Self.rms(settledInput[...])
        let outRMS = Self.rms(settled)
        #expect(inRMS > 0.05)
        #expect(outRMS < inRMS * 0.1, "echo not suppressed: in \(inRMS) out \(outRMS)")

        let stats = await canceller.stats()
        #expect(stats.processed > 0)
    }

    @Test("mic-only: passes through with bounded latency, count preserved")
    func micOnlyPassthrough() async throws {
        guard let engine = Self.loadEngine() else { return }
        let canceller = EchoCanceller(engine: engine)
        let anchor = Date()
        let mic = Self.signal(seconds: 5, seed: 2.0)
        var out: [Float] = []
        let chunk = Self.rate / 10
        for start in stride(from: 0, to: mic.count, by: chunk) {
            let end = min(start + chunk, mic.count)
            out += await canceller.processMic(Array(mic[start..<end]), anchor: anchor)
        }
        out += await canceller.flushMic()
        #expect(out.count == mic.count)
        // No reference stream → output must be bit-identical passthrough.
        #expect(out == mic)
    }

    @Test("reference outage mid-stream degrades to passthrough, count preserved")
    func referenceOutage() async throws {
        guard let engine = Self.loadEngine() else { return }
        let canceller = EchoCanceller(engine: engine)
        let anchor = Date()
        let farEnd = Self.signal(seconds: 2, seed: 3.0)
        await canceller.feedReference(farEnd, anchor: anchor)

        // 10 s of mic vs only 2 s of reference: the tail must still come out
        // (zero-filled reference after the wait bound / flush).
        let mic = Self.signal(seconds: 10, seed: 4.0)
        var out: [Float] = []
        let chunk = Self.rate / 4
        for start in stride(from: 0, to: mic.count, by: chunk) {
            let end = min(start + chunk, mic.count)
            out += await canceller.processMic(Array(mic[start..<end]), anchor: anchor)
        }
        out += await canceller.flushMic()
        #expect(out.count == mic.count)
    }
}
