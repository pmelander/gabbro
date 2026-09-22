# Gabbro

Talk into your phone. Get a markdown note in your Obsidian vault.

Nothing leaves the device. The recording, the transcription and the note are all
produced on the phone, on the Neural Engine. The only network request Gabbro
ever makes is fetching the speech model once, on first launch.

---

## What it does

**Record, including with the screen locked.** Press record, pocket the phone,
keep talking. Audio is written to disk *as it is captured*, so a crash, a
force-quit or a phone running out of battery costs you nothing — the recording
is still there when you come back.

**Transcribe on device, in your languages.** Whisper running on the Apple Neural
Engine. Norwegian, Swedish, Danish and English, plus around ninety more. The
detected language is recorded in the note.

**Hand the note to Obsidian yourself.** Gabbro renders markdown with YAML
frontmatter and gives it to the iOS share sheet. Tap, pick Obsidian, done.

**A queue you can see.** Transcription takes as long as it takes. Every
recording shows what is happening to it — queued, transcribing with a
percentage, ready to share — and the queue resumes on its own whenever you open
the app.

**Storage that looks after itself.** Audio is kept for 30 days and then removed
automatically; transcripts and notes are kept forever. Swipe any recording to
delete it outright. The app tells you what it freed and how much is on disk.

## Why it works this way

**It is an app, not an Obsidian plugin.** Obsidian on iOS runs inside a
Capacitor WebView, which has no route to CoreML. On-device transcription is not
possible from a plugin, at any level of effort.

**It never opens your vault.** No security-scoped bookmark, no file coordinator,
no writing into a directory that iCloud and Obsidian are both touching. Gabbro
owns its own transcripts and hands them over through the share sheet, so it
cannot create conflict files, cannot overwrite a note, and cannot leave a
half-written file behind. Delivery costs one tap per note. That is the trade,
and it removes every irreversible failure the direct-write design had.

**Whisper, not Parakeet.** Parakeet TDT is the better model for mid-sentence
language switching and was the original choice. Its language set is the 24 EU
official languages plus Russian and Ukrainian — which excludes Norwegian, since
Norway is not in the EU. A hard requirement beat a quality preference. The cost
is real and worth knowing: **Whisper decides one language per ~30 s window**, so
a sentence that switches Swedish→English mid-flow gets forced into one of them.

## Privacy

- The only outbound request in the app's life is the one-time model download.
- No analytics, no crash reporter, no third-party network code.
- Audio and transcripts are excluded from iCloud backup, so recordings do not
  travel off the phone that way either.
- **Verified, not asserted:** a full record → transcribe → share cycle completes
  with the device in airplane mode.

## Note format

```markdown
---
created: 2026-09-22T14:32:00+02:00
duration: 4m12s
language: [sv, en]
input_route: built-in
model: whisper-large-v3-v20240930_626MB
tags: [voice]
---

Verbatim transcript, paragraphed on natural pauses.
```

Verbatim only. No summarising, no rewriting, no LLM touching the words you said.

## Requirements

- iPhone on iOS 26
- Obsidian 1.13+ for the share target
- ~626 MB one-time model download, Wi-Fi recommended
- A free Apple ID. No paid developer account is needed.

## Installing

Personal tool, sideloaded. Grab the latest `.ipa` from
[Releases](../../releases) — on the phone, in Safari, then open it in SideStore
or AltStore. First launch downloads the model and shows its progress.

See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) for building it yourself, and
the three install gates (certificate trust, Developer Mode, microphone) that
each fail looking like one of the others.

## Status

Working and in daily use. Record, transcribe, share, delete and retention are
all real, and the performance gates have been measured on device: 24× real-time
transcription with comfortable memory headroom, nothing thermally interesting.

Not yet working: the Live Activity and the Lock Screen start/stop controls,
which need the widget extension to be signed properly.

## Documentation

- [Design doc](docs/designs/voice-capture-obsidian-ios.md) — the decisions, what
  they cost, and the premises that were wrong
- [M0 runbook](docs/M0-RUNBOOK.md) — measuring it on a real device, and the
  operational traps
- [Development](docs/DEVELOPMENT.md) — building from Windows with no Mac
