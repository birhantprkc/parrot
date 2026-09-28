<p align="center"><img src="docs/icon.png" width="96" alt="parrot"></p>

# parrot

Hold `fn`, speak, release. Your words appear at the cursor. On-device dictation for macOS.

## 1. Install

Download [Parrot.dmg](https://github.com/humanitas-labs/parrot/releases/latest/download/Parrot.dmg), drag Parrot to Applications, and open it. Turn on Parrot when macOS asks for Accessibility and the microphone. The first start downloads the speech model (about 150 MB).

Or from a terminal, which also installs the `parrot` command:

```sh
curl -fsSL https://humanitas-labs.github.io/parrot/install.sh | sh
```

Requires macOS 14+ on Apple Silicon. Parrot is signed and notarized, so permissions survive updates, and it updates itself: it checks once a day, and **Check for Updates…** in its menu checks now. Upgrading from the command-line version: open the new app once and it replaces the old install.

## 2. Usage

1. Click into any text field.
2. Hold `fn` and speak. A small pill at the bottom of the screen shows the mic is live.
3. Release. The transcript is pasted at the cursor, usually within 200–300 ms, and your clipboard is restored.

Choose **Launch at login** in the menu to start Parrot with your Mac. If `fn` is mapped to input source or emoji, `parrot doctor` shows how to fix it.

## 3. Dictionary

Add your names and technical terms to `~/.config/parrot/dictionary.json`, and Parrot spells them your way. Edits apply on the next dictation. See [docs/dictionary.md](docs/dictionary.md).

## 4. CLI

| Command | What it does |
|---|---|
| `parrot` | Run in the foreground (^C to quit) |
| `parrot setup` | One-time setup: permissions and model download |
| `parrot doctor` | Check permissions and the `fn` key setting |
| `parrot install --launch-at-login` | Start Parrot at login |
| `parrot install --cli` | Link `/usr/local/bin/parrot` to Parrot.app |
| `parrot install --uninstall` | Stop launching at login and remove logs |
| `parrot models list` | List available models |
| `parrot --model whisper-large-v3-turbo` | Larger, multilingual model |
| `parrot --no-overlay` | Hide the recording pill |
| `parrot --inject-mode type-unicode` | Type instead of paste (leaves the clipboard alone) |

## 5. How it works

WhisperKit runs Whisper on the Apple Neural Engine via CoreML, AVAudioEngine captures the mic, a CGEventTap watches the hotkey, and a synthesized ⌘V pastes the result. Nothing leaves your Mac, and logs never contain what you said. See [docs/architecture.md](docs/architecture.md).

## 6. Build from source

```sh
swift build -c release && swift test
scripts/dev-install.sh      # build, sign, install Parrot.app, link the CLI
```

## 7. License

[MIT](LICENSE)
