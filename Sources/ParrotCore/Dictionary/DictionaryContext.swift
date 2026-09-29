import Foundation

/// Fills a dictation's `TranscriptionContext` from the dictionary: the example
/// sentence for the active language as the prompt, and the canonical spellings
/// as the vocabulary. In Automatic the language is unknown until the engine
/// hears it, so every example sentence goes along and the engine picks the one
/// for the language it settled on.
package struct DictionaryContext {
    let store: DictionaryStore
    /// The language being spoken, when known. Without it the prompt is left
    /// to the engine, from `examples`.
    let language: String?

    package init(store: DictionaryStore, language: String?) {
        self.store = store
        self.language = language
    }

    package func context() -> TranscriptionContext {
        let dictionary = store.current().dictionary
        return TranscriptionContext(
            language: language,
            prompt: dictionary.example(for: language),
            vocabulary: dictionary.vocabulary,
            examples: language == nil ? dictionary.examples : [:]
        )
    }

    /// The language a model will hear, when that is certain without a
    /// setting: a single-language model such as `whisper-base.en`. Nil for
    /// multilingual models, whose language comes from the Language setting or
    /// detection: an example sentence in the wrong language drags the decoder
    /// into it (#23).
    package static func knownLanguage(of model: TranscriptionModel) -> String? {
        guard model.languages.count == 1, let only = model.languages.first, only != "multi" else { return nil }
        return only
    }

    /// The language `model` will be told to expect: its only language, or
    /// the Language setting `setting` if the model supports it. Nil for
    /// Automatic.
    package static func language(of model: TranscriptionModel, setting: String?) -> String? {
        if let only = knownLanguage(of: model) { return only }
        if case .fixed(let code) = SpokenLanguage.plan(setting: setting, model: model) { return code }
        return nil
    }
}
