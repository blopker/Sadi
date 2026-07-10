# Sadi — Pipeline Specification

A fully on-device macOS meeting transcriber, designed to be rebuilt from scratch against this document. Targets macOS 26+, Apple Silicon, sandboxed.

> 📎 **§13 carries the current implementation status** for each phase along with the landing commit. Detailed change history lives in `git log`.

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
- No *hand-rolled* acoustic echo cancellation (FDAF / NLMS / WebRTC AEC). Echo is cancelled in-process by a small neural AEC model (LocalVQE v1.4-AEC, §6.2a) with the system-audio stream as the reference; the text-level echo filter (§7) remains as backstop. The OS canceller (VoiceProcessingIO) is deliberately NOT used — see Appendix A.
- No recovery of *quiet local speech that overlaps loud far-end speech* ("yeah/right" backchannels mid-far-end-turn). Explicitly acceptable to lose, per the primary use case.
- No cloud ASR backends. Local-only.
- No meeting platform integrations (Zoom SDK, Meet bot, Teams bot). Local capture only.
- No multi-language UI in v1 (system-locale ASR via Apple SpeechTranscriber, en-US fallback).

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
              │  - file writer (fMP4 AAC)  │    │  - per-segment ASR           │
              └──────────────┬─────────────┘    │  - LS-EEND diarizer (live)   │
                             │                  │  - file writer (fMP4 AAC)    │
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

### 5.0 Realtime-thread discipline

Both capture sources (AVAudioEngine input tap, CoreAudio IOProc) invoke their callbacks on a **fixed-priority realtime thread**. Inside those callbacks the code must not allocate, not take locks, not call Obj-C runtime services that may, and not log. The handoff to the rest of the pipeline is via a **lock-free, wait-free single-producer / single-consumer (SPSC) ring buffer** — one per stream. The callback's only job is to copy its incoming samples into the ring and return.

A reference implementation lives at `Sadi/SPSCRingBuffer.swift`: power-of-two capacity, monotonic indices with mask-on-access, release/acquire memory ordering, `Float` samples, `@unchecked Sendable`. Producer = the realtime thread; consumer = a long-running `Task` on a normal-priority queue. The consumer side is where all resampling, file writing, VAD, ASR, and diarization happen.

Capacity per ring: sized for the maximum tolerated end-to-end consumer latency. The consumer's `await processor.feed(...)` blocks while the per-track actor runs ASR transcribe + WeSpeaker embedding, both of which can spike past a second on a busy machine — so we currently allocate **~5 seconds of source-rate audio** (`nextPowerOfTwo(rate * 5)` ≈ 262144 samples ≈ 1 MB at 48 kHz mono). Two streams → ~2 MB total, lives for the duration of a recording. The 1 s baseline the original spec proposed proved tight under real load; 5 s gives the actor wiggle room without changing steady-state latency (the consumer drains backlogs quickly once unblocked).

### 5.1 Microphone Capture (`MicCapture`)

- **Framework:** a raw **AUHAL input unit** (`kAudioUnitSubType_HALOutput`, input enabled, output disabled). Not `AVAudioEngine` (hidden aggregate devices, graph-rebuild storms on device changes) and not VoiceProcessingIO (see Appendix A — its session ducking and by-design device gain changes degrade live meetings).
- **No voice processing on the unit.** The mic stream leaves capture raw; echo cancellation happens in-process at the 16 kHz pipeline stage (§6.2a), which has zero footprint on other apps' audio.
- **Multi-channel handling:** take **channel 0 only** (deinterleaved render into a pre-allocated buffer list). MacBook built-in mics expose multi-channel arrays where channels 1+ are directional/cancellation beams; averaging them destroys the voice signal.
- **Sample rate:** the client format is fixed at the device's nominal hardware rate read at init (`kAudioDevicePropertyNominalSampleRate`); the AUHAL's converter bridges device-rate changes across device switches.
- **Device follow:** a default-input listener retargets the live unit via `kAudioOutputUnitProperty_CurrentDevice` (debounced ~1 s), refusing Bluetooth inputs (HFP would conflict with the system tap).
- **Input callback work:** render channel 0 → host-time gap fill (silence) → `ring.push(data:)`. Nothing else. The first-buffer host time is recorded once via a separate atomic so the consumer can convert sample offsets to wall-clock dates.
- **No file write here.** The consumer thread pulls samples and writes the archive file (§6.1).

### 5.2 System Audio Capture (`SystemAudioCapture`)

