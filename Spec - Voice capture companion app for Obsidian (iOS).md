---
tags:
  - spec
  - ios
  - asr
  - obsidian
status: draft
created: 2026-09-21
related: "[[On-device multilingual ASR on iPhone (A18)]]"
---

# Spec — Voice capture companion app for Obsidian (iOS)

## 1. Summary

A standalone iOS app that records voice, transcribes it locally on the Neural Engine using Parakeet TDT 0.6B v3, and writes the result as a markdown note into an existing Obsidian vault. No Obsidian plugin involved — an Obsidian plugin runs in a Capacitor WebView and cannot reach CoreML.

**Design constraint driving everything below:** the app never has the vault "open". It holds a security-scoped handle to a folder that another app (Obsidian, plus iCloud or whatever sync layer) is concurrently mutating.

## 2. Goals

- Capture voice with the screen locked
- Transcribe fully on-device; no audio leaves the phone, ever
- Land a well-formed markdown note in the vault without manual copy-paste
- Survive the round trip: audio is retained until the note is confirmed written

## 3. Non-goals (v1)

- Live/streaming captions. Parakeet v3 multilingual has no native streaming EOU path — this is record-then-transcribe.
- Editing existing vault notes. Write-new-only.
- Speaker diarization. FluidAudio supports it; defer to v2.
- Desktop, iPad-specific layout, watchOS.

## 4. Architecture

```
AVAudioEngine tap
  → 16 kHz mono Float32 (AVAudioConverter)
  → WAV on disk (durable buffer)
  → VAD segmentation
  → chunked Parakeet inference (ANE)
  → overlap merge
  → markdown render
  → NSFileCoordinator write into vault
```

### 4.1 Audio capture

- `AVAudioSession` category `.record`, mode `.measurement` — `.measurement` disables AGC and system voice processing, which materially helps ASR input quality.
- Input node is typically 48 kHz; convert to **16 kHz mono Float32** via `AVAudioConverter`. Parakeet expects 16 kHz.
- `UIBackgroundModes: audio` so recording continues on lock.
- Write raw audio to disk *during* capture, not just into memory. A crash mid-session must not lose the recording — transcription is always re-runnable from the WAV.

### 4.2 Transcription

- **FluidAudio** (Swift/SPM), Parakeet TDT 0.6B v3 CoreML weights.
- Compute units pinned to `.cpuAndNeuralEngine`.
- VAD (Silero, shipped with FluidAudio) to drop silence and find segment boundaries.
- Chunking: ~10–15 s windows with **1–2 s overlap**. Merge on the overlap region by token-level alignment; naive concatenation duplicates words at every seam.
- Language detection is automatic across the 25 supported languages. Expose a manual override in settings if the API allows a language hint — otherwise document that mid-note code-switching may produce artefacts.

> FluidAudio is pre-1.0. Verify exact API surface (`AsrManager`, `ModelRegistry`) against the current release rather than trusting this document.

### 4.3 Model delivery

- ~460 MB, fetched once on first launch.
- **Pin the HF revision** (`ModelRegistry.repoOverrides`) — do not track a default branch.
- Store in Application Support, set `isExcludedFromBackupKey = true`. 460 MB in the user's iCloud backup is hostile.
- Gate the download behind Wi-Fi by default, with an explicit "download on cellular" toggle.
- Show a real progress indicator; this is the app's worst first-run moment.

## 5. Vault integration

### 5.1 Access

`UIDocumentPickerViewController` in folder mode → user selects the vault root once → persist a **security-scoped bookmark**. This works for vaults in iCloud Drive, On My iPhone, and third-party File Providers.

There is no App Group path — Obsidian is a third-party app and shares no container.

### 5.2 Writing

