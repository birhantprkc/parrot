/// Spoken-language preferences (#43).
///
/// The `settings.json` field for this feature; see `Settings`. Give each new
/// field a default and decode it in `init(from:)` with
/// `decodeIfPresent(…) ?? default`, so older files and `{}` still load.
struct LanguageSettings: Codable, Equatable {
    /// An ISO 639-1 code such as "pt", or nil for Automatic. Ignored by
    /// English-only models.
    var code: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decodeIfPresent(String.self, forKey: .code)
    }
}