> **Wall-clock lock:** process taps stall when no process is playing audio and deliver stale catch-up bursts after route churn. The IOProc back-fills host-time gaps with silence and drops stale bursts (same scheme as §5.1's mic path), keeping the ring's sample count locked to wall-clock — without this the stream timeline warps by seconds, breaking AEC alignment and utterance timestamps. The effective-rate retune (§ Phase 9) additionally rejects readings >2% off nominal: it exists for sub-percent clock drift, and burst-polluted measurements (a transient 72 kHz reading on a 48 kHz tap was observed) must never rebuild the resampler.

- **Framework:** **CoreAudio process tap**, not ScreenCaptureKit. Specifically:
  - `AudioHardwareCreateProcessTap` with `kAudioSubTapMixdown` (or its mono variant) to get a single-channel mix of system output.
  - `AudioHardwareCreateAggregateDevice` wrapping the tap, with `kAudioSubTapDriftCompensationKey: true` so the OS handles clock drift between the tap and the output device.
  - `AudioDeviceCreateIOProcIDWithBlock` to install an IO callback that fires on a CoreAudio realtime thread.
- **Why this and not SCStream:**
  - No Screen Recording permission prompt (huge UX win for the in-person mic-only case and just generally).
  - No video pipeline to babysit (SCStream needs a throwaway video output to satisfy its config requirements).
  - Smaller permission surface; cleaner audio path.
- **Mono mixdown:** done by CoreAudio in the tap config; receive a single channel of Float32 PCM.
- **IO callback work:** `ring.push(data:)`. Nothing else.
- **Effective sample-rate correction (consumer-side):** CoreAudio taps report a nominal rate that does not always match what they actually deliver. The *consumer thread* tracks `(firstHostTime, totalFramesPushed)` continuously; the resampler uses the computed `effectiveSampleRate = totalFramesPushed / wallSeconds` rather than the declared rate. This is the OpenOats trick; prevents subtle long-term drift between mic and system. None of this math happens on the realtime thread.

### 5.3 Synchronization

Both rings tag their first push with the realtime thread's `mach_absolute_time`. From then on, each pulled sample's host time is `firstHostTime + framesPulled * (1 / effectiveSampleRate) * machTimebase`. The consumer can map any sample → host time → wall-clock `Date` (using a session-start anchor). The `EchoFilter` later compares utterance time windows in wall-clock space.

No sample-accurate alignment is required between mic and system because we never feed both streams into a single signal-processing stage.

---

## 6. Streaming Pipeline

### 6.1 Consumer thread

Each track runs a long-lived consumer `Task` that:
1. Pulls Float samples from the SPSC ring (§5.0) in fixed-size frames (e.g. 512 samples at the source rate, ~10 ms at 48 kHz).
2. **Encodes the samples to mono AAC at 64 kbps and appends them to the segment's archive file as fragmented MP4** — `AVAssetWriter` with `movieFragmentInterval = CMTime(seconds: 10, …)` so each fragment is independently playable on crash. See §10 for the file path and §10.6 for the size / rate tradeoff and the open TODO to evaluate 32 kbps.
3. Feeds the same source-rate samples through an `AVAudioConverter` to produce **16 kHz mono** — the rate FluidAudio's ASR, diarizer, and VAD all expect. The system track uses the *effective* sample rate (§5.2) for this resample, not the declared one.
4. Hands the 16 kHz samples to the VAD/segmentation stage (§6.2).

Encoding (step 2) and resampling (step 3) consume the same source-rate samples and run in parallel — the encoder uses Apple's hardware AAC path, the resampler is CPU. Neither blocks the other.

The ring is the only shared mutable state across the realtime/consumer boundary. Within the consumer everything is plain Swift concurrency.

Backpressure: the ring is bounded. If `ring.push(...)` returns `false` (full) — meaning the consumer is more than ~1 second behind — log it as a structured event and drop the incoming buffer. Live transcription is best-effort; we prefer losing a buffer to stalling the realtime thread.

### 6.2 VAD & Segmentation

- **Model:** **Silero VAD** via FluidAudio.
- **Operation:** the VAD consumer pulls 16 kHz samples from the ring buffer in fixed-size frames (e.g., 30 ms), runs Silero, and applies a state machine: `idle → speaking (on threshold crossing + min-speech-ms) → idle (on threshold-drop + min-silence-ms)`. On each `speaking → idle` transition, emit a `SpeechSegment { samples, startHostTime, endHostTime }`.
- **Buffering:** keep a small lookahead (~200 ms) so the segment boundary doesn't clip the first phoneme.
- **Output:** an `AsyncStream<SpeechSegment>`.

### 6.2a Acoustic Echo Cancellation (`EchoCanceller`, call mode)

- **Model:** LocalVQE **v1.4-AEC** (203 K params, echo-only: passes near-end voice, noise, and room through — keeps WeSpeaker embeddings trustworthy), GGUF via `liblocalvqe.dylib` (GGML, CPU, ~22x realtime). Vendored in `Vendor/localvqe/`; rebuild with `scripts/build-localvqe.sh`.
- **Reference:** the system-audio stream — the same 16 kHz samples the system `StreamProcessor` consumes. Alignment is wall-clock (each stream declares its sample-0 anchor) **plus a measured refinement**: anchors get into the right second, but the AEC needs tens of milliseconds, so the canceller cross-correlates 20 ms RMS envelopes of both streams every ~4 s (±2 s search, confidence- and consistency-gated) and applies the residual offset to future hops. The remaining acoustic delay is absorbed by the model's adaptive-filter front-end. Never trust anchors alone — a 1.6 s real-world anchor error broke AEC entirely before the refiner existed.
- **Placement:** mic path only, post-resample, pre-VAD — VAD, diarizer, ASR, and embeddings all consume *cleaned* audio. The canceller preserves sample count/order, so cleaned-stream indices equal raw-stream indices and all wall-clock math is unchanged. **Archives stay raw** — a rerun re-derives the cleaned mic from the pristine recording (and benefits from future model upgrades).
- **Degradation:** missing model/dylib, mic-only mode, or a stalled reference stream → bounded buffering then raw passthrough. AEC is an enhancement, never a gate; §7's text filter remains the backstop (it eats ASR output from the model's quiet residual, deliberately un-gated because a hard noise gate would eat quiet real speech).
- The offline pipeline (§ finalize/rerun) runs the same stage batch, before diarization, so echo cannot seed phantom mic clusters.

