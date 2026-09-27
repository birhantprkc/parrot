# ADR-004 :: Local data and privacy

Last updated: `2026.09.27`

> Transcript text is never written to logs, disk, or stats. Everything Parrot keeps lives under `~/Library` with owner-only permissions: models and user data in Application Support, logs in Logs, debug captures in Caches.

## 1. Decision

- **No transcript text at rest.** Logs record timings and character counts. Stats record counts. The dictionary is the only user-authored text Parrot stores.
- **Fixed locations under `~/Library`.** `Application Support/parrot/` holds settings, dictionary, stats, and models. `Logs/parrot/` holds daemon logs. `Caches/parrot/` holds `--dump-wav` captures. `Paths` defines them all.
- **Owner-only.** Directories are 0700 and files 0600. Existing symlinks are refused, and new files are created with `O_EXCL | O_NOFOLLOW`.
- **Models are downloaded into Application Support** by passing an explicit `downloadBase` to WhisperKit.

## 2. Rationale

Up to 0.0.5 the LaunchAgent sent stderr to world-readable `/tmp/parrot.err.log`, and the daemon logged every transcript there, so anything a user dictated was readable by any local process. `--dump-wav` also wrote audio to `/tmp`.

Models went to `~/Documents/huggingface`, the swift-transformers default. That triggered a Documents permission prompt, failed under launchd (which has no Documents access) with a misleading error, let iCloud evict the weights so model loading hung, and counted 1.6 GB against the user's iCloud quota. `~/Library/Caches` was rejected for models because the system purges it under disk pressure, which would mean a surprise re-download and model recompile.

## 3. Design Implications

- Rule: every on-disk location comes from `Paths`; no other code builds a path.
- Observers and stats receive `DictationResult`, which has no text field.
- Foreground commands (`setup`, `install`, `models download`) migrate old caches; the daemon never reads `~/Documents`.
- Uninstall removes all three folders.

## 4. When to Revisit

- If Parrot adds transcript history as a feature, it needs an explicit opt-in, a stated location, and its own ADR.
- If the app becomes sandboxed, the locations move into the container.
