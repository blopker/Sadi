# Sadi — Pipeline Specification

A fully on-device macOS meeting transcriber, designed to be rebuilt from scratch against this document. Targets macOS 26+, Apple Silicon, sandboxed.

---

## 1. Problem Statement

Transcribe a video call (or in-person meeting) end-to-end on a Mac, fully offline, with accurate attribution of *who* said *what*. Optimize for the local user's note-taking workflow: the user already knows what they said; what matters is correctly capturing the other participants and identifying them across calls.

The hard part is acoustic bleed: when the local user is on speakers (not headphones), the far-end audio comes out of the speakers and back into the microphone, causing the same words to be transcribed twice — once correctly from the system audio, once incorrectly attributed to the user from the mic. Solving this *without* damaging downstream ASR is the central architectural challenge.

This problem has been solved many times. Real-time VoIP comms use sophisticated nonlinear AEC (WebRTC AEC3). ASR front-ends on smart devices use linear-only AEC. Meeting transcription tools — including the polished, shipping reference app in this exact category (OpenOats) — do **not** do real AEC at all. They sidestep it via per-source capture, source-tagged transcription, and post-ASR text-level cleanup. This spec follows the in-category pattern.

---

## 2. Goals & Non-Goals

### Goals
- **Fully on-device transcription.** No audio leaves the machine. Models run locally on Apple Neural Engine (ANE).
- **Per-source capture and transcription.** Mic and system audio are treated as independent streams from capture through to ASR; never mixed before transcription.
- **Live (streaming) transcripts** during the recording, not just after.
- **Two use cases, one pipeline.** A call (mic + system) and an in-person meeting (mic only) are handled by the same pipeline with self-detected mode.
- **Persistent speaker identity.** A voiceprint book that grows over time: once the user names a speaker, they're recognized in future recordings.
- **Sandboxed app.** Minimal entitlements, no Screen Recording permission required.
- **Robust to the common failure modes we know about** (multi-channel mics, sandbox quirks, sample-rate drift, bleed during far-end speech, similar-sounding local and far-end voices).

### Non-Goals
- No real-time acoustic echo cancellation (FDAF / NLMS / WebRTC AEC). Validated against the in-category leader; not necessary at this scope.
- No recovery of *quiet local speech that overlaps loud far-end speech* ("yeah/right" backchannels mid-far-end-turn). Explicitly acceptable to lose, per the primary use case.
- No cloud ASR backends. Local-only.
- No meeting platform integrations (Zoom SDK, Meet bot, Teams bot). Local capture only.
- No multi-language UI in v1 (English ASR via Parakeet TDT v2).

---

## 3. Use Cases

### 3.1 Primary: Video Call
The user joins a Meet/Zoom/Teams/etc. call, optionally on **speakers** (not headphones). Far-end audio plays through the Mac's output and bleeds into the mic. Multiple far-end participants may speak. The user mostly listens; speaks in mostly-turn-taking fashion; occasionally interjects briefly. The user wants:
- Every utterance from the far-end captured correctly.
- Each far-end speaker distinguished from the others (and named, if previously enrolled).
- Their own contributions tagged as "You", with rough timing.
- Lost short overlapping backchannels are acceptable.

### 3.2 Secondary: In-Person Meeting (Mic Only)
The user records a room with multiple people present via the Mac's mic only. No system audio. The pipeline should recognize this mode automatically and:
- Diarize the mic into distinct local speakers.
- Apply persistent identity (already-enrolled people get their names).
- Not gate or drop anything as "bleed" — there's no far-end to bleed in.

### 3.3 Non-Cases
- Music or non-speech system audio while the user talks — out of scope. The user accepts that music playing through the system may produce gibberish transcription on the system track; they can ignore that track.
- Multi-language calls in a single recording — out of scope for v1.

---

## 4. Architecture Overview