### 6.3 Per-Track ASR

- **Model:** Apple **SpeechTranscriber** (macOS 26 `SpeechAnalyzer`), OS-shipped model, system locale with en-US fallback. One shared stateless `AppleAsr` wrapper; each call builds a fresh transcriber+analyzer session (each segment is one independent utterance). Replaced FluidAudio's Parakeet TDT v2 after a head-to-head showed raw accuracy is a wash and Sadi's value is in the surrounding pipeline (`scratch/speech-compare/ANALYSIS.md`).
- **Operation:** the ASR consumer pulls `SpeechSegment`s, runs `asr.transcribe(slice)` (word-level `audioTimeRange` tokens ride along), and emits an `Utterance { source, startHostTime, endHostTime, text, embeddingHint? }`.
- **Empty-text guard:** drop segments whose ASR text is empty after whitespace trim.
- **Minimum-slice guard:** skip segments shorter than ~200 ms of audio. (Avoids the CoreML `E5RT: zero shape error` we saw on degenerate slices.)
- **Output:** an `AsyncStream<Utterance>` per track.

### 6.4 Diarization

- **Model:** FluidAudio's **LS-EEND** streaming diarizer.
- **Both tracks always diarized.** Mic embeddings are required by the echo filter's fingerprint gate (§7) and by persistent speaker ID (§8), so there's no "skip diarization" mode — whether the recording is a call or mic-only is purely a labeling decision, made downstream.
- **Operation:** runs in parallel with each track's ASR, consuming the same 16 kHz samples the ASR sees. Maintains a per-segment, per-track speaker timeline with cluster centroid embeddings. As more audio arrives, prior assignments may be revised retroactively — a fundamental property of streaming diarization. Labels are not considered final until the session stops.
- **Tagging utterances:** when an `Utterance` is emitted, query its track's diarization timeline for the **dominant speaker** in `[utterance.startedAt, utterance.endedAt]` (by total overlap). Attach the local cluster id and centroid embedding to the utterance.
- **Labeling differences (resolved in §7):**
  - **System track clusters** → `.them` (single cluster) or `.remote(N)` (multi).
  - **Mic track clusters** → `.you` in call mode (mic clusters collapsed); `.localSpeaker(N)` in mic-only mode (mic clusters kept distinct).
  - Either side can be replaced by `.named(...)` via the voiceprint book (§8.2).

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
    var modelVersion: String  // FluidAudio embedding model identifier at enrollment
    var createdAt: Date
    var updatedAt: Date
}
```

`modelVersion` is essential because FluidAudio's embedding model can change between releases. Embeddings produced by different model versions are not comparable. On startup, any voiceprint whose `modelVersion` doesn't match the current model is treated as "needs re-enrollment" — surfaced in the voiceprint management UI, not silently used.

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
/// A meeting / recording event. Identified by its start time at second
/// resolution — sortable lexicographically, human-readable, never collides
/// across calls (we record one session at a time).
struct Session: Codable {
    let id: String                   // "YYYY-MM-DD-HH-MM-SS" (local time, 24-hour)
    var title: String
    let startedAt: Date              // wall-clock start of segment 1
    var endedAt: Date?               // nil while in-progress or paused
    var segments: [Segment]          // 1+ contiguous record-to-pause periods
    var speakerClusters: [SpeakerCluster]  // accumulated across all segments
}

/// One uninterrupted recording period within a session.
/// Pause → finalize current segment, leave session open.
/// Resume → append a new segment.
struct Segment: Codable {
    let index: Int                   // 1-indexed within the session
    let startedAt: Date
    var endedAt: Date?               // nil while this segment is recording
    var micFilename: String          // e.g. "mic-001.mp4", relative to session dir
    var systemFilename: String?      // nil in mic-only mode
}

/// One spoken contribution after the echo filter, ready to display.
struct Utterance: Identifiable, Hashable, Codable {
    let id: UUID
    let source: Source               // .mic | .system
    var speaker: Speaker
    let text: String
    let startedAt: Date              // wall-clock
    let endedAt: Date                // wall-clock
    let embedding: [Float]?          // present when source had diarization
    let asrConfidence: Float?        // if model exposes it
}

enum Source: String, Codable { case mic, system }

struct SpeakerCluster: Codable {
    let id: UUID
    let source: Source
    let localIdx: Int                // 1-indexed within the source track
    var centroid: [Float]
    var resolvedName: String?        // if matched to a voiceprint
    var resolvedVoiceprintID: UUID?
}
```

