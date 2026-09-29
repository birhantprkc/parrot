import Foundation
import WhisperKit

/// How a dictation's spoken language is chosen (#43). Pure, so it is tested.
///
/// - A single-language model such as `whisper-base.en` is never told a
///   language and never asked to detect one: it only knows one.
/// - An explicit Language setting is used as given, with detection off.
/// - Automatic chooses among the languages the user speaks (the Languages
///   setting, or the Mac's preferred languages until it is set), and only
///   among them: `LanguageDetector` lets no other language compete. Whisper
///   confuses close languages on short clips (Spanish heard as Italian or
///   Portuguese, #15: Serbian heard as Spanish), and a wrong language comes
///   back as a translation. With one language there is nothing to detect.
package enum SpokenLanguage {
    /// What to do before decoding.
    package enum Plan: Equatable, Sendable {
        /// Pass no language: the model has only one.
        case none
        /// Decode in this language, detection off.
        case fixed(String)
        /// Detect which of these languages is spoken. Empty when none of the
        /// user's languages is one the model knows: then every language
        /// competes, as in WhisperKit's own detection.
        case detect(among: [String])
    }

    /// The plan for `model` with the Language setting `setting` (an ISO 639-1
    /// code, or nil for Automatic) and the languages the user speaks,
    /// `spoken`. A code the model does not support, such as a typo in a hand
    /// edit, counts as Automatic.
    package static func plan(setting: String?, spoken: [String], model: TranscriptionModel) -> Plan {
        guard model.isMultilingual else { return .none }
        let supported = model.supportedLanguages
        if let code = setting?.lowercased(), supported.contains(code) {
            return .fixed(code)
        }
        var seen = Set<String>()
        let candidates = spoken.map { $0.lowercased() }.filter { supported.contains($0) && seen.insert($0).inserted }
        if candidates.count == 1 { return .fixed(candidates[0]) }
        return .detect(among: candidates)
    }

    /// Softmax over `scores` (a logit per language): each language's
    /// probability among these languages only, highest first.
    package static func probabilities(_ scores: [(String, Float)]) -> [(code: String, probability: Float)] {
        guard let top = scores.map(\.1).max() else { return [] }
        let weights = scores.map { ($0.0, exp($0.1 - top)) }
        let total = weights.reduce(0) { $0 + $1.1 }
        return weights
            .map { (code: $0.0, probability: $0.1 / total) }
            .sorted { $0.probability > $1.probability }
    }

    /// `identifiers` (as in `Locale.preferredLanguages`: "en-US", "pt-BR",
    /// "zh-Hans-CN") reduced to ISO 639-1 codes, in order, without repeats.
    package static func preferredCodes(_ identifiers: [String] = Locale.preferredLanguages) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { id -> String? in
            let language = Locale.Language(identifier: id)
            let code = language.languageCode?.identifier(.alpha2) ?? language.languageCode?.identifier
            return code?.lowercased()
        }
        .filter { seen.insert($0).inserted }
    }

    /// Every language Whisper's multilingual models know, as codes. From
    /// WhisperKit, so it follows the package.
    package static let whisperLanguages: Set<String> = Constants.languageCodes

    /// `code`'s name in the user's language, for the Language picker:
    /// "Portuguese", "Português". Falls back to Whisper's English name.
    package static func displayName(_ code: String, locale: Locale = .current) -> String {
        if let name = locale.localizedString(forLanguageCode: code), name != code {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        // Some codes have several names ("flemish", "dutch"); pick one stably.
        let whisperName = Constants.languages.filter { $0.value == code }.map(\.key).min() ?? code
        return whisperName.capitalized
    }
}

extension TranscriptionModel {
    /// True if the model hears more than one language. Registry entries say
    /// so with `languages: ["multi"]`.
    package var isMultilingual: Bool {
        languages.contains("multi") || languages.count > 1
    }

    /// The language codes the model can be told to expect.
    package var supportedLanguages: Set<String> {
        languages.contains("multi") ? SpokenLanguage.whisperLanguages : Set(languages)
    }
}
