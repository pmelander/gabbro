# Gabbro

On-device voice capture for iPhone. Records, transcribes locally on the Neural Engine, and
hands a markdown note to Obsidian through the iOS share sheet.

**Design doc: [`docs/designs/voice-capture-obsidian-ios.md`](docs/designs/voice-capture-obsidian-ios.md).**
Read it before changing anything structural — several obvious-looking simplifications here
are load-bearing and the doc says why.

## Status

Pre-M0. The pipeline is scaffolded; the ASR integration is deliberately not written.

## Building — there is no Mac in this loop

Development happens on Windows. CI builds, you sideload, the phone measures itself.

```
push to main
  -> GitHub Actions builds an unsigned .ipa on a macOS runner (~10-15 min, free)
  -> download the artifact, unzip
  -> sideload from Windows: Sideloadly, AltServer, or iPASide, free Apple ID
  -> Files -> On My iPhone -> Gabbro -> Diagnostics  for M0 numbers
```

The repo is **public**, which is what makes macOS runner minutes unlimited and free. On a
private repo they carry a 10x multiplier (~200 macOS minutes/month on the free tier).

No debugger, no Instruments, no live console. That is survivable here because M0 is
measurement work rather than breakpoint work — the app instruments itself. See
[`docs/M0-RUNBOOK.md`](docs/M0-RUNBOOK.md). When chasing something on-device, add
`M0Telemetry.shared.noteEvent("...")` calls rather than log lines: events land in the report
with timestamps, `OSLog` output does not reach you.

### If you do get to a Mac

The repo has no `.xcodeproj`. It is described by [`project.yml`](project.yml) and generated
with [XcodeGen](https://github.com/yonaskolb/XcodeGen), which keeps it diffable and
authorable from a non-Mac.

```sh
brew install xcodegen
xcodegen generate
open Gabbro.xcodeproj
```

Re-run `xcodegen generate` after adding files. Do not commit the generated `.xcodeproj`.

## Signing

**No paid Apple Developer Program membership is required.** Sign in to Xcode with a plain
Apple ID and let automatic signing pick your personal team.

What free provisioning costs you:

| Limit | Impact here |
|---|---|
| Certificates expire every 7 days | Re-sign from Xcode, or use SideStore to refresh on-device |
| 3 apps installed at a time | None |
| ~10 App IDs per 7 days | None (app + widget extension = 2) |
| No push notifications | None — only local notifications are used |
| **No App Groups** | **Designed around.** See below. |
| No TestFlight | None — one user |

**Do not add an App Group.** It is the only paid-only capability this design would need, and
it was removed on purpose: a stateful Control Center toggle would need one to read recording
state from the widget extension process. Instead the control is a stateless button and the
Live Activity carries state — ActivityKit passes `ContentState` through the system, not
through a shared container. Adding an App Group back puts $99/yr on the critical path.

## Layout

```
project.yml                    XcodeGen spec: app + widget extension, FluidAudio pinned to 0.15.6
Shared/                        Compiled into BOTH targets
  RecordingActivityAttributes  Live Activity state
  RecordingIntents             App Intents + the registry that lets them reach app-only code
Gabbro/
  App/                         GabbroApp, CaptureView, CaptureModel
  Audio/                       AudioSessionManager, AudioRecorder, WAVWriter
  Model/                       RecordingJob, JobStore
  Transcription/               Transcriber protocol, ParakeetTranscriber, OverlapMerge, Coordinator
  Render/                      MarkdownRenderer
GabbroWidgets/                 Live Activity + Control Center button
```

## Four things that look wrong and are not

**1. `AudioRecorder.stop()` does not stop the engine.**
The background execution assertion is held by `mediaserverd` only while an I/O unit is
actually moving frames — not by `setActive(true)`. Stop arrives from the Lock Screen with the
app already backgrounded, so nothing stands between it and suspension mid-inference. The tap
keeps running (discarding buffers) and a `beginBackgroundTask` is held until the job reaches
`.ready`. Visible consequence: the orange mic indicator stays lit for a few seconds after you
press Stop. Expected.

**2. Transcription runs during capture, not after it.**
While the audio session is live, `UIBackgroundModes: audio` legitimately covers inference. By
the time you press Stop only the tail chunk remains. Record-then-transcribe would owe minutes
of ANE work at exactly the moment the assertion is weakest.

**3. The intents live in `Shared/`, not the app target.**
The `ControlWidget` has to reference the intent type, so it must compile into the extension.
It only ever *executes* in the app process, via `LiveActivityIntent` conformance and
`RecordingControl_Registry`. An intent running in the widget extension process could never
host a capture session — that process has no `UIBackgroundModes: audio`.

**4. `ParakeetTranscriber` throws instead of working.**
The source spec says, in its own words: *"Verify exact API surface against the current release
rather than trusting this document."* FluidAudio is pre-1.0 and moves. Writing plausible
`AsrManager` signatures from memory would look finished and fail on first build. The file
carries the M0 checklist; fill the three TODOs from the 0.15.6 source. `StubTranscriber` wires
the pipeline end to end meanwhile — it is the sanctioned early fake, never a shipping path.

## M0 — before this is worth building on

Four gates, all measured on a **20-minute live locked capture with incremental inference
running**, not an offline file run:

- **Speed** — sustained ≥ 2x real-time single-stream, measured *under lock* (CPU/ML work runs
  markedly slower backgrounded)
- **Memory** — `os_proc_available_memory()` ≥ 400 MB at peak, locked and backgrounded
- **Thermal** — does not reach `.serious`
- **Battery** — measured against the same capture with inference disabled

Plus: the real model artifact size at the pinned SHA (authorized to fail the design if it is
FP16-sized), whether FluidAudio lets you pin `computeUnits` to `.cpuAndNeuralEngine` (iPhones
cannot use the GPU in the background — this is not optional), the locked-screen start spike,
and the interruption spike.

**A failed gate is a project stop, not a substitution.** See the design doc's M0 failure policy.

## Privacy

The only network activity in the app's life is the one-time model weight fetch. No analytics,
no crash reporter, no ATS exceptions. Audio and transcripts live in `Documents/` with
`isExcludedFromBackupKey = true` — without that they would be uploaded to iCloud Backup, which
would contradict the whole point and which the airplane-mode test would not catch, because it
is OS traffic rather than app traffic.
