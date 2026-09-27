# ADR-003 :: Push-to-talk on a single modifier key

Last updated: `2026.09.27`

> Parrot has one interaction: hold a modifier key, speak, release. The key is configurable among fn and the left or right Option, Command, Control, and Shift keys. The event tap listens to modifier changes only, so Parrot never sees what the user types.

## 1. Decision

- **Push-to-talk only.** Recording starts on key-down and ends on key-up. There is no toggle mode and no double-tap latch.
- **The hotkey is a single modifier.** Choices are fn (default) and the left or right Option, Command, Control, and Shift keys, matched by keycode so left and right are distinct.
- **The event tap is `flagsChanged`-only and listen-only.** It never subscribes to key-down or key-up events and never swallows events.
- **Shortcuts on the hotkey do not produce text.** A capture shorter than 0.3 s is discarded without transcribing, and a recording is cancelled if another modifier changes while the hotkey is held.

## 2. Rationale

A tap that sees key-down events sees every keystroke, including passwords; that is keylogger surface Parrot does not need. A modifier-only tap cannot see the C in ⌘C, which is why side-specific shortcuts are handled with the short-capture and chord rules rather than by inspecting keys.

Toggle and latch modes were proposed in several PRs. They were rejected to keep one interaction that is predictable, starts instantly, and cannot be left recording by accident; they also need a length cap and recovery for a missed release, which push-to-talk avoids. Non-modifier keys and chords were rejected because a listen-only tap cannot stop them from also reaching the focused app.

Fn stays the default because it is otherwise unused on Apple keyboards, but it never reaches macOS on many third-party keyboards and the macOS 27 beta stops delivering it to taps, so a configurable key is required.

## 3. Design Implications

- Rule: the event tap mask is `flagsChanged` only, including in debug modes.
- Gesture logic (short-capture discard, chord cancel) is a small pure type with tests, separate from audio and UI.
- Focus-drift detection happens at delivery time through Accessibility, never by widening the tap.

## 4. When to Revisit

- If users need hands-free dictation (for long-form writing or accessibility), a toggle mode with a length cap would reopen this.
- If macOS offers a supported global-shortcut API that can consume a key without an event tap.