```
                  ┌─────────────────────┐         ┌──────────────────────┐
                  │  MicCapture          │         │  SystemAudioCapture   │
                  │  AVAudioEngine       │         │  CoreAudio process    │
                  │  channel-0 mono      │         │  tap → aggregate dev  │
                  └──────────┬───────────┘         └───────────┬───────────┘
                             │ host-time-tagged                 │ host-time-tagged
                             │ Float32 mono PCM                 │ Float32 mono PCM
                             ▼                                  ▼
                     ┌──────────────────────────────────────────────────┐
                     │  StreamSession (per-recording orchestrator)       │
                     │  - holds two AudioStream pipelines (mic + system) │
                     │  - merges Utterances into a unified timeline      │
                     └──────────────────────────────────────────────────┘
                             │                                  │
              ┌──────────────┴─────────────┐    ┌───────────────┴──────────────┐
              │  AudioStream (mic)         │    │  AudioStream (system)        │
              │  - ring buffer             │    │  - ring buffer + effective-  │
              │  - Silero VAD              │    │    rate correction           │
              │  - per-segment ASR         │    │  - Silero VAD                │
              │  - file writer (mono CAF)  │    │  - per-segment ASR           │
              └──────────────┬─────────────┘    │  - LS-EEND diarizer (live)   │
                             │                  │  - file writer (mono CAF)    │
                             │                  └───────────────┬──────────────┘
                             │ Utterance{mic, ...}              │ Utterance{system, ...}
                             └───────────────┬──────────────────┘
                                             ▼
                                ┌─────────────────────────────┐
                                │  EchoFilter (post-ASR)       │
                                │  - temporal-overlap gate     │
                                │  - text Jaccard match        │
                                │  - embedding cosine match    │
                                │  - energy backstop           │
                                └──────────────┬───────────────┘
                                               ▼
                                ┌─────────────────────────────┐
                                │  SpeakerResolver             │
                                │  - per-recording cluster ids │
                                │  - voiceprint book lookup    │
                                │  - emit final Speaker label  │
                                └──────────────┬───────────────┘
                                               ▼
                                ┌─────────────────────────────┐
                                │  TranscriptStore (live)      │
                                │  - append-only utterance log │
                                │  - publishes to UI           │
                                │  - persists JSON on each     │
                                │    finalized utterance       │
                                └─────────────────────────────┘
```

Every box is its own actor or task. Buffers flow through `AsyncStream`; finalized utterances flow through an actor-owned channel. The UI subscribes to `TranscriptStore` and renders live.

---

## 5. Capture Layer

### 5.1 Microphone Capture (`MicCapture`)

- **Framework:** `AVAudioEngine` with an input-node tap on bus 0, buffer size 4096.
- **No voice processing.** `setVoiceProcessingEnabled` is never called. The pipeline expects raw, unprocessed mic audio throughout. See §12 and Appendix A for the reasoning.
- **Multi-channel handling:** Read the input node's current format. If `channelCount > 1`, take **channel 0 only** (per-buffer copy of `floatChannelData[0]`). MacBook built-in mics expose 3-channel arrays where channels 1+ are directional/cancellation beams; averaging them destroys the voice signal. Same rationale as OpenOats.
- **Sample rate:** Query the **hardware** nominal rate of the resolved input device (`AudioObjectGetPropertyData` with `kAudioDevicePropertyNominalSampleRate`) and prefer it over the `inputNode.outputFormat` rate when they disagree — this catches the post-device-switch lag where AVAudioEngine still reports the old rate for a beat.
- **Output:** an `AsyncStream<TimedPCMBuffer>` where each element is:
  - `samples: [Float]` — mono float32 at the source sample rate
  - `hostTime: UInt64` — Mach absolute time of the buffer's first sample
  - `sampleRate: Double` — the rate above
- **No file write here.** A separate consumer writes a mono CAF for the recording archive. This keeps capture latency-free and lets the streaming consumer get every buffer.

### 5.2 System Audio Capture (`SystemAudioCapture`)

- **Framework:** **CoreAudio process tap**, not ScreenCaptureKit. Specifically:
  - `AudioHardwareCreateProcessTap` with `kAudioSubTapMixdown` (or its mono variant) to get a single-channel mix of system output.
  - `AudioHardwareCreateAggregateDevice` wrapping the tap, with `kAudioSubTapDriftCompensationKey: true` so the OS handles clock drift between the tap and the output device.
  - `AudioDeviceCreateIOProcIDWithBlock` to install an IO callback that fires on a CoreAudio realtime thread.
- **Why this and not SCStream:**
  - No Screen Recording permission prompt (huge UX win for the in-person mic-only case and just generally).
  - No video pipeline to babysit (SCStream needs a throwaway video output to satisfy its config requirements).
  - Smaller permission surface; cleaner audio path.
