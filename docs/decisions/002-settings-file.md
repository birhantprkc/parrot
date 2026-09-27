# ADR-002 :: One settings file in Application Support

Last updated: `2026.09.27`

> Every persistent preference lives in one JSON file, `~/Library/Application Support/parrot/settings.json`, read into a `Codable` `Settings` value and changed only through `SettingsStore`. The settings window and hand edits write the same file, and changes apply live.

## 1. Decision

- **One file, JSON, in Application Support.** `settings.json` sits next to `dictionary.json`, `stats.json`, and `models/`. `Paths` names every location.
- **One `Codable` value.** `Settings` aggregates one struct per feature (`HotkeySettings`, `DictionarySettings`, `LanguageSettings`, `ModelSettings`, `AudioSettings`, `StatsSettings`). A missing key takes its default, and unknown keys are ignored.
- **`SettingsStore` is the only writer.** Writes are atomic. It watches the directory so hand edits apply without a restart; a file that fails to parse keeps the last good settings and logs one line.
- **CLI flags override one foreground run and are never persisted.** Launch at login carries no arguments.

## 2. Rationale

Configuration was scattered: the hotkey was hard-coded, the README advertised a `--hotkey` flag that did not exist, and the LaunchAgent's `ProgramArguments` froze whatever flags were passed at install, so a setting could silently disappear after a reboot. A file the app owns removes that class of bug.

`UserDefaults` was rejected because it is opaque to users and hard to hand-edit or back up, and because the command-line binary and the app bundle can see different defaults domains. TOML in `~/.config` was rejected because it is a non-native location for a Mac app, adds a dependency, and would split Parrot's data across two roots. Per-feature files were rejected because they make atomic changes and file watching harder for no gain.

## 3. Design Implications

- Rule: no `UserDefaults`, no plist flags, no per-feature config files.
- The dictionary is its own file (`dictionary.json`) because it is user content that grows, not a preference.
- Uninstall removes the Application Support folder along with logs and caches.
- The settings window is a view over `Settings`; it holds no state of its own.

## 4. When to Revisit

- If Parrot ships through the Mac App Store, the sandbox moves Application Support into the container and the paths change.
- If settings need to sync across Macs, a synced store would replace or mirror the file.
