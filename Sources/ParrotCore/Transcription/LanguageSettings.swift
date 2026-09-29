/// Spoken-language preferences (#43).
///
/// The `settings.json` field for this feature; see `Settings`. Give each new
/// field a default and decode it in `init(from:)` with
/// `decodeIfPresent(…) ?? default`, so older files and `{}` still load.
struct LanguageSettings: Codable, Equatable {
    /// An ISO 639-1 code such as "pt", or nil for Automatic. Ignored by
    /// English-only models.
    var code: String?
    /// The languages the user speaks, as ISO 639-1 codes, most used first.
    /// Automatic trusts these at any probability. Nil until the user edits
    /// the list: the Mac's preferred languages stand in for it.
    var spoken: [String]?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        spoken = try c.decodeIfPresent([String].self, forKey: .spoken)
    }

    /// `spoken`, or the Mac's preferred languages while it is unset.
    var spokenOrPreferred: [String] {
        spoken ?? SpokenLanguage.preferredCodes()
    }
}
