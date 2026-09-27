<p align="center"><img src="docs/icon.png" width="96" alt="parrot"></p>

# parrot

Hold `fn`, speak, release. Your words appear at the cursor. On-device dictation for macOS.

## 1. Install

Download [Parrot.dmg](https://github.com/humanitas-labs/parrot/releases/latest/download/Parrot.dmg), open it, and drag Parrot to Applications. Open Parrot from Applications. It asks for Accessibility first: turn on Parrot in System Settings → Privacy & Security → Accessibility, then open Parrot again and allow the microphone. The first start downloads the speech model (about 150 MB) before the parrot icon appears in the menu bar. Choose **Launch at login** in its menu to start it with your Mac.

Requires macOS 14+ on Apple Silicon. Parrot is signed and notarized, so it opens without a Gatekeeper override, and the permissions you grant survive updates.

From a terminal instead:

```sh
curl -fsSL https://humanitas-labs.github.io/parrot/install.sh | sh
```

The installer checks the download against its published SHA-256, copies Parrot.app to `/Applications`, links `/usr/local/bin/parrot` to it, and opens it. To add the `parrot` command after installing from the DMG, run `/Applications/Parrot.app/Contents/MacOS/parrot install --cli`.

**Upgrading from the command-line version.** Open the new Parrot once. It stops and removes the old LaunchAgent (`com.digimata.parrot`), keeps launch at login on if you had it, and asks before replacing the old `/usr/local/bin/parrot` binary with a link to the app. Your models, settings, and logs stay where they are. macOS asks for Microphone and Accessibility again, this time for Parrot instead of your terminal; you can remove the old `parrot` and terminal entries from those lists.

## 2. Usage

1. Click into any text field.
2. Hold `fn` and speak. A small pill at the bottom of the screen shows the mic is live.
3. Release. The transcript is pasted at the cursor, usually within 200–300 ms, and your clipboard is put back as it was.

If you switch apps or fields before the transcript is ready, it goes to the clipboard instead. If a password field has focus, the transcript is discarded.

Choose **Launch at login** in the menu, or run `parrot install --launch-at-login`, to start Parrot when you log in. It logs to `~/Library/Logs/parrot/`, readable only by you, and records timings and character counts, never what you said. If `fn` is mapped to input source or emoji, `parrot doctor` shows how to fix it.

## 3. Dictionary

Parrot keeps your names and technical terms in `~/.config/parrot/dictionary.json` (or `$XDG_CONFIG_HOME/parrot/dictionary.json`). The first run creates a small starter file. A filled-in one looks like this:

```json
{
  "terms": ["PostHog", "WhisperKit"],
  "replacements": [
    { "from": ["post hog", "posthug"], "to": "PostHog" }
  ],
  "examples": {
    "en": "I pushed the WhisperKit fix and checked the PostHog dashboard before the review."
  }
}
```

Every key is optional, and keys Parrot does not know are ignored.

| Key | What it does |
|---|---|
| `terms` | Canonical spellings. A term written in any casing is rewritten to yours: `posthog` becomes `PostHog`. |
| `replacements` | What the model writes, mapped to what you meant. Each `from` is rewritten to `to`. Use it for words the model splits or mishears. |
| `examples` | One natural sentence per language, keyed by language code (`en`, `pt-BR`), that uses your words the way you say them. |

Terms and replacements run on every transcript. They match whole words only (`api` never changes `rapid`), ignore case, and work in any script. When two entries match at the same place, the longer one wins. Each word is rewritten at most once, so one entry's output never feeds another, and `to` is inserted exactly as written. A `from` in `replacements` takes precedence over the same word in `terms`.

The example sentence is what Whisper reads as the speech just before yours, which biases it toward your spellings. Write it the way you dictate: "I need to review the pull requests before the merge" works; "I am a developer who uses technical terms" does not, and neither does a bare list of words. One sentence is enough: Whisper reads it before every dictation, so it adds time (about 50 ms for a short sentence on `whisper-base.en`), and a longer one adds more. Parrot only uses the sentence for the language being spoken, because a sentence in the wrong language pulls the model into that language. Until Parrot has a language setting, that means the English sentence with the English-only models (the default `whisper-base.en` and `whisper-small.en`); the multilingual model gets no sentence.

Edits apply on the next dictation, with no restart. If the file has a mistake, Parrot keeps using the last version that loaded and logs the line and column of the problem to `~/Library/Logs/parrot/`. The file can live in a dotfiles repository: `~/.config/parrot`, or `dictionary.json` itself, may be a symlink, as long as the file it points to is yours.

## 4. CLI

| Command | What it does |
|---|---|
| `parrot` | Run in the foreground (^C to quit) |
| `parrot setup` | One-time setup: permissions and model download |
| `parrot doctor` | Check permissions and the `fn` key setting |
| `parrot install --launch-at-login` | Start Parrot.app at login (a login item) |
| `parrot install --cli` | Link `/usr/local/bin/parrot` to Parrot.app |
| `parrot install --uninstall` | Stop launching at login, quit Parrot, remove its logs |
| `parrot models list` | List available models |
| `parrot models download <id>` | Pre-download a model |
| `parrot --model whisper-large-v3-turbo` | Larger, multilingual model |
| `parrot --hotkey right-option` | Change the push-to-talk key |
| `parrot --no-overlay` | Hide the recording pill |
| `parrot --inject-mode type-unicode` | Type the text as key events instead of pasting; leaves the clipboard alone, but terminals and Electron apps ignore it |

## 5. How it works

A single Swift executable: WhisperKit runs Whisper on the Apple Neural Engine via CoreML, AVAudioEngine captures the mic, a CGEventTap watches the hotkey, and a synthesized ⌘V pastes the result at the cursor. See [docs/architecture.md](docs/architecture.md).

## 6. Build from source

```sh
swift build -c release
.build/release/parrot --help
swift test
scripts/dev-install.sh      # build, sign, and install Parrot.app, and link the CLI
scripts/make-dmg.sh 0.1.0   # signed, notarized DMG in dist/
```

`dev-install.sh` signs with a Developer ID certificate from your keychain so macOS keeps the permission grants across rebuilds. Without one it signs ad hoc, and each build asks again.

## 7. License

[MIT](LICENSE)
