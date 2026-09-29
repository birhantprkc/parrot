import Foundation
import WhisperKit

/// How a dictation's spoken language is chosen (#43). Pure, so it is tested.
///
/// - A single-language model such as `whisper-base.en` is never told a
///   language and never asked to detect one: it only knows one.
/// - An explicit Language setting is used as given, with detection off.
/// - Automatic detects the language, then trusts it by the user's macOS
///   preferred languages: one in that list is trusted at any probability, so
///   a bilingual user can alternate between dictations; one outside it only
///   at `foreignThreshold` or above. Short clips are where Whisper's
///   detection is least reliable (#15: Serbian heard as Spanish, English as
///   Portuguese), and a wrong language comes back as a translation.
package enum SpokenLanguage {
    /// Probability a detected language outside the preferred languages needs
    /// before it is used. Below it, the first preferred language the model
    /// supports is used instead. 0.8 rejected real Spanish at 0.62 and 0.72
    /// on whisper-small and translated it into English, while English
    /// detected at 0.99 or above; someone who speaks a language most of the
    /// time can add it to their preferred languages.
    package static let foreignThreshold: Float = 0.7

    /// What to do before decoding.
    package enum Plan: Equatable, Sendable {
        /// Pass no language: the model has only one.
        case none
        /// Decode in this language, detection off.
        case fixed(String)
        /// Detect, then `resolve`.
        case detect
    }

    /// The plan for `model` with the Language setting `setting` (an ISO 639-1
    /// code, or nil for Automatic). A code the model does not support, such
    /// as a typo in a hand edit, counts as Automatic.
    package static func plan(setting: String?, model: TranscriptionModel) -> Plan {
        guard model.isMultilingual else { return .none }
        if let code = setting?.lowercased(), model.supportedLanguages.contains(code) {
            return .fixed(code)
        }
        return .detect
    }

    /// The language to decode in after detection heard `detected` with
    /// `probability` (0 to 1). `preferred` is the user's preferred languages
    /// as ISO 639-1 codes, most preferred first.
    package static func resolve(
        detected: String,
        probability: Float,
        preferred: [String],
        supported: Set<String>
    ) -> String {
        if preferred.contains(detected) || probability >= foreignThreshold {
            return detected
        }
        // No preferred language the model knows: detection is all there is.
        return preferred.first(where: supported.contains) ?? detected
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