- **Mono mixdown:** done by CoreAudio in the tap config; receive a single channel of Float32 PCM.
- **Effective sample-rate correction:** CoreAudio taps report a nominal rate that does not always match what they actually deliver. Track `(firstHostTime, totalFramesWritten)` continuously; expose `effectiveSampleRate = totalFrames / wallSeconds`. Resampling consumers use this, not the declared rate. This is the OpenOats trick; it prevents subtle long-term drift between mic and system.
- **Output:** same `AsyncStream<TimedPCMBuffer>` shape as `MicCapture`.

### 5.3 Synchronization

Both streams are tagged with `mach_absolute_time` host time at buffer level. Downstream consumers align by host time when they need to relate the two streams (specifically: the `EchoFilter` checks overlap of utterance time windows). No sample-accurate alignment is required because we never feed both streams into a single signal-processing stage.

---

## 6. Streaming Pipeline

### 6.1 Buffer Plumbing

Each track runs an `AudioStream` actor that owns:
- An in-memory **ring buffer** sized for the maximum VAD lookahead (e.g., 30 seconds at 16 kHz mono Float32 = 1.9 MB). Capture consumers push, VAD consumer pops.
- A **resampler** (`AVAudioConverter`) that lazily resamples each pushed buffer from the source rate to **16 kHz mono** (what FluidAudio's ASR and diarizer expect). For the system track, the resampler uses the *effective* sample rate, not the declared one.
- A **file writer** that writes the source-rate samples (pre-resample) to a mono CAF in the recording's directory. The CAF is the archive; recompute later if needed.

Backpressure: ring buffers are bounded; if a consumer can't keep up, drop the oldest unread audio and log a warning. Live transcription is best-effort — we prefer dropping audio over stalling capture.

### 6.2 VAD & Segmentation

- **Model:** **Silero VAD** via FluidAudio.
- **Operation:** the VAD consumer pulls 16 kHz samples from the ring buffer in fixed-size frames (e.g., 30 ms), runs Silero, and applies a state machine: `idle → speaking (on threshold crossing + min-speech-ms) → idle (on threshold-drop + min-silence-ms)`. On each `speaking → idle` transition, emit a `SpeechSegment { samples, startHostTime, endHostTime }`.
- **Buffering:** keep a small lookahead (~200 ms) so the segment boundary doesn't clip the first phoneme.
- **Output:** an `AsyncStream<SpeechSegment>`.

### 6.3 Per-Track ASR

- **Model:** FluidAudio's **Parakeet TDT v2** (English). One `AsrManager` instance per track; both share the model weights but each has its own `TdtDecoderState`.
- **Operation:** the ASR consumer pulls `SpeechSegment`s, allocates a fresh decoder state per segment (each segment is one independent utterance), runs `asr.transcribe(slice, decoderState: &state)`, and emits an `Utterance { source, startHostTime, endHostTime, text, embeddingHint?, confidence? }`.
- **Empty-text guard:** drop segments whose ASR text is empty after whitespace trim.
- **Minimum-slice guard:** skip segments shorter than ~200 ms of audio. (Avoids the CoreML `E5RT: zero shape error` we saw on degenerate slices.)
- **Output:** an `AsyncStream<Utterance>` per track.

### 6.4 Diarization (System Track Only)

- **Model:** FluidAudio's **LS-EEND** streaming diarizer.
- **Operation:** runs in parallel with system-track ASR, consuming the same 16 kHz samples (sharing the ring buffer or a forked one). Maintains a per-recording speaker timeline: `[ (speakerIdx, startHostTime, endHostTime, centroidEmbedding) ]`. As new audio comes in, the timeline is updated (segments may be revised retroactively as more context arrives, which is fine — speaker labels are not finalized until the recording stops).
- **Tagging utterances:** when a system-track `Utterance` is emitted, query the diarization timeline for the **dominant speaker** in `[utterance.startHostTime, utterance.endHostTime]` (by total overlap). Tag the utterance with the local cluster id and centroid embedding.
- **No diarization on the mic** in call mode (mic = single local speaker, "You"). In **mic-only mode** (see §7), run the same LS-EEND on the mic to split in-room speakers.

---

## 7. Echo Filter (Post-ASR)

The echo filter consumes `Utterance`s from both tracks and decides which to keep. It runs on the merged stream, ordered by `startHostTime`.

### 7.1 Mode Detection

Recompute on every utterance: a recording is in **call mode** if the system track has emitted any utterance so far. Otherwise it's in **mic-only mode**.

- **Mic-only mode:** keep every mic utterance unmodified. Speaker labels come from mic-track diarization. The echo filter is a no-op.
- **Call mode:** apply the filter to every mic utterance. System utterances are always kept (they're the source of truth for the far-end).

### 7.2 Filter Logic (Call Mode)

For each mic utterance `m`:

1. **Temporal-overlap precondition.** Find all system utterances that overlap `m.timeRange` by more than 100 ms. If none, **KEEP** `m` — there's no far-end speech at this time, so it can't be bleed regardless of how similar the voices are. *This is the precondition we got wrong the first time around; it's load-bearing.*

2. **Otherwise, evaluate three bleed signals against the set of overlapping system utterances `S`:**

   **(a) Text-similarity match (cheap, no embeddings):**
   - Normalize: lowercase, strip punctuation, collapse whitespace.
   - For each `s ∈ S`, compute `jaccard(tokens(m.text), tokens(s.text))` and `containsEitherDirection(m.text, s.text)`.
   - **Signal fires** if any `s` has Jaccard ≥ 0.6 or substring containment (and `m.text` is at least 4 tokens or 20 chars — short utterances are too noisy for text similarity).

   **(b) Fingerprint match (level-independent, robust to ASR errors):**
   - Far-end voiceprint set: the centroid embeddings of all system-track speaker clusters seen so far.
   - For `m`'s embedding (from the mic-track diarizer's clustering, which always runs to produce centroids), compute the minimum cosine distance to any far-end voiceprint.
   - **Signal fires** if `minDistance < 0.65` (FluidAudio's same-speaker threshold).

   **(c) Energy backstop (degraded-bleed catcher):**
   - Compute raw RMS (pre-normalization) of `m`'s window in both tracks.
   - **Signal fires** if `systemRaw > 3 × micRaw`.

3. **Decision:** `m` is **bleed** if **any** of (a), (b), (c) fired. Else **KEEP**.

The three signals catch different failure modes and complement each other: text-match handles cleanly-ASR'd bleed; fingerprint handles bleed that ASR garbled differently; energy handles bleed too degraded for the fingerprint to match. The temporal precondition prevents all three from being wrongly applied to genuine local speech during far-end silence — which is the single most important property of the filter.

### 7.3 Labeling Survivors

- Mic survivors in call mode → `.you`.
- System utterances → the diarizer's per-recording speaker label, resolved to a persistent name if matched (§8).
- In mic-only mode, mic-track speakers → the diarizer's local labels, resolved.

---

## 8. Speaker Identity

### 8.1 Ephemeral (Per-Recording)

Each per-recording speaker (from LS-EEND clustering on either track) is identified by `(recordingId, localClusterIdx)` and carries a centroid embedding (Float32 vector, dimension defined by the diarizer's embedding model). The `Speaker` type:

```swift
enum Speaker: Hashable, Codable {
    case you                       // mic in call mode
    case them                      // system, single far-end speaker
    case remote(Int)               // system, multi-speaker (1-indexed)
    case localSpeaker(Int)         // mic-only mode, multi-speaker (1-indexed)
    case named(String, UUID)       // persistent identity from voiceprint book
}
```

`.them` is used when the system track only contains one cluster; `.remote(N)` for multi-speaker far-end. Same for mic in mic-only mode.

### 8.2 Persistent (Voiceprint Book)

A separate persistent store of named voiceprints:

```swift
struct Voiceprint: Codable {
    let id: UUID
    var name: String
    var embedding: [Float]    // centroid; updated as samples accumulate
    var sampleCount: Int      // for incremental averaging
    var createdAt: Date
    var updatedAt: Date
}
```

Stored as JSON at `<container>/Application Support/Sadi/Voiceprints/book.json`, plus a small SQLite or a daily backup snapshot for safety.

**Resolution flow** at the end of each recording (or live, debounced):

1. For each diarized cluster (in either track), compute its centroid embedding.
2. For each enrolled `Voiceprint`, compute `cosineDistance(cluster.centroid, vp.embedding)`.
3. If the minimum distance is below `matchThreshold` (start at 0.55; tunable, tighter than the 0.65 echo-filter threshold to bias against false matches), label as `.named(vp.name, vp.id)`.
4. Otherwise, keep the ephemeral label (`.them` / `.remote(N)` / `.localSpeaker(N)`).

**Enrollment / correction flow** (UI-driven):

- The transcript view shows each speaker label. The user can click any label and either pick an existing name from the voiceprint book or type a new name.
- Renaming an ephemeral label to a new name creates a new `Voiceprint` from that cluster's centroid.
- Renaming to an existing name **updates** that voiceprint's embedding via running average: `vp.embedding = (vp.embedding * vp.sampleCount + cluster.centroid) / (vp.sampleCount + 1)`, `vp.sampleCount += 1`.
- All utterances of that cluster in the current recording are relabeled in-place.
- (Future) "Wrong person" correction: click a `.named` utterance and pick a different name → the voiceprint update is reversed for that cluster's contribution.

---

## 9. Data Model

```swift
/// One spoken contribution after the echo filter, ready to display.
struct Utterance: Identifiable, Hashable, Codable {
    let id: UUID
    let source: Source              // .mic | .system
    var speaker: Speaker
    let text: String
    let startHostTime: UInt64       // nanoseconds since boot
    let endHostTime: UInt64
    let embedding: [Float]?         // present when source had diarization
    let asrConfidence: Float?       // if model exposes it
}

enum Source: String, Codable { case mic, system }

struct Recording: Identifiable, Codable {
    let id: UUID
    var title: String
    let createdAt: Date
    var endedAt: Date?
    var micFileURL: URL              // mono CAF, source sample rate
    var systemFileURL: URL?          // mono CAF, may be absent in mic-only
    var utterances: [Utterance]      // append-only; persisted incrementally
    var speakerClusters: [SpeakerCluster]  // per-recording clusters with centroids
}

struct SpeakerCluster: Codable {
    let id: UUID
    let source: Source
    let localIdx: Int                // 1-indexed within the source track
    var centroid: [Float]
    var resolvedName: String?        // if matched to a voiceprint
    var resolvedVoiceprintID: UUID?
}
```

`UInt64` host time is stored raw; convert to wall-clock at display time using the recording's `createdAt` and a host-time anchor captured at recording start.

---

## 10. Persistence

Recordings live in `<container>/Application Support/Sadi/Recordings/<UUID>/`:

```
<UUID>/
  recording.json     ← Recording struct, rewritten on every utterance finalize
  mic.caf            ← source-rate mono mic capture
  system.caf         ← source-rate mono system capture (absent in mic-only)
  marker.json        ← present only while recording is in progress (crash recovery)
```

Voiceprints live in `<container>/Application Support/Sadi/Voiceprints/book.json`. On each enrollment / update, write to `book.json.tmp` and atomically rename.

Crash recovery: on launch, scan for any `marker.json` files; if found, the recording is incomplete. Offer the user "recover" (try to re-transcribe from the saved CAFs) or "delete." We don't autoplay the raw recording silently — surface it.

---

## 11. UI Surface

Minimal, focused; not a UI spec, but the contract the pipeline supports:

- **Recordings list** — sidebar of past recordings, newest first. Click to view transcript.
- **Live recording view** — shown while recording. Transcript appends in real time; each finalized `Utterance` slides in. A small "X" indicator on dropped (echo-filtered) utterances behind a debug toggle. Mode (call / mic-only) shown in the header.
- **Transcript view** — past recording. Each utterance has its speaker label, time, and text. Click the label to rename / assign to a voiceprint.
- **Settings** — ASR model selection (Parakeet v2 only in v1, but the surface is there), voiceprint book management.

The UI subscribes to `TranscriptStore`'s `AsyncStream<TranscriptEvent>`; `TranscriptEvent` is `.appended(Utterance)`, `.updated(Utterance)`, `.dropped(Utterance, reason)`, `.speakerRelabeled(clusterID, Speaker)`.

---

## 12. Dependencies & Entitlements

### Swift packages
- **FluidAudio** (pinned to a known-good version; bump deliberately): provides Parakeet TDT v2 (ASR), LS-EEND (streaming diarizer), Silero VAD, and the embedding model used for voiceprints.
- (Stretch) **Sparkle** for auto-update if/when shipped.

No DSP libraries. No WebRTC. No custom CoreML model bundling beyond what FluidAudio handles.

### Entitlements (`Sadi.entitlements`)
- `com.apple.security.app-sandbox` = true
- `com.apple.security.device.audio-input` = true
- `com.apple.security.network.client` = true (for FluidAudio one-time model download)
- `com.apple.security.files.user-selected.read-only` = true (for any "import audio file" feature)

### Info.plist (via build settings)
- `NSMicrophoneUsageDescription` — required, or mic permission request crashes.
- **No** `NSScreenCaptureUsageDescription` — we don't use ScreenCaptureKit.

### Build settings
- `MACOSX_DEPLOYMENT_TARGET = 26.0` (we're macOS 26+ only).
- `ENABLE_APP_SANDBOX = YES`, `ENABLE_HARDENED_RUNTIME = YES`.
- `SWIFT_VERSION = 6`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

### What we are deliberately *not* using
- ScreenCaptureKit (replaced by CoreAudio process tap).
- AVAudioEngine voice processing (`setVoiceProcessingEnabled`). See Appendix A — it cannot solve our bleed problem (can't cancel another app's audio), and under the sandbox it actively degrades capture.
- WebRTC, Speex, RNNoise, or any AEC/NLP library.
- Any cloud ASR / cloud anything.

---

## 13. Implementation Phases

Each phase ends at a testable milestone. Don't move on until the milestone passes.

### Phase 1 — Foundation
Project scaffold (SwiftPM-based Xcode project), sandbox + entitlements, Sadi.entitlements file, build settings as above. App launches, requests mic permission, shows an empty window. **Milestone:** clean build, mic permission granted, empty UI.

### Phase 2 — Capture
`MicCapture` and `SystemAudioCapture` per §5, each producing an `AsyncStream<TimedPCMBuffer>`. A debug view shows live RMS meters for both. **Milestone:** start/stop captures both tracks; meters move when you speak / when audio plays; no Screen Recording prompt ever appears.

### Phase 3 — File Archive
A consumer per track writes the capture stream to a mono CAF in a recording directory, with the source-rate format. **Milestone:** stop a recording; play back both CAFs in Finder; mic.caf is your voice, system.caf is what was playing.

### Phase 4 — VAD + Per-Track ASR
Add the ring buffer, Silero VAD, and per-track ASR per §6.2 and §6.3. No diarization yet; no echo filter; tag mic utterances as `.you` and system as `.them` unconditionally. **Milestone:** live transcript appears in the UI for both tracks during recording.

### Phase 5 — Diarization on System
Add LS-EEND on the system track per §6.4. System utterances are tagged with `.them` (one cluster) or `.remote(N)` (multi-cluster). **Milestone:** in a recording with two distinct far-end voices, the transcript shows two distinct remote speakers.

### Phase 6 — Echo Filter (Call Mode)
Implement §7 with all three bleed signals and the temporal precondition. Run against the harness (`scratch/pipetest`) on known recordings to verify. **Milestone:** on a recording with mic bleed of far-end audio, the bleed utterances are filtered out; on a recording where local user speaks during far-end silence, those utterances survive — even if the voices are similar.

### Phase 7 — Mic-Only Mode
Detect mode per §7.1; in mic-only mode, run LS-EEND on the mic too; bypass the echo filter. **Milestone:** in an in-person recording (no system audio), multiple distinct local speakers appear correctly diarized.

### Phase 8 — Persistent Speaker ID
Implement §8.2: voiceprint book on disk, resolution flow at recording finalize (or live debounced), UI affordance to name speakers. **Milestone:** name "Alice" in one recording; in a new recording with Alice, her utterances show up as "Alice" automatically.

### Phase 9 — Effective Sample-Rate Correction
Wire up the wall-clock-derived `effectiveSampleRate` in `SystemAudioCapture` and use it in the resampler. **Milestone:** record a long (>30 min) session; verify by spot-check that system utterances stay in time with mic utterances throughout. (This is a robustness fix, not a feature, but it's important for long meetings.)

### Phase 10 — Crash Recovery & Polish
`marker.json` flow, recovery UI, debug toggles for dropped utterances, settings screen, voiceprint book management UI.

---

## 14. Risks & Open Questions

1. **CoreAudio process tap availability and exact API shape.** macOS 14.4+ is required; we target 26+, so available, but the invocation pattern (tapping all-system-output vs a specific process) needs verifying at implementation time. There are surprisingly few public examples; reference: WWDC23 Session 10235.

2. **LS-EEND streaming semantics.** "Streaming diarizer" still has retroactive cluster revision as more context arrives; the per-utterance speaker label may need to be re-emitted later. The data model (`Utterance.speaker` mutable; `.speakerRelabeled` events) supports this, but the UI needs to handle in-place updates gracefully.

3. **Voiceprint stability across hardware/contexts.** Embeddings shift when the mic, room, or speaker volume change. The running-average update helps but isn't bulletproof; the system needs a clear "rename / correct" affordance and shouldn't pretend to be more confident than it is. Start with a conservative threshold (0.55) and let the user retrain by correcting.

4. **FluidAudio's embedding model dimension and stability.** Document the dimension (used in voiceprint storage); commit to a model version with bump procedure. If FluidAudio changes embedding spaces in a future version, existing voiceprints become unmatchable — need a migration path or model-version tag on each voiceprint.

5. **ASR latency vs liveness.** Parakeet per-segment is fast (~100s of ms per a few-second segment on ANE), but two concurrent ASR streams + diarization is real load. Live transcript needs to keep up; if it doesn't, degrade to batching system-track ASR while keeping mic live (the user cares more about seeing their own thread of the conversation in real time — actually, no, they care more about the far-end; reverse this if needed).

6. **CoreML `E5RT zero shape error`.** Saw this once on a degenerate slice during prepare(). Mitigation: enforce a minimum slice length in the ASR consumer (~200 ms). If it persists, file/investigate against FluidAudio.

7. **Memory on long meetings.** Ring buffers are bounded; utterances accumulate. A 4-hour recording at, say, 1 utterance/5 seconds × 1 KB per utterance = ~3 MB. Embeddings (256-dim Float32 = 1 KB each) double that. Comfortable; no streaming-to-disk needed for in-memory utterances during a session.

8. **The mode-detection edge case.** If the user is in a call but the far-end happens to be silent for the first N seconds, we'd start in "mic-only mode" and produce mic-track diarization. As soon as the system speaks, we'd switch to call mode and start gating. Need to: (a) suppress the spurious mic-side diarization in retrospect, OR (b) start always-on diarization for both tracks and only differ at the labeling step. Option (b) is cleaner; do that.

---

## 15. Out of Scope

- Real-time AEC (FDAF, NLMS, WebRTC). Not used by in-category leaders; doesn't fit our priorities.
- Cloud anything.
- Live captions overlay on top of the call app.
- Meeting summarization, action items, knowledge-base integration (OpenOats does these; we don't, in v1).
- Multi-language support (English Parakeet TDT only).
- iOS / iPad version.
- Calendar integration / meeting auto-detect.
- Automatic launching / always-on capture.

---

## Appendix A — Lessons Carried Forward From v0

This spec encodes specific failures from the previous iteration:

- **VPIO is not used at all.** Under the App Sandbox it requires a `com.apple.security.temporary-exception.mach-lookup.global-name` entitlement for `com.apple.audioanalyticsd` and produces continuous downlink-DSP faults if its render side isn't driven. Attempting to drive it (silent source on the output) created I/O overload that degraded mic capture. And its acoustic echo cancellation can only cancel audio our own engine renders — never another app's playback — so it cannot solve the bleed problem regardless. Also: on some hardware it exposes the mic as a multi-channel "discrete" format that silently downmixes to zero. The mono channel-0 capture below is the defensive choice independent of voice processing.
- **Mono channel-0 capture, not averaging.** MacBook built-in mic arrays expose multi-channel formats (front beam + directional / cancellation beams); averaging across channels causes destructive interference and effectively silences the voice. Always take channel 0.
- **Diarizing a *mix* of mic + system collapses both speakers into one cluster** when one is much louder. Per-track ASR is not negotiable.
- **Per-track normalization + raw energy comparison for bleed gating** is necessary (normalization is needed so ASR sees the quiet mic; raw comparison is needed so the energy gate isn't fooled by the boost).
- **A fingerprint-only bleed gate drops the local speaker when local and far-end voices are similar.** The temporal-overlap precondition is the load-bearing fix.
- **`let id = UUID()` in a `Codable` struct silently breaks decoding.** Use `var id = UUID()`.
- **The `MemberImportVisibility` upcoming feature requires explicit `import Combine` for `@Published` / `ObservableObject`.** Not optional.

---
