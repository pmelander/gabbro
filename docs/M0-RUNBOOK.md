# M0 runbook — running the gates without a Mac

Development happens on Windows. CI builds an unsigned `.ipa`, you sideload it, and the phone
is on its own — no Xcode, no Instruments, no console. So the app measures itself and writes
the verdict to a file you read in Files.

Design doc: [`designs/voice-capture-obsidian-ios.md`](designs/voice-capture-obsidian-ios.md).

## The loop

**Preferred — the desktop never touches the binary:**

```
git tag v0.1.1 && git push --tags
  -> GitHub Actions builds and publishes a Release (~10-15 min)
  -> open the Releases page in Safari ON THE IPHONE
  -> install the .ipa with SideStore or AltStore, free Apple ID
  -> run the capture
  -> Files -> On My iPhone -> Gabbro -> Diagnostics -> m0-<timestamp>.json
```

A release asset is a plain public HTTPS URL, so the phone can fetch it directly. This exists
because a centrally managed desktop will block an unsigned, zero-reputation download by
policy — and the right response to that is not to argue with the policy, it is to notice the
laptop was never needed in the path. The phone is the target; let it do the download.

**Via desktop, if you prefer:**

```
push to main
  -> GitHub Actions builds an unsigned .ipa (free, public repo, ~10-15 min)
  -> download the artifact, unzip
  -> sideload with Sideloadly / AltServer / iPASide, free Apple ID
```

Builds expire after 7 days. Re-sideload, or let SideStore refresh on-device.

### Antivirus will probably flag the download

Expect it, and verify rather than either panicking or waving it through.

Why it happens: the artifact is a **zip containing an `.ipa`, which is itself a zip**
containing an ARM64 Mach-O. Nested archives wrapped around an unsigned, zero-reputation
executable is exactly what heuristic and prevalence-based detection is built to catch. The
binary is unsigned on purpose — signing happens at sideload time with your Apple ID, so the
CI runner has no certificate and needs none. And the file has been seen by one person on
earth, which some engines flag on its own.

Also worth knowing: an **iOS arm64 Mach-O cannot execute on Windows**. Whatever the verdict,
the file is inert on the machine that downloaded it.

How to verify instead of trusting:

1. Every CI run's summary page prints the **SHA256** of the `.ipa` as built, plus a full
   manifest of its contents. Compare: `certutil -hashfile Gabbro.ipa SHA256`.
2. A `Gabbro.ipa.sha256` file ships in the same artifact.
3. The summary lists every file inside the `.ipa`. Nothing should be unexpected — the app
   binary, the widget extension, the asset catalog, Info.plists, and the Swift runtime libs.
4. The build log prints `otool -L` output, so the linked libraries are visible too.

If the detection names a **specific** malware family rather than a generic ML or
low-reputation verdict, stop and investigate — the one genuine third-party code path here is
FluidAudio, pulled by SPM. It is pinned to an exact version in `project.yml` and to a commit
in `Package.resolved`, and the resolved graph is printed in the build log.

**On a corporate-managed endpoint, an AV exclusion is a policy decision, not a local
toggle.** If this machine's antivirus is centrally managed, that is a conversation with
whoever owns the policy rather than something to switch off.

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

### The widget extension needs its own App ID, and tools will quietly drop it

If `GabbroWidgets` crashes with `EXC_BAD_ACCESS` / `SIGKILL` and a termination namespace of
`CODESIGNING` ("Invalid Page"), that is the kernel refusing the extension's signature. It is
an **install-time provisioning problem, not a code bug.**

Why it happens: **every app extension consumes one of the 10 App IDs a free Apple ID gets
per 7 days.** Sideloadly can strip extensions before install for exactly that reason, and if
the app is signed while the extension's App ID was never registered, you get an invalid
signature and a kernel kill on first use.

**How to confirm it is this and not something in the code.** Compare the two `.ips` files:

| Field | Host app | Broken appex |
|---|---|---|
| `codeSigningTrustLevel` | 4 | **0** |
| `codeSigningAuxiliaryInfo` | non-zero | **0** |
| `codeSigningFlags` | includes `get-task-allow` | does not |

Trust level 0 means no valid signature at all. `vmRegionInfo` will place the faulting
address inside an `r--/r--` **mapped file** region — the appex's own code pages — and the
process will have lived about 3 ms, with `usedImages` empty and symbolication failed. It
died on the first page-in of its own code, before dynamic linking finished. No app code ran,
so no app code is implicated.

What to check:

- Whether the sideload tool is set to remove app extensions (Sideloadly offers this).
- Whether the App ID quota is exhausted — app + widget extension is 2 of 10 per week, and
  every re-sideload can consume more.
- **Do not run AltStore and Sideloadly against the same app.** They overwrite each other's
  certificates and previously-signed apps stop opening.

**Or just install the no-extension build.** Every CI run publishes
`Gabbro-no-extension.ipa` alongside the full one — same build, `PlugIns/` stripped, so
there is no appex to sign or fail. Use it to get on with M0 and sort the extension signing
as its own task.

What it costs you, and what it does not: the Live Activity and the Control Center button
stop working, so the **locked-screen start and Lock Screen stop paths cannot be tested.**
Everything else is unaffected — the in-app record button calls `CaptureModel.start()`
directly rather than through `AudioRecordingIntent`, and `Activity.request` is already
behind a `try?`. **M0's four gates do not need the extension.** Measure first, sort the
appex signing before testing the intent paths.

### "It crashed but there is no crash log"

That is the signature of a **memory kill**. Jetsam does not write a crash report under the
app's name — it writes **`JetsamEvent-<date>.ips`**, so scrolling Analytics Data looking for
"Gabbro" finds nothing and the crash appears to have left no trace.

Where to look instead:

1. **Analytics Data → `JetsamEvent-*`** around the time it died. The app will be listed
   inside with its memory footprint at kill time.
2. **`Files → On My iPhone → Gabbro → Diagnostics → crash-trail.txt`.** Breadcrumbs are
   written synchronously, so they survive a kill that leaves no crash report. The model
   preparation path records available memory at each step
   (`model:prepare-begin`, `model:download 30% avail=…MB`, `model:downloaded`,
   `model:ready`), so the trail shows both where it died and how much headroom was left.

The main lever is the **model size**, set in `WhisperTranscriber.init`. `small` is the
practical floor for multilingual quality; `base` and `tiny` are lighter but noticeably worse
on Norwegian, which is the language the engine was chosen for — so dropping below `small`
trades away the reason for the engine. Move up to the large variant only once M0 reports the
real headroom.

### Which build am I actually running?

`CFBundleVersion` is stamped in CI with the run number and the short commit SHA, and it
appears in every crash log. Check it before concluding a fix did not work — twice now a
"still broken" report has turned out to be a build that predated the fix.

The breadcrumb banner helps too: if the app shows "Previous run ended at: …" then it at
least contains `73252be`.

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