- Wrap every write in **`NSFileCoordinator`**. iCloud and Obsidian are both touching this directory; uncoordinated writes produce conflict files.
- Bookmarks go stale (OS updates, provider changes). Handle `isStale` by re-prompting for the folder rather than failing silently.
- **Never overwrite.** On filename collision, suffix `-1`, `-2`.
- Write to a temp file and atomically move into place, so Obsidian's file watcher never sees a half-written note.

### 5.3 `obsidian://` URI — secondary path only

`obsidian://new?vault=…&file=…&content=…` is useful as a "send to Obsidian now" action, but it foregrounds Obsidian, has URL length limits, and can't run unattended. Not the primary write path.

### 5.4 Note format

Configurable via template. Default:

```markdown
---
created: 2026-09-21T14:32:00+02:00
duration: 4m12s
language: sv
model: parakeet-tdt-0.6b-v3
model_revision: <pinned-sha>
tags: [voice]
---

<transcript>
```

Settings:
- Target folder within vault (default: `Inbox/`)
- Filename template (default: `{{date}}-{{time}}-voice.md`)
- Mode: new file | append to daily note
- Optionally copy the source audio into the vault attachments folder and embed `![[recording.m4a]]`

## 6. State model

Recordings are a queue, not a single-shot flow:

| State | Meaning |
|---|---|
| `recording` | Capture in progress |
| `pending` | Audio on disk, not yet transcribed |
| `transcribing` | Inference running |
| `review` | Transcript ready, awaiting user confirm/edit |
| `written` | Note in vault; audio may be purged per retention setting |
| `failed` | Retryable; audio retained |

A recording is only deleted after `written` + retention window. Everything before that is recoverable.

## 7. Thermal and power

Monitor `ProcessInfo.processInfo.thermalState`. On `.serious` or `.critical`, pause the transcription queue and surface it in the UI rather than silently degrading. Sustained ANE load on a small chassis throttles well before the compute ceiling.

Offer a "transcribe while charging" mode that defers the queue via `BGProcessingTaskRequest`. Note that iOS will suspend long foreground-style work in the background — the queue must be resumable mid-chunk, not restart-from-zero.

## 8. Privacy posture

- The only outbound network call in the entire app is the one-time model fetch.
- No analytics SDK, no crash reporter that could capture audio buffers or transcript text.
- No ATS exceptions.
- State this plainly in the App Store privacy nutrition label: no data collected.

**Verification (do this, don't assume it):** run under Charles with airplane mode toggled after first launch and confirm a full record → transcribe → write cycle completes with the interface down.

## 9. Risks

| Risk | Mitigation |
|---|---|
| FluidAudio API churn (pre-1.0) | Pin the SPM version; wrap in a thin internal protocol so the dependency is swappable for sherpa-onnx |
| Stale security-scoped bookmark | Detect `isStale`, re-prompt; never fail a transcription because of it |
| iCloud conflict files in vault | `NSFileCoordinator` + atomic move; test against a vault actively syncing |
| 460 MB first-run download | Wi-Fi gate, resumable, clear progress |
| Overlap merge artefacts | Test corpus with known transcripts; assert no duplicated tokens at seams |
| Thermal throttle on long recordings | Queue pause + deferred processing mode |

## 10. Milestones

- **M0 — spike.** Load Parakeet v3 via FluidAudio on device. Measure real-time factor and peak memory on the target hardware. *Kill criterion: if RTF > 1.0 on A18, the whole design changes.*
- **M1 — walking skeleton.** Record → transcribe → write one file to a picked folder. No queue, no settings, no polish.
- **M2 — usable.** Queue, review/edit screen, settings, templates, thermal handling.
- **M3 — nice.** Audio attachment embed, daily-note append, language override, diarization.

## 11. Open decisions

- [ ] Minimum iOS version — determined by FluidAudio's floor; verify
- [ ] Distribution: App Store, or TestFlight/sideload for personal use only (affects whether the privacy label and review process matter at all)
- [ ] Retention default for source audio after successful write
- [ ] Does Parakeet v3 expose a language hint parameter, or is detection strictly automatic?
