# ADR-001 :: Core library and extension points

Last updated: `2026.09.27`

> All behaviour lives in a `ParrotCore` library behind a thin `parrot` executable, and features attach to the dictation loop at named extension points instead of editing it. This keeps the loop small, makes the logic testable, and lets several contributors or agents work on features at once without colliding.

## 1. Decision

- **Three targets.** `ParrotCore` (library) holds every behaviour. `parrot` (executable) parses ArgumentParser commands and calls into it. `ParrotTests` tests `ParrotCore`.
- **The core does not depend on ArgumentParser.** Command bodies signal "message printed, exit with this code" by throwing `SilentExit`; `main.swift` maps it to an exit code.
- **`DictationController` owns only the loop.** It holds the `idle`, `recording`, `transcribing` state machine, runs the transcriber off the main actor, and calls the extension points in order.
- **Features plug in at extension points.** Input to the model goes through `TranscriptionContext`. Changes to the text go through a `TranscriptProcessor`. Reactions to a dictation (overlay, menu bar, stats, latency) are a `DictationObserver`. User-visible failures are a `UserFacingError`. Preferences are a per-feature struct inside `Settings`.
- **Shared types are extended, not reshaped.** Adding a field, case, or callback is routine; renaming or restructuring a shared type is its own change.

## 2. Rationale

Before this, one `Run.run()` of about 230 lines wired capture, transcription, injection, overlay, and menu bar together with closures. Every feature on the roadmap (dictionary, language, stats, delivery rules) would have added branches to it, and 26 community PRs showed what that produces: overlapping edits to the same lines.

Keeping a single executable target was rejected because Swift cannot test an executable target's internals, and the pure logic (replacement pass, settings decoding, gesture filtering) is exactly what needs tests. A plugin system with dynamic registration was rejected as more machinery than a single-process app with a handful of features needs; the extension points are plain protocols wired in `Daemon`.

The cost is some indirection: a feature author has to find the right extension point rather than adding code where the behaviour happens. `docs/architecture.md` lists the points to make that cheap.

## 3. Design Implications

- New behaviour after transcription is a `TranscriptProcessor` or a `DictationObserver`, never a branch in `DictationController`.
- Observers receive counts and timings in `DictationResult`, never transcript text.
- Anything worth testing lives in `ParrotCore`; `main.swift` stays declarative.
- Features that need persisted preferences add a struct in their own folder and a field in `Settings`, rather than reading their own files.

## 4. When to Revisit

- If Parrot splits into more than one process (for example an XPC helper for transcription), the controller and observer boundaries should be redrawn around the process boundary.
- If processors need to be asynchronous (for example an on-device language-model correction pass), `TranscriptProcessor` needs an async variant.
