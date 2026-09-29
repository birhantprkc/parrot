import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// The microphone grant as the onboarding window shows it.
enum MicrophonePermission: Equatable {
    case granted
    /// The system has never asked; a request shows its prompt.
    case notDetermined
    /// Denied or restricted: only System Settings can change it.
    case denied

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .granted
        case .notDetermined: self = .notDetermined
        case .denied, .restricted: self = .denied
        @unknown default: self = .denied
        }
    }
}

/// Both grants Parrot needs, read at one moment.
struct PermissionState: Equatable {
    var accessibility: Bool
    var microphone: MicrophonePermission

    var allGranted: Bool { accessibility && microphone == .granted }

    /// This process's grants now.
    static var current: PermissionState {
        PermissionState(accessibility: AXIsProcessTrusted(), microphone: MicrophonePermission(MicrophoneAccess.status))
    }
}

/// Reading and asking for Accessibility and Microphone (#51). The onboarding
/// window explains both before any of these requests is made.
enum Permissions {
    /// One thing an Allow button does.
    enum Step: Equatable {
        /// `AXIsProcessTrustedWithOptions` with the prompt, which also lists
        /// Parrot in the Accessibility pane.
        case promptAccessibility
        case openAccessibilitySettings
        case requestMicrophone
        case openMicrophoneSettings
    }

    /// The two grants, each with its own Allow button in the onboarding
    /// window, so macOS never shows both prompts at once.
    enum Kind: Equatable {
        case microphone
        case accessibility
    }

    /// What Allow does for `kind` in `state`: the microphone prompt while
    /// the system has never asked, its System Settings pane once denied;
    /// the Accessibility prompt and its pane, so the user ends up where the
    /// switch is. Nothing once granted.
    static func allowSteps(for kind: Kind, in state: PermissionState) -> [Step] {
        switch kind {
        case .microphone:
            switch state.microphone {
            case .granted: return []
            case .notDetermined: return [.requestMicrophone]
            case .denied: return [.openMicrophoneSettings]
            }
        case .accessibility:
            return state.accessibility ? [] : [.promptAccessibility, .openAccessibilitySettings]
        }
    }

    static func perform(_ step: Step) {
        switch step {
        case .promptAccessibility:
            Log.info("asking for accessibility")
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .openAccessibilitySettings:
            openSettings(pane: "Privacy_Accessibility")
        case .requestMicrophone:
            MicrophoneAccess.requestIfUndetermined()
        case .openMicrophoneSettings:
            openSettings(pane: "Privacy_Microphone")
        }
    }

    /// Opens System Settings → Privacy & Security at `pane`.
    static func openSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
