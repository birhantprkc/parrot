/// Push-to-talk key preferences (#42).
///
/// The `settings.json` field for this feature; see `Settings`. Give each new
/// field a default and decode it in `init(from:)` with
/// `decodeIfPresent(…) ?? default`, so older files and `{}` still load.
struct HotkeySettings: Codable, Equatable {
    /// The modifier held to dictate. An unknown name decodes to the default.
    var key: HotkeyKey = .fn

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .key)
        key = name.flatMap(HotkeyKey.init(rawValue:)) ?? .fn
    }
}

/// The modifiers Parrot can use as its push-to-talk key (ADR-003). The raw
/// value is the name in `settings.json` and for `--hotkey`.
enum HotkeyKey: String, Codable, CaseIterable, Sendable {
    case fn
    case leftOption = "left-option"
    case rightOption = "right-option"
    case leftCommand = "left-command"
    case rightCommand = "right-command"
    case leftControl = "left-control"
    case rightControl = "right-control"
    case leftShift = "left-shift"
    case rightShift = "right-shift"

    /// How the key is named in the menu and the Settings window.
    var displayName: String {
        switch self {
        case .fn: return "fn"
        case .leftOption: return "Left Option (⌥)"
        case .rightOption: return "Right Option (⌥)"
        case .leftCommand: return "Left Command (⌘)"
        case .rightCommand: return "Right Command (⌘)"
        case .leftControl: return "Left Control (⌃)"
        case .rightControl: return "Right Control (⌃)"
        case .leftShift: return "Left Shift (⇧)"
        case .rightShift: return "Right Shift (⇧)"
        }
    }
}
