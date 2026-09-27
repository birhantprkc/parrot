# Architecture

Last updated: `2026.09.27`

> This document is the target structure. Contributors and agents working on an issue read it first: it says where each kind of change belongs, so parallel work composes instead of colliding.

Parrot is a macOS menu-bar dictation app. Hold a key, speak, release, and the transcript appears at the cursor. Everything runs on the Mac: audio and text never leave it.

## Contents

1. [Goals and non-goals](#1-goals-and-non-goals)
   - [1.1 — Goals](#11--goals)
   - [1.2 — Non-goals](#12--non-goals)
2. [Targets](#2-targets)
3. [Layout](#3-layout)
4. [The dictation loop](#4-the-dictation-loop)
   - [4.1 — Flow](#41--flow)
   - [4.2 — Extension points](#42--extension-points)
5. [Settings](#5-settings)
6. [Files on disk](#6-files-on-disk)
7. [Startup and failure](#7-startup-and-failure)
8. [Rules](#8-rules)
9. [Permissions](#9-permissions)
10. [Issue map](#10-issue-map)

## 1. Goals and non-goals

### 1.1 — Goals

1. **Push-to-talk dictation into any app.** Hold a hotkey, speak, release, and the text lands in the focused field.
2. **On-device.** No network calls for transcription. Audio never leaves the machine.
3. **Minimal surface.** A menu-bar item, a small recording pill, and one settings window. No dock icon, no main window.
4. **Your words.** A custom dictionary biases the model toward the names and terms you use, and fixes what it still gets wrong.
5. **Trustworthy by construction.** Transcript text is never written to logs or disk. The app is signed and notarized, so permissions survive updates.
6. **Pluggable engines.** Whisper (WhisperKit) today, Parakeet and Apple SpeechAnalyzer behind the same protocol.

### 1.2 — Non-goals

- Cross-platform. Parrot depends on CoreML and the Apple Neural Engine.
- Cloud transcription providers.
- Transcript history or search. Stats keep counts only.
- Meeting recording and diarization. They may come later as a separate mode.

## 2. Targets

```
Package.swift
  ParrotCore      library     all behaviour: capture, hotkey, transcription, pipeline, settings, UI
  parrot          executable  thin entry point: ArgumentParser commands that call into ParrotCore
  ParrotTests     tests       unit tests against ParrotCore
```

`Parrot.app` wraps the `parrot` executable in a signed bundle (#40). The same binary runs as the app (launched by `SMAppService` or from Finder) and as the CLI (through a symlink). Launching with no subcommand runs the dictation loop.

The executable holds no logic beyond parsing flags and calling ParrotCore. Anything worth testing lives in ParrotCore.

## 3. Layout

```
Sources/ParrotCore/
  App/
    DictationController.swift   the dictation loop: gesture → capture → transcribe → process → deliver
    DictationObserver.swift     observer protocol and DictationResult (counts and timings, never text)
    Startup.swift               startup checks and StartupFailure (permanent vs transient)
    Daemon.swift                the `run` command: startup, wiring, run loop
    Setup.swift, Doctor.swift, LaunchAgent.swift, ModelCommands.swift
                                bodies of the other commands
  Support/
    Paths.swift                 every on-disk location Parrot uses
    Log.swift                   stderr logging; never logs transcript text
    SilentExit.swift            "message printed, exit with this code", so ParrotCore needs no ArgumentParser
  Settings/
    Settings.swift              Codable settings value with defaults
    SettingsStore.swift         load, atomic save, file watching, change publishing
  Input/
    HotkeyMonitor.swift         CGEventTap for modifier changes only
    Gesture.swift               press/release filtering: short-tap discard, chord cancel (pure, tested)
    FocusSnapshot.swift         what was focused, whether it is editable or secure
    TextInjector.swift          delivery into the focused field (paste or typed Unicode)
  Audio/
    AudioCapture.swift          capture engine, device selection, format conversion
  Transcription/
    Transcriber.swift           protocol and TranscriptionContext
    WhisperKitTranscriber.swift
    ModelRegistry.swift, TranscriptionModel.swift, ModelStore.swift
  Pipeline/
    Transcript.swift            the value that flows through processing
    TranscriptProcessor.swift   protocol for post-transcription steps
  Dictionary/
    Dictionary.swift            the user's terms, replacements, and example sentences
    DictionaryProcessor.swift   the replacement pass
  Stats/
    StatsRecorder.swift         counts only, as a DictationObserver
  UI/
    MenuBarController.swift
    RecordingOverlay.swift
    SettingsWindow.swift        window shell and section slots
    Sections/                   one view per settings section

Sources/parrot/
  main.swift                    ArgumentParser commands: run, setup, doctor, models, install

Tests/ParrotTests/
```

Files that do not exist yet are created by the issue that needs them. The layout says where they go.

## 4. The dictation loop

### 4.1 — Flow

```
HotkeyMonitor ──flags──▶ Gesture ──start/stop──▶ DictationController
                                                     │
                                  start: FocusSnapshot + AudioCapture.start
                                  stop:  AudioCapture.stop → [Float]
                                                     │
                                                     ▼
                              Transcriber.transcribe(audio, context)
                                  context = language + prompt (from Dictionary)
                                                     │ Transcript
                                                     ▼
                              [TranscriptProcessor] in order
                                  DictionaryProcessor, later others
                                                     │ Transcript
                                                     ▼
                              delivery: TextInjector if focus is unchanged and editable,
                                        otherwise nothing is inserted
                                                     │
                                                     ▼
                              DictationObservers: overlay, menu bar, stats
```

`DictationController` owns the state machine (`idle`, `recording`, `transcribing`) and nothing else. It is `@MainActor`. Transcription runs off the main actor; the controller awaits it.

### 4.2 — Extension points

Features plug in at one of these points. They do not add branches to `DictationController`.

| Point | Shape | Used by |
|---|---|---|
| `TranscriptionContext` | value passed to `transcribe`: language, prompt text | dictionary prompting (#33), language (#43) |
| `TranscriptProcessor` | `func process(_ transcript: Transcript) -> Transcript`, synchronous, pure where possible | dictionary replacements (#33); future cleanup passes |
| Delivery decision | chooses injector or fallback from the `FocusSnapshot` and the result | secure fields and focus drift (#38) |
| `DictationObserver` | `dictationStarted`, `dictationTranscribing`, `dictationFinished(DictationResult)`, `dictationFailed`; each has an empty default | overlay, menu bar, stats (#46), latency (#49) |
| `Settings` sections | a field in `Settings` plus a view in `UI/Sections/` | hotkey (#42), model (#1), language (#43), dictionary editor (#33), input device (#44), stats (#46) |

## 5. Settings

One file: `~/Library/Application Support/parrot/settings.json`, a `Codable` `Settings` value. A missing key takes its default. Writes are atomic. `SettingsStore` watches the directory, so hand edits apply live, and a file that fails to parse keeps the last good settings and logs one line.

Subsystems observe the settings they care about and reconfigure themselves. Launch at login carries no settings. CLI flags override a single foreground run and are never persisted.

## 6. Files on disk

Every location comes from `Paths`. No other code builds a path.

| Location | Contents |
|---|---|
| `~/Library/Application Support/parrot/` | `settings.json`, `dictionary.json`, `stats.json`, `models/` |
| `~/Library/Logs/parrot/` | daemon logs, owner-only; timings and lengths, never transcript text |
| `~/Library/Caches/parrot/` | `--dump-wav` debug captures, owner-only |

Uninstall removes all three.

## 7. Startup and failure

`Startup` runs its checks before loading a model: Accessibility, microphone authorization, and the selected model id. Each failure is a `StartupFailure` with `isPermanent`: missing Accessibility, denied microphone, an unknown model, and no registered models are permanent; failed checks, warmup, and an unavailable hotkey are not. A permanent failure prints one actionable message and exits 0, so launchd does not relaunch into it. A crash or transient failure exits nonzero. This rule lives in one place, `Run` in `main.swift` (#36).

## 8. Rules

1. Never write transcript text to logs, disk, or stats. The dictionary is the only user-authored text Parrot stores.
2. Every on-disk location comes from `Paths`.
3. Every persistent preference lives in `Settings` and changes through `SettingsStore`. No `UserDefaults`, no plist flags.
4. New behaviour after transcription is a `TranscriptProcessor` or a `DictationObserver`, not an edit to `DictationController`.
5. Pure logic (gesture recognition, replacement pass, settings decoding, stats aggregation) has unit tests in `ParrotTests`.
6. The event tap listens to `flagsChanged` only.
7. Shared types are extended, not reshaped. A feature adds its settings to its own `…Settings` struct in its own folder, fills existing fields of `TranscriptionContext`, and uses existing `StartupFailure` cases. Adding a field or case to a shared type is fine; renaming or restructuring one needs its own change.

## 9. Permissions

Parrot needs Microphone and Accessibility. macOS keys both grants to the app's code identity. With a Developer ID signature and a stable bundle identifier, grants survive updates. With an ad-hoc signature, each new build is a new identity, and the grant silently stops applying. That is why the signed bundle (#40) matters, and why `scripts/dev-install.sh` signs local builds with the Developer ID certificate.

`parrot setup` is the only command that shows the permission prompts. The running app checks without prompting (#36).

## 10. Issue map

| Area | Issues |
|---|---|
| `Support/`, `App/Startup.swift`, logging | #34, #35, #36 |
| `Input/` | #37, #38, #42 |
| `Audio/` | #39, #44 |
| `Transcription/` | #1, #43, #49 |
| `Dictionary/`, `Pipeline/` | #33 |
| `Settings/`, `UI/SettingsWindow.swift` | #41 |
| `Stats/` | #46 |
| Bundle, signing, `SMAppService`, release | #40 |
