import Foundation

/// Fills a dictation's `TranscriptionContext` from the dictionary: the example
/// sentence for the active language as the prompt, and the canonical spellings
/// as the vocabulary.
struct DictionaryContext {
    let store: DictionaryStore
    /// The language being spoken, when known. No prompt is given without it.
    let language: String?

    func context() -> TranscriptionContext {
        let dictionary = store.current().dictionary
        return TranscriptionContext(
            language: language,
            prompt: dictionary.example(for: language),
            vocabulary: dictionary.vocabulary
        )
    }

    /// The language a model will hear, when that is certain without a
    /// setting: a single-language model such as `whisper-base.en`. Nil for
    /// multilingual models, so they get no example sentence: one in the wrong
    /// language drags the decoder into it (#23). The language setting (#43)
    /// replaces this.
    static func knownLanguage(of model: TranscriptionModel) -> String? {
        guard model.languages.count == 1, let only = model.languages.first, only != "multi" else { return nil }
        return only
    }
}
