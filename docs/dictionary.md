# Dictionary

Last updated: `2026.09.27`

> Your names and technical terms, so Parrot spells them the way you do. One JSON file, edited by hand, applied on the next dictation.

The file is `~/.config/parrot/dictionary.json` (or `$XDG_CONFIG_HOME/parrot/dictionary.json`). The first run creates a small starter file. A filled-in one looks like this:

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

The example sentence is what Whisper reads as the speech just before yours, which biases it toward your spellings. Write it the way you dictate: "I need to review the pull requests before the merge" works; "I am a developer who uses technical terms" does not, and neither does a bare list of words. One sentence is enough: Whisper reads it before every dictation, so it adds time on `whisper-base.en`: about 35–40 ms for a 9-word sentence and 85–100 ms for a 19-word one. Terms and replacements cost nothing noticeable however many you add, because they rewrite the finished text and never reach the model. Parrot only uses the sentence for the language being spoken, because a sentence in the wrong language pulls the model into that language. Until Parrot has a language setting, that means the English sentence with the English-only models (the default `whisper-base.en` and `whisper-small.en`); the multilingual model gets no sentence.

Edits apply on the next dictation, with no restart. If the file has a mistake, Parrot keeps using the last version that loaded and logs the line and column of the problem to `~/Library/Logs/parrot/`. The file can live in a dotfiles repository: `~/.config/parrot`, or `dictionary.json` itself, may be a symlink, as long as the file it points to is yours.
