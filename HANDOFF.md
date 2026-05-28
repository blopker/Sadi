# Session Handoff — read this first

Notes for the next session. SPEC.md is the design; this is operational context.

## Where things are

| Path | What it is |
|---|---|
| `Sadi/SPEC.md` | The v2 design document. Authoritative. |
| `Sadi/Sadi.xcodeproj` + `Sadi/Sadi/*.swift` | **v0 app.** Swift 5. Working per-track + temporal-overlap + fingerprint+energy echo gate. Reference implementation; source of Appendix A lessons. Don't delete until v2 reaches Phase 6 or so. |
| `Sadi/Sadi/SPSCRingBuffer.swift` | **v2 building block.** Swift 6, requires `import Synchronization` (so won't build inside the v0 Swift-5 target — physically present, not in pbxproj). Type-checks clean standalone. |
| `Sadi/scratch/pipetest/` | Standalone SwiftPM package that runs the v0 `Transcriber` (symlinked, not copied) against real FluidAudio on existing recordings in the app container. Used to validate the bleed-gate fix empirically without manual recording. Pattern is reusable for v2 — symlink the new `Transcriber` once it exists. |
| `~/Library/Application Support/FluidAudio` → symlink into the v0 sandboxed container | Lets the non-sandboxed harness find cached models. Remove on clean v2 rebuild; the v2 sandboxed app will repopulate its own container. |
| `~/code/OpenOats` | Reference codebase — shipping meeting-transcription app, same category as Sadi. Survey informed several decisions in SPEC (CoreAudio process tap, effective sample-rate correction, channel-0 extraction wording). Their persistence sprawl was deliberately *not* adopted. |

## Decisions already made — don't relitigate without new evidence

The spec calls these out, but listing here because they cost real conversation cycles and shouldn't be re-examined casually:

- **Real-time AEC** (FDAF / NLMS / WebRTC AEC3 implemented ourselves) — rejected. Not what shipping meeting transcribers do; if ever needed, embed AEC3, don't roll our own.
- **ScreenCaptureKit for system audio** — rejected. Use CoreAudio process tap; no Screen Recording permission needed.
- **AVAudioEngine voice processing (VPIO)** — rejected. See Appendix A.
- **CAF as the archive format** — rejected for fMP4/AAC 64 kbps (~25× smaller, no ASR penalty).
- **`marker.json` for in-progress sessions** — rejected. `session.endedAt == nil` carries the same info.
- **Append-only live JSONL transcript during recording** — rejected. Transcript written once at finalize; crash recovery re-runs the pipeline on durable fMP4s. (Few minutes per hour on ANE — acceptable.)
- **UUID session ids** — rejected for second-resolution local-time strings (`YYYY-MM-DD-HH-MM-SS`).
- **Mixing mic + system into a single archive file** — rejected. The pipeline needs per-track separation.
- **`AsyncStream` at the realtime capture boundary** — rejected. Allocates and takes locks. SPSC ring instead (§5.0).

## Suggested project type for v2

SwiftPM-based: `Package.swift` at root with the library code, plus a thin Xcode app target that depends on the library. Matches OpenOats's structure. Lets us `swift test` from the command line and keeps the validation harness pattern (`scratch/pipetest/`) trivially compatible.

## Two implementation unknowns to verify early in v2 (Phase 2)

1. **CoreAudio process tap exact invocation.** macOS 14.4+ API; sparsely documented in public examples. Reference: WWDC23 Session 10235. Specifically need: tapping the *default output device* mixed mono, with `kAudioSubTapDriftCompensationKey` on the aggregate device. If this doesn't work as expected on a real machine, the §5.2 plan needs adjusting — it's the biggest specification risk.
2. **LS-EEND streaming semantics.** FluidAudio's `LSEENDDiarizer` advertises streaming but may still retroactively revise cluster assignments. The `Utterance.speaker` mutability + `.speakerRelabeled` event already accommodates this; need to verify the actual revision pattern doesn't drop or duplicate utterances.

## Open TODOs to plan around

- **Test AAC at 32 kbps vs 64 kbps** on a real recording (Phase 8+). If WER delta is in the noise, drop to 32 and halve storage. See SPEC §10.6.
- **Measure ASR throughput on this specific Mac.** Estimates in §13 risk #5 are educated guesses (~1–3 min per hour on ANE). The harness can measure it once Phase 4 is wired.
- **Verify embedding-model identifier exposure.** §8.2 requires a `modelVersion: String` on each `Voiceprint`. Need to find where FluidAudio exposes the loaded model's identifier (or compute a hash of the model file as fallback).

## Things that exist on disk to clean up at start of v2

- The `~/Library/Application Support/FluidAudio` symlink (created for the harness).
- The two `mic-002.caf` family of leftover recordings in the v0 sandbox container, if any. The v2 build will use a new bundle id path or, if same, will see the v0 recordings and crash on `recording.json` parsing — best to clear them.

That's it. SPEC.md is the durable artifact; this file goes away once v2 is meaningfully underway.
