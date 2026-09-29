import CoreGraphics

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
public enum HotkeyKey: String, Codable, CaseIterable, Sendable {
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

    /// The short name in the menu bar and log lines: "hold right ⌥ to dictate".
    var shortName: String {
        switch self {
        case .fn: return "fn"
        case .leftOption: return "left ⌥"
        case .rightOption: return "right ⌥"
        case .leftCommand: return "left ⌘"
        case .rightCommand: return "right ⌘"
        case .leftControl: return "left ⌃"
        case .rightControl: return "right ⌃"
        case .leftShift: return "left ⇧"
        case .rightShift: return "right ⇧"
        }
    }

    /// The virtual keycode a `flagsChanged` event carries for this key
    /// (`kVK_Function`, `kVK_Option`, `kVK_RightOption`, …).
    var keycode: Int64 {
        switch self {
        case .fn: return 63
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftShift: return 56
        case .rightShift: return 60
        }
    }

    /// The device-independent flag this key sets. Left and right share it.
    var flag: CGEventFlags {
        switch self {
        case .fn: return .maskSecondaryFn
        case .leftOption, .rightOption: return .maskAlternate
        case .leftCommand, .rightCommand: return .maskCommand
        case .leftControl, .rightControl: return .maskControl
        case .leftShift, .rightShift: return .maskShift
        }
    }
}
