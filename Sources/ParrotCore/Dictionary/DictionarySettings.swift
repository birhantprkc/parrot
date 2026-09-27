/// Custom dictionary preferences (#33). The terms themselves live in `Paths.dictionaryFile`. Empty until that feature lands.
///
/// The `settings.json` field for this feature; see `Settings`. Give each new
/// field a default and decode it in `init(from:)` with
/// `decodeIfPresent(…) ?? default`, so older files and `{}` still load.
struct DictionarySettings: Codable, Equatable {
    init() {}

    init(from decoder: Decoder) throws {}
}