**On timestamps.** Internally during a segment, audio buffers carry `mach_absolute_time` host time for fast monotonic comparisons. Host time **doesn't survive reboot** and isn't comparable across segments (the audio engine restarts between them), so it's converted to a wall-clock `Date` at utterance-emission time using the segment's start anchor `(firstHostTime, startedAt)`. Persisted utterances carry wall-clock dates only; cross-segment ordering and display are both natural.

**Session-state derivation.** No explicit "paused" / "in progress" / "finalized" enum. State is read from the data:
- `session.endedAt != nil` → finalized.
- `session.endedAt == nil` and last `segment.endedAt == nil` → currently recording.
- `session.endedAt == nil` and last `segment.endedAt != nil` → paused (or interrupted; same shape on disk).

---

## 10. Persistence

Layout under `<container>/Application Support/Sadi/`:

```
Sadi/
  recordings/
    2026-05-27-14-32-08/             ← session id = local-time timestamp at start
      session.json                   ← metadata (title, segments, endedAt, speaker clusters)
      transcript.json                ← utterances; written ONCE at session finalize
      mic-001.mp4                    ← fragmented AAC mono 64 kbps, segment 1
      system-001.mp4                 ← fragmented AAC mono 64 kbps, segment 1 (absent in mic-only)
      mic-002.mp4                    ← if user paused then resumed
      system-002.mp4
      ...
  voiceprints/
    book.json                        ← persistent speaker identities
```

### 10.1 Session IDs

`YYYY-MM-DD-HH-MM-SS`, local time, 24-hour, all dashes. Lexicographic sort matches chronological order; no collision concern (we record one session at a time). If the user starts a second session in the same second (rapid stop/start), append `-1`, `-2`, etc. as a tiebreaker — cheap to detect at directory creation.

### 10.2 Segments & pause / resume

A session contains 1+ **segments**. Each segment = one press-record-to-pause/stop period and gets its own pair of fMP4 files (`mic-NNN.mp4`, `system-NNN.mp4`, 1-indexed, zero-padded to 3 digits).

- **Pause:** finalize the current segment's audio writers (close the files cleanly), drain any in-flight ASR/diarization, set `segment.endedAt`, rewrite `session.json`. Session stays open (`session.endedAt == nil`).
- **Resume:** allocate the next segment number, create new audio writers, start the capture stack again, append the new `Segment` to `session.segments`, rewrite `session.json`.
- **Stop:** finalize the current segment as above, then write `transcript.json` once, set `session.endedAt`, rewrite `session.json`. Session is done.

Utterances span segments naturally — they carry wall-clock dates and accumulate into one list. The pause gap shows up in the transcript as a time gap with no utterances; the UI can render a "⏸ paused N min" marker by inspecting `session.segments`.

### 10.3 What's written when

| Event | Files touched |
|---|---|
| Session start | `session.json` created; `mic-001.mp4` + `system-001.mp4?` opened for streaming write |
| Each audio buffer | Encoded AAC fragments appended to the current segment's fMP4s (fragment finalized every 10 s) |
| Pause | fMP4s for current segment closed (final fragment + index written); `segment.endedAt` set; `session.json` rewritten |
| Resume | `mic-NNN.mp4` + `system-NNN.mp4?` opened for next segment; `session.json` rewritten |
| Stop (finalize) | Current segment closed; `transcript.json` written once; `session.endedAt` set; `session.json` rewritten |
| Speaker rename | `session.json` (clusters), `voiceprints/book.json` |

`session.json` is small (no utterances inside it) so frequent rewrites are cheap. `transcript.json` is the big one and is written exactly once per session, at finalize.

### 10.4 Atomic writes

For `session.json`, `transcript.json`, and `book.json`: write to `<filename>.tmp` then `rename` over the live file. POSIX guarantees no half-written final file.

### 10.5 Crash recovery

No marker files. No launch-time scan. The directory structure *is* the state:

- Any session with `session.endedAt == nil` is unfinalized. The sessions list shows it with a small badge ("interrupted" or "paused" — same on-disk shape).
- Opening such a session offers a "**Finalize from audio**" action that re-runs the pipeline over the existing segment fMP4s to produce a `transcript.json`, then sets `session.endedAt`. Estimated runtime: a few minutes per hour of audio (§13 risk #5). User-initiated, not automatic; the user might prefer to delete instead.
- Per-segment crash safety comes from the fragmented MP4 container: each 10-second fragment is a complete, self-contained `moof`+`mdat` pair, so a file that wasn't cleanly closed is still playable up to its last finalized fragment. A hard crash loses at most the in-flight ≤10 s fragment.

Voiceprints (`book.json`) are only modified by user actions (rename / merge), so atomic-write is sufficient — there's no in-progress state to worry about.

### 10.6 Audio format & size

Default: **mono AAC, 64 kbps, encoded into fragmented MP4** (10-second fragment interval). Apple's hardware AAC encoder runs essentially free; the file is universally playable; ASR re-runs on decoded AAC are functionally identical to running on PCM at this bitrate.

Size envelope (per stream; double for a call with both mic + system):

| Bitrate | Per minute | Per hour | Per 5-hour day |
|---|---|---|---|
| **64 kbps (v1 default)** | ~0.5 MB | ~29 MB | ~145 MB |
| 32 kbps (TODO: evaluate) | ~0.25 MB | ~14 MB | ~70 MB |

**Open TODO:** Once we have a working pipeline, A/B-test 32 kbps against 64 kbps on real recordings — compare ASR transcripts (SpeechTranscriber output, ideally also a Whisper baseline) and listen-test the audio. AAC at 32 kbps mono is widely transparent for speech and is what podcast distribution often uses; if the WER delta on our recordings is in the noise, drop to 32 and halve storage. If it isn't, stay at 64.

Either way the archive is small enough that storage isn't a constraint — both rates are 1–2 orders of magnitude smaller than the Float32 CAF baseline we'd have shipped otherwise.

---

## 11. UI Surface

Minimal, focused; not a UI spec, but the contract the pipeline supports:

- **Recordings list** — sidebar of past recordings, newest first. Click to view transcript.
- **Live recording view** — shown while recording. Transcript appends in real time; each finalized `Utterance` slides in. A small "X" indicator on dropped (echo-filtered) utterances behind a debug toggle. Mode (call / mic-only) shown in the header.
- **Transcript view** — past recording. Each utterance has its speaker label, time, and text. Click the label to rename / assign to a voiceprint.
- **Settings** — ASR model selection (Apple SpeechTranscriber only in v1, but the surface is there), voiceprint book management.

The UI subscribes to `TranscriptStore`'s `AsyncStream<TranscriptEvent>`; `TranscriptEvent` is `.appended(Utterance)`, `.updated(Utterance)`, `.dropped(Utterance, reason)`, `.speakerRelabeled(clusterID, Speaker)`.

---

## 12. Dependencies & Entitlements

### Swift packages
- **FluidAudio** (pinned to a known-good version; bump deliberately): provides LS-EEND (streaming diarizer), Silero VAD, the offline diarizer, and the embedding model used for voiceprints. (ASR moved to Apple SpeechTranscriber; Parakeet is no longer downloaded.)
- **LocalVQE** (vendored binary + model in `Vendor/localvqe/`, Apache-2.0/MIT): `liblocalvqe.dylib` (dlopen'd, embedded in the app bundle, code-signed on copy) + the v1.4-AEC GGUF (bundled resource). No SwiftPM dependency; the Swift side is a ~100-line dlsym wrapper in SadiKit.
- (Stretch) **Sparkle** for auto-update if/when shipped.

No DSP libraries. No WebRTC. No custom CoreML model bundling beyond what FluidAudio handles.

### Entitlements
Managed via Xcode build settings (no standalone `.entitlements` file); the codesign step expands them into the embedded entitlements.
- `com.apple.security.app-sandbox` = true (`ENABLE_APP_SANDBOX = YES`)
- `com.apple.security.device.audio-input` = true (`ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES`)
- `com.apple.security.network.client` = true (`ENABLE_OUTGOING_NETWORK_CONNECTIONS = YES`, for FluidAudio one-time model download)
- `com.apple.security.files.user-selected.read-only` = true (`ENABLE_USER_SELECTED_FILES = readonly`, for any "import audio file" feature)

### Info.plist
- `NSMicrophoneUsageDescription` — required, or mic permission request crashes.
- `NSAudioCaptureUsageDescription` — required for the CoreAudio process tap (§5.2). macOS prompts "Sadi would like to record system audio" the first time `AudioDeviceStart` runs on the aggregate device. This is a separate permission category from Screen Recording.
- **No** `NSScreenCaptureUsageDescription` — we don't use ScreenCaptureKit.

> Implementation note: Xcode's `GENERATE_INFOPLIST_FILE = YES` machinery has a finite allowlist of recognized `INFOPLIST_KEY_*` build settings, and `NSAudioCaptureUsageDescription` isn't on it (as of Xcode 26.5). Use a hand-authored `Info.plist` referenced via `INFOPLIST_FILE` instead.

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

**Status legend:** ✅ shipped & milestone verified · 🟢 shipped, milestone not yet field-tested · 🚧 in progress · ⬜ not started

| Phase | Status | Commit |
|---|---|---|
| 1 — Foundation | ✅ | `28b9ef6` |
| 2 — Capture | ✅ | `2a7e9fc` |
| 3 — File Archive | ✅ | `9207d08` |
| 4 — VAD + Per-Track ASR | ✅ | `c4c01f5` |
| 5 — Diarization | ✅ (both tracks) | `bf62904` |
| 6 — Echo Filter | ✅ (signals a+c; b deferred) | `146e7b8`, pipetest `dea1bd3` |
| 7 — Mic-Only Mode | ✅ | `d08e375` |
| — — SpeakerSegmenter (mid-phase polish) | ✅ | `0eb04d4` |
| 8 — Persistent Speaker ID | ✅ | `3bea656` |
| 9 — Effective Sample-Rate Correction | 🟢 (needs 30 min field test) | _uncommitted_ |
| 10 — Crash Recovery & Polish | ⬜ | — |

### ✅ Phase 1 — Foundation
Project scaffold (SwiftPM-based Xcode project), sandbox + entitlements (via build settings; see §12), Info.plist with the required usage descriptions, build settings as above. App launches, requests mic permission, shows an empty window. **Milestone:** clean build, mic permission granted, empty UI.

> **Done.** SadiKit local SwiftPM package at the repo root, app target reuses the existing `Sadi.xcodeproj` per user direction. Entitlements already matched §12 from v0; switched to a hand-authored `Info.plist` to add the new keys.

### ✅ Phase 2 — Capture
`MicCapture` and `SystemAudioCapture` per §5, each pushing into its SPSC ring (§5.0). A consumer `Task` pulls and feeds a debug RMS meter for each stream. **Milestone:** start/stop captures both tracks; meters move when you speak / when audio plays; no Screen Recording prompt ever appears; the realtime callback does nothing but `ring.push`.

> **Done.** Realtime callbacks do only `ring.push` (+ the first-host CAS and, post-Phase-9, the delivered-frames counter add — all wait-free atomics). The macOS 26 `audioanalyticsd` precondition + `-10877` log noise is environmental and non-fatal (Apple's HALC client telemetry; we don't grant the lookup); see Appendix A.

### ✅ Phase 3 — File Archive
The consumer task per track encodes pulled samples to mono AAC at 64 kbps and writes a fragmented MP4 (`mic-001.mp4` / `system-001.mp4`) into the session directory using `AVAssetWriter` with `movieFragmentInterval = 10s`. **Milestone:** stop a recording; play back both `.mp4` files in QuickTime; mic is your voice, system is what was playing; file sizes match the §10.6 envelope (~0.5 MB/min/stream).

> **Done.** Verified at 70 s: ~62 kbps mic / ~56 kbps system VBR. The two streams stayed within 64 ms of each other end-to-end on a healthy machine — a baseline that Phase 9 keeps from drifting over hours.

### ✅ Phase 4 — VAD + Per-Track ASR
Add the ring buffer, Silero VAD, and per-track ASR per §6.2 and §6.3. No diarization yet; no echo filter; tag mic utterances as `.you` and system as `.them` unconditionally. **Milestone:** live transcript appears in the UI for both tracks during recording.

> **Done.** Uses FluidAudio's streaming-VAD API (`processStreamingChunk` + `VadStreamState`) rather than rolling our own state machine. ASR via Parakeet TDT v2 with a fresh `TdtDecoderState` per segment. Models load via `ModelHost` once at app start (~620 MB Parakeet download on first launch).

### ✅ Phase 5 — Diarization
Add LS-EEND on the system track per §6.4. System utterances are tagged with `.them` (one cluster) or `.remote(N)` (multi-cluster). **Milestone:** in a recording with two distinct far-end voices, the transcript shows two distinct remote speakers.

> **Done.** LS-EEND runs on **both** tracks per §6.4 (the mic embeddings feed Phase 6's eventual fingerprint signal and Phase 7's `.localSpeaker(N)` labels). dihard3 variant, 100 ms step. Verified with `Remote 1` / `Remote 2` labels on a 2-host podcast.

### ✅ Phase 6 — Echo Filter (Call Mode)
Implement §7 with all three bleed signals and the temporal precondition. Run against the harness (`scratch/pipetest`) on known recordings to verify. **Milestone:** on a recording with mic bleed of far-end audio, the bleed utterances are filtered out; on a recording where local user speaks during far-end silence, those utterances survive — even if the voices are similar.

> **Done with the temporal precondition + signals (a) text and (c) energy.** Signal (b) cosine-distance fingerprint deferred to Phase 6.1 — LS-EEND 0.14.7 doesn't expose centroid embeddings publicly. Verified across 5 sessions via the pipetest harness; **textMatch is 14/14 correct**, energy fires only in "meetings during loud playback" sessions and is ~half false-positive there (SPEC §2 explicitly accepts losing quiet local speech during loud far-end). Default 3× ratio kept per SPEC; tunable.

### ✅ Phase 7 — Mic-Only Mode
Detect mode per §7.1; in mic-only mode, run LS-EEND on the mic too; bypass the echo filter. **Milestone:** in an in-person recording (no system audio), multiple distinct local speakers appear correctly diarized.

> **Done.** Mic diarization was already running from Phase 5; Phase 7 stopped hard-coding `.you` and surfaced `.localSpeaker(N)`. TranscriptStore collapses mic clusters to `.you` in call mode (any system utterance seen so far). Rapid-conversation misattribution is the §13 Risk #2 streaming-diarizer baseline; partially addressed mid-phase by **SpeakerSegmenter** (split single VAD segments by per-word speaker via Parakeet's token timings); full retroactive relabel deferred to Phase 10.

### ✅ Phase 8 — Persistent Speaker ID
Implement §8.2: voiceprint book on disk, resolution flow at recording finalize (or live debounced), UI affordance to name speakers. **Milestone:** name "Alice" in one recording; in a new recording with Alice, her utterances show up as "Alice" automatically.

> **Done.** WeSpeaker 256-dim embedding extracted per utterance via `DiarizerManager.extractSpeakerEmbedding` (side-loaded purely for that helper; LS-EEND remains the diarizer). `VoiceprintBook` lives in SadiKit (pure logic: JSON persistence, cosine matching, running-average updates, modelVersion stamping). Live matching at receive time + click-to-name UI + `rerunVoiceprintMatching` to relabel past utterances in the current session.

### 🟢 Phase 9 — Effective Sample-Rate Correction
Wire up the wall-clock-derived `effectiveSampleRate` in `SystemAudioCapture` and use it in the resampler. **Milestone:** record a long (>30 min) session; verify by spot-check that system utterances stay in time with mic utterances throughout. (This is a robustness fix, not a feature, but it's important for long meetings.)

> **Implemented; not yet field-tested at 30 min.** `SystemAudioCapture.framesDelivered` (atomic, bumped in IOProc), `effectiveSampleRate(asOf:)` via `mach_timebase`. `StreamProcessor.retuneSourceRate(_:)` rebuilds the resampler if drift > 0.2%. `CaptureController`'s system consumer polls every 10 s of wall-clock. Mic skips polling — AVAudioEngine's hardware-rate query (§5.1) is already authoritative.

### ⬜ Phase 10 — Pipeline Correctness, Crash Recovery & Data Safety
Scoped to backend/pipeline correctness and crash safety. New data is surfaced **read-only, for debugging** — no full UI build-out here. The polished UI (Settings, voiceprint management, EchoFilter tuning, themed transcript) is deferred to a dedicated later UI phase.

**Pipeline correctness carryovers** (highest value, no new UI):
> - **Retroactive `.them` → `.remote(N)` relabel** when a second remote cluster appears mid-recording (Phase 5 carryover). Most self-contained; do first.
> - **Post-session diarizer relabel pass** (Phase 7 carryover): re-query `diarizer.timeline` after Stop and rewrite past utterance labels to the now-final cluster assignments.
> - **Phase 6.1 fingerprint signal**: cosine-distance signal (b) against centroid voiceprints in EchoFilter. We now have the embedding pipeline from Phase 8; the data is available.

**Crash recovery & data safety**:
> - **"Finalize from audio"** recovery action for unfinalized sessions (§10.5): re-run the pipeline over existing segment fMP4s to produce `transcript.json`. Pure pipeline — the offline path is already proven by `Sadi cli replay` (see `Sadi/CLI/`), which drives the live `StreamProcessor`/`TranscriptStore` from recorded files.
> - **Pause / resume + multi-segment writers** (§10.2): the one structural piece — splits a session into multiple `mic-NNN.mp4` / `system-NNN.mp4` segment pairs and rewrites `session.json` on each transition. Needs a single pause button; the work is in `CaptureController` / writers / `session.json` schema.
> - **Quit-while-recording confirmation dialog**: tiny; prevents data loss.

**Read-only debug surfacing** (simple, no styling):
> - Dropped (echo-filtered) utterances shown with an "✕" + reason.
> - "⏸ paused N min" markers in the transcript view (falls out of pause/resume).

**Deferred to a later UI phase:** Settings screen, voiceprint book management UI, EchoFilter parameter tuning UI (expose `energyRatio` / `jaccardThreshold`), polished/themed transcript view.

---

## 14. Risks & Open Questions

1. **CoreAudio process tap availability and exact API shape.** macOS 14.4+ is required; we target 26+, so available, but the invocation pattern (tapping all-system-output vs a specific process) needs verifying at implementation time. There are surprisingly few public examples; reference: WWDC23 Session 10235.

2. **LS-EEND streaming semantics.** "Streaming diarizer" still has retroactive cluster revision as more context arrives; the per-utterance speaker label may need to be re-emitted later. The data model (`Utterance.speaker` mutable; `.speakerRelabeled` events) supports this, but the UI needs to handle in-place updates gracefully.

3. **Voiceprint stability across hardware/contexts.** Embeddings shift when the mic, room, or speaker volume change. The running-average update helps but isn't bulletproof; the system needs a clear "rename / correct" affordance and shouldn't pretend to be more confident than it is. Start with a conservative threshold (0.55) and let the user retrain by correcting.

4. **FluidAudio's embedding model dimension and stability.** Document the dimension (used in voiceprint storage); commit to a model version with bump procedure. If FluidAudio changes embedding spaces in a future version, existing voiceprints become unmatchable — need a migration path or model-version tag on each voiceprint.

5. **ASR latency vs liveness.** SpeechTranscriber per-segment is fast (~70–270 ms per segment, measured), but two concurrent ASR streams + diarization is real load. Live transcript needs to keep up; if it doesn't, degrade to batching system-track ASR while keeping mic live (the user cares more about seeing their own thread of the conversation in real time — actually, no, they care more about the far-end; reverse this if needed).

6. **CoreML `E5RT zero shape error`.** Saw this once on a degenerate slice during prepare(). Mitigation: enforce a minimum slice length in the ASR consumer (~200 ms). If it persists, file/investigate against FluidAudio.

7. **Memory on long meetings.** Ring buffers are bounded; utterances accumulate. A 4-hour recording at, say, 1 utterance/5 seconds × 1 KB per utterance = ~3 MB. Embeddings (256-dim Float32 = 1 KB each) double that. Comfortable; no streaming-to-disk needed for in-memory utterances during a session.

8. **Mode-detection edge case** — *resolved.* Diarization runs on both tracks at all times (§6.4); call-vs-mic-only is purely a labeling decision (§7.1), so a quiet first-N-seconds in the far-end doesn't produce spurious mic clusters that need unwinding.

---

## 15. Out of Scope

- Custom real-time AEC (FDAF, NLMS, WebRTC). The OS canceller (§5.1) covers speaker bleed; building our own doesn't fit our priorities.
- Cloud anything.
- Live captions overlay on top of the call app.
- Meeting summarization, action items, knowledge-base integration (OpenOats does these; we don't, in v1).
- Multi-language support beyond the system locale (Apple SpeechTranscriber, en-US fallback).
- iOS / iPad version.
- Calendar integration / meeting auto-detect.
- Automatic launching / always-on capture.

---

## Appendix A — Lessons Carried Forward From v0

This spec encodes specific failures from the previous iteration:

- **VPIO is not used.** *(Re-tested on macOS 26, shipped briefly, then reverted — the v0 technical failures no longer reproduce, but the approach is wrong for this app.)* On macOS 26 a sandboxed VPIO unit starts cleanly (no mach-lookup entitlement, no DSP faults) and does cancel other processes' playback. But any active voice-processing session (a) ducks all other audio ~5.5 dB steady-state even at `kAUVoiceIOOtherAudioDuckingLevelMin`, with -34 dB transients and sloppy multi-second releases, and (b) applies a by-design gain change to the shared mic and output devices (Apple-confirmed, not disableable) that meeting apps' AGC then fights — a Meet participant heard the local user muddled during recording and blasting after stop. OpenOats independently ships Apple AEC hard-disabled for adjacent reasons (aggregate reconfiguration stalls vs their system tap). Echo cancellation therefore runs *in-process* (LocalVQE, §6.2a) where it cannot touch other apps' audio.
- **Mono channel-0 capture, not averaging.** MacBook built-in mic arrays expose multi-channel formats (front beam + directional / cancellation beams); averaging across channels causes destructive interference and effectively silences the voice. Always take channel 0.
- **Diarizing a *mix* of mic + system collapses both speakers into one cluster** when one is much louder. Per-track ASR is not negotiable.
- **Per-track normalization + raw energy comparison for bleed gating** is necessary (normalization is needed so ASR sees the quiet mic; raw comparison is needed so the energy gate isn't fooled by the boost).
- **A fingerprint-only bleed gate drops the local speaker when local and far-end voices are similar.** The temporal-overlap precondition is the load-bearing fix.
- **`let id = UUID()` in a `Codable` struct silently breaks decoding.** Use `var id = UUID()`.
- **The `MemberImportVisibility` upcoming feature requires explicit `import Combine` for `@Published` / `ObservableObject`.** Not optional.

---
