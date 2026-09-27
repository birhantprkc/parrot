<p align="center"><img src="docs/icon.png" width="96" alt="parrot"></p>

# parrot

Hold `fn`, speak, release. Your words appear at the cursor. On-device dictation for macOS.

## 1. Install

```sh
curl -fsSL https://humanitas-labs.github.io/parrot/install.sh | sh
parrot setup
```

Requires macOS 14+ on Apple Silicon. `parrot setup` grants mic and accessibility permissions and downloads the model. Builds are unsigned, so the installer strips the quarantine attribute from `/usr/local/bin/parrot`.

## 2. Usage

1. Click into any text field.
2. Hold `fn` and speak. A small pill at the bottom of the screen shows the mic is live.
3. Release. The transcript is typed at the cursor, usually within 200–300 ms.

Run `parrot install --launch-at-login` to keep it running in the menu bar. It logs to `~/Library/Logs/parrot/`, readable only by you, and records timings and character counts, never what you said. If `fn` is mapped to input source or emoji, `parrot doctor` shows how to fix it.

## 3. CLI

| Command | What it does |
|---|---|
| `parrot` | Run in the foreground (^C to quit) |
| `parrot setup` | One-time setup: permissions and model download |
| `parrot doctor` | Check permissions and the `fn` key setting |
| `parrot install --launch-at-login` | Register a LaunchAgent |
| `parrot install --uninstall` | Remove the LaunchAgent and its logs |
| `parrot models list` | List available models |
| `parrot models download <id>` | Pre-download a model |
| `parrot --model whisper-large-v3-turbo` | Larger, multilingual model |
| `parrot --hotkey right-option` | Change the push-to-talk key |
| `parrot --no-overlay` | Hide the recording pill |

## 4. How it works

A single Swift executable: WhisperKit runs Whisper on the Apple Neural Engine via CoreML, AVAudioEngine captures the mic, a CGEventTap watches the hotkey, and CGEvent types the result at the cursor. See [docs/architecture.md](docs/architecture.md).

## 5. Build from source

```sh
swift build -c release
.build/release/parrot --help
```

## 6. License

[MIT](LICENSE)
