# M0 runbook — running the gates without a Mac

Development happens on Windows. CI builds an unsigned `.ipa`, you sideload it, and the phone
is on its own — no Xcode, no Instruments, no console. So the app measures itself and writes
the verdict to a file you read in Files.

Design doc: [`designs/voice-capture-obsidian-ios.md`](designs/voice-capture-obsidian-ios.md).

## The loop

```
push to main
  -> GitHub Actions builds an unsigned .ipa (free, public repo, ~10-15 min)
  -> download the artifact, unzip
  -> sideload from Windows with Sideloadly / AltServer / iPASide, free Apple ID
  -> run the capture on your phone
  -> Files -> On My iPhone -> Gabbro -> Diagnostics -> m0-<timestamp>.json
```

Builds expire after 7 days. Re-sideload, or let SideStore refresh on-device.

## First install: three gates, in this order

A sideloaded build does not just run. There are three separate permissions, each with a
failure mode that looks like something else. Do them in order.

**1. Trust the certificate.** Settings -> General -> VPN & Device Management -> under
*Developer App*, tap your Apple ID -> Trust.

- The *Developer App* section **does not exist until you have tried to launch the app at
  least once.** If Settings looks empty, tap the Gabbro icon, let it fail, go back.
- The device **needs internet at the moment you tap Trust** — iOS verifies the certificate
  with Apple. Offline you get "Unable to Verify App", which reads like a signing failure and
  is not one. Do this *before* any airplane-mode testing.
- If the error says *"your device management settings do not allow"* and
  VPN & Device Management also lists an **MDM enrolment profile**, this is a managed device
  and the policy forbids developer-signed apps. That is a policy question for whoever owns
  the profile, not something to work around. This project assumes a personal device.

**2. Enable Developer Mode** (iOS 16+, separate from trust). Settings -> Privacy & Security
-> Developer Mode -> on -> the phone restarts -> **confirm again after the reboot**, with
your passcode.

- There are **two confirmations and the second is post-restart.** Toggling only schedules
  the reboot; the alert you get when the phone comes back is what actually enables it. Miss
  it and the toggle reads off with no explanation.
- The menu item only appears once the device has been connected to Xcode or had a
  developer-signed app installed.
- One-time, persists across reboots. It does relax some on-device protections — a reasonable
  trade on a personal phone, but a real one.

**3. Grant microphone access** on first launch. `AudioSessionManager.hasMicrophonePermission()`
gates the intents, and a locked-screen entry point cannot prompt — so grant it in the
foreground before testing any Lock Screen start.

### Symptoms that are not what they look like

| What you see | Actual cause |
|---|---|
| App installs, icon greyed or "Unable to Verify App" | Certificate not trusted, or no network while trusting |
| "Untrusted Developer" | Step 1 not done |
| App refuses to launch after trusting | Developer Mode (step 2) |
| Developer Mode toggle absent | No developer-signed app installed yet |
| Toggled Developer Mode, still off | Missed the post-restart confirmation |
| Worked for a week, then stopped | 7-day free-team certificate expiry — re-sideload |
| A fourth sideloaded app will not install | Free Apple ID caps you at 3 installed at once |

## The four gates

From the design doc. Change them here and you have changed M0.

| Gate | Threshold | Where it lives |
|---|---|---|
| Speed | sustained **≥ 2.0× real-time**, single-stream, **measured under lock** | `M0Telemetry.speedGateRTF` |
| Memory | **`os_proc_available_memory()` ≥ 400 MB** at worst sample, locked | `M0Telemetry.memoryGateAvailableBytes` |
| Thermal | never reaches **`.serious`** | `M0Telemetry.thermalGateCeiling` |
| Battery | measured, judged — compare against the inference-disabled baseline | manual |

**A failed gate is a project stop, not a substitution.** sherpa-onnx and whisper.cpp exist,
but Whisper detects one language per ~30 s window, which breaks the code-switching criterion
specifically, and both change the memory and thermal profile the design rests on. Reopen the
design instead.

## Running it

**Two runs, same length, same route, same pocket.** The battery gate is a ratio, not a number.

1. **Baseline.** Set `CaptureModel.inferenceEnabled = false`. Record 20 minutes, screen
   locked, phone in a pocket. This captures audio and transcribes nothing.
