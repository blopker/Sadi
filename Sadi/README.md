# Hapi Clone — local meeting recorder & transcriber

A minimal macOS app that records your **microphone + system audio**, then
produces a **speaker-labelled transcript** entirely **on-device**. No cloud,
no meeting-detection, no account. Just the core of what Hapi does.

Pipeline: capture mic + system audio → mix to one file → diarize (who spoke
when) → transcribe each speaker turn → show a labelled transcript.

---

## Important: read this first

This code was written **without being compiled or run** — treat it as a
solid starting project, not a finished binary. You build it in Xcode.

The riskiest file is `SystemAudioRecorder.swift`. ScreenCaptureKit's audio
behaviour has changed across macOS versions, so system-audio capture is the
part most likely to need a tweak on your specific OS. Everything else is
fairly standard AVFoundation / SwiftUI.

---

## Requirements

- macOS 14.0 (Sonoma) or later — Parakeet's Core ML models need 14+
- Xcode 16+ (Swift 6)
- Apple Silicon strongly recommended (the models run on the Neural Engine)
- ~1 GB free disk + internet **on first launch** (models download once)

---

## Setup (about 5 minutes)

### 1. Create the Xcode project
- Xcode → New → Project → **macOS → App**
- Product name: `HapiClone`, Interface: **SwiftUI**, Language: **Swift**
- Delete the auto-generated `ContentView.swift` and `*App.swift`

### 2. Add the source files
Drag all the `.swift` files from this folder into the project
(check "Copy items if needed", add to the `HapiClone` target):
`Models.swift`, `MicRecorder.swift`, `SystemAudioRecorder.swift`,
`AudioMixer.swift`, `Transcriber.swift`, `GlobalHotkey.swift`,
`AppController.swift`, `ContentView.swift`, `HapiCloneApp.swift`

### 3. Add the FluidAudio package
- File → Add Package Dependencies…
- URL: `https://github.com/FluidInference/FluidAudio.git`
- Dependency rule: Up to Next Major, from `0.12.4`
- Add the `FluidAudio` product to the `HapiClone` target

FluidAudio is the on-device engine: NVIDIA Parakeet for transcription and a
Pyannote Community-1 pipeline for speaker diarization, both Core ML.

### 4. Set permissions (target → Info / Signing & Capabilities)
Add this key under **Info**:
- `NSMicrophoneUsageDescription` → e.g. *"Records your microphone for
  meeting transcription."*

For a personal-use build, the simplest path is to **turn App Sandbox off**
(Signing & Capabilities → remove the App Sandbox capability). If you keep
the sandbox, you'll need: Audio Input, Outgoing Network Connections (for the
first-run model download), and a writable location.

Screen Recording permission (needed by ScreenCaptureKit for system audio)
is **not** an Info.plist key — macOS will prompt on first capture. Grant it
in System Settings → Privacy & Security → Screen Recording, then relaunch.

### 5. Build & run
First launch downloads the models (one-time, slow). After that everything
is offline.

---

## Using it

- **Record button**, or the global hotkey **⌥⌘R** from any app
- Stop → it mixes, diarizes and transcribes automatically
- Pick a recording in the sidebar to read the speaker-labelled transcript
- Audio files are kept in
  `~/Library/Application Support/HapiClone/Recordings`

---

## How the speaker labelling works

Diarization runs on the **mixed** recording. With two people on a call it
finds two voice clusters and labels them Speaker 1 / Speaker 2.

To handle calls without headphones, `MicRecorder` enables macOS voice
processing, which applies acoustic echo cancellation to the mic input —
the far-end voice leaking out of your speakers is largely removed before
recording. Any residual bleed clusters as the *same* speaker as the clean
system-track copy, so it never creates phantom speakers. (Note: how
completely the OS cancels echo from a *separate* app's playback, e.g.
Chrome/Meet, varies — test it; worst case the residual is just harmless
bleed.) Accuracy is good for 2–4 speakers and drifts lower beyond that.

For each speaker turn the app transcribes just that slice of audio, so each
block of text belongs cleanly to one speaker (no fragile word-timestamp
alignment).

---

## Crash safety

A crash mid-recording does **not** lose the recording:

- The system-audio file is written as a *fragmented* MP4 — `AVAssetWriter`
  flushes a self-contained, playable fragment every ~5 seconds. If the app
  dies before `finishWriting()`, the file stays playable up to the last
  fragment instead of becoming an unreadable stub.
- The microphone file is CAF, which tolerates an unfinalized header.
- While recording, an `inprogress.json` marker names the two audio files.
  On the next launch the app sees it, automatically mixes and transcribes
  the orphaned files, and adds the result as a "Recovered recording".
- Finished transcripts are saved to `recordings.json` (atomic writes), so
  they survive a normal quit or a crash.

Limit: a kernel panic or power loss can still cost the last few seconds of
unflushed audio. App crashes — the common case — are fully covered.

---

## Deliberately left out (easy extensions)

- Meeting auto-detection — you said you didn't want it.
- Export (Markdown / SRT), search, summaries, renaming speakers.
- Configurable hotkey UI (currently hard-coded to ⌥⌘R).

---

## If something doesn't work

- **No system audio in the transcript** → Screen Recording permission, then
  relaunch. If still empty, your macOS version may handle audio-only
  `SCStream` differently — see the notes in `SystemAudioRecorder.swift`.
- **FluidAudio build errors** → you likely pulled a newer version with a
  changed API. Check the FluidAudio repo README; adjust `Transcriber.swift`.
- **Hotkey doesn't fire** → add the app under Privacy & Security →
  Accessibility.
- **Models won't download** → first launch needs internet; corporate proxy
  users can set `https_proxy` (FluidAudio supports it).