2. **Real run.** Set it back to `true`. Same 20 minutes, same conditions.

Both write a report. Compare `verdict.batteryPercentUsed`.

Start the capture, then **lock the phone immediately and leave it locked.** The report marks
itself `INVALID` if the device never locked, if the run was under 20 minutes, or if no chunks
were transcribed — easy conditions cannot produce a pass.

## Reading the report

`verdict` comes first; everything else is there if you want to argue with it.

```json
{
  "verdict": {
    "valid": true,
    "validityNote": "valid",
    "speedRTF": 3.4,
    "speedGate": "PASS",
    "minAvailableBytes": 612344320,
    "memoryGate": "PASS",
    "worstThermal": "fair",
    "thermalGate": "PASS",
    "batteryPercentUsed": 11.0,
    "batteryGate": "MEASURE — compare against an inferenceEnabled:false run of the same length"
  },
  "run": {
    "modelLoadSeconds": 4.2,
    "modelArtifactBytes": null,
    "maxBacklogSeconds": 6.1,
    "lockedForSeconds": 1180,
    "chunkCount": 104,
    "chunksMeasuredWhileLocked": 101
  }
}
```

Things worth knowing about how these are computed:

- **`speedRTF` uses only chunks that ran while locked.** CPU/ML work runs markedly slower
  backgrounded; a foreground measurement would flatter the design into passing. If
  `chunksMeasuredWhileLocked` is much lower than `chunkCount`, you did not keep it locked.
- **`minAvailableBytes` is the worst sample, not the mean.** Jetsam does not care about your
  average, and a backgrounded app gets a tighter limit than a foreground one.
- **`modelLoadSeconds` is excluded from the speed gate.** Cold load is a one-off cost; it is
  reported so you can size the first-run experience, not to skew throughput.
- **`availableBytes: 0`** means the measurement failed rather than that memory ran out. It is
  reported as-is so a broken reading cannot look like a passing one.

## M0 step 1: things only reading the FluidAudio source can answer

These block writing `ParakeetTranscriber` and are listed at the top of that file too.

- [ ] **Real artifact size at the pinned SHA.** The spec says ~460 MB, but 0.6B parameters is
      ~1.2 GB at FP16 and ~600 MB at INT8. **If it is FP16-sized, this step is authorized to
      fail the design**, not merely to record the number. Put the value in
      `noteModelLoad(artifactBytes:)`.
- [ ] **Can you set `MLModelConfiguration.computeUnits`?** It must be `.cpuAndNeuralEngine`.
      iPhones cannot use the GPU in the background, and the default `.all` includes it — if
      CoreML schedules any of the encoder or the TDT decode loop on the GPU, inference fails
      on exactly the locked path. If FluidAudio offers no way to set it, that is a
      design-level finding.
- [ ] **Does it return a detected language code?** Decides whether the frontmatter `language`
      field exists at all. Parakeet takes no language *input*; whether it surfaces detection
      as *output* is a separate question.
- [ ] **Does it window internally regardless of input length?** If yes, success criterion 4's
      single-pass baseline cannot exist, and the criterion becomes "our chunking adds no
      artefacts beyond the library's".
- [ ] **Does Silero VAD actually ship with the package?** Asserted by the spec, unverified.
- [ ] **Exact HF repo id and the commit SHA you are pinning.**

## The two spikes the telemetry cannot answer

**Locked-screen start.** Does a `ControlWidget`-hosted intent conforming to
`AudioRecordingIntent` + `LiveActivityIntent` start capture from the locked screen on this
device and OS build? Both readings of Apple's docs are live. If it fails, set
`openAppWhenRun = true` on `StartRecordingIntent` and accept Face ID.

**Interruption.** Trigger an incoming call during a backgrounded locked recording. Does
`.ended` / `.shouldResume` ever arrive, or is the app suspended and recovered at next launch?
Criterion 2b accepts either, but the design has to say which one ships. Watch for the
`device locked` / `device unlocked` events in the report, and check whether the job came back
as one job or two.

## When something fails on-device and you have no debugger

Everything goes through `OSLog` with subsystem `com.pmelander.gabbro`. Without a Mac you
cannot stream it live — so anything you need after the fact should be a
`M0Telemetry.shared.noteEvent("...")` call, which lands in the report's `events` array with a
timestamp. When you are chasing something, add events rather than log lines.
