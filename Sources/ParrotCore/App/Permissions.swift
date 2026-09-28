import AppKit
import ApplicationServices
import AVFoundation
import Foundation

/// The microphone grant as the first-run window shows it.
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

/// Reading and asking for Accessibility and Microphone (#51). The window in
/// `FirstRunWindow` explains both before any of these requests is made.
enum Permissions {
    /// One thing Continue does.
    enum Step: Equatable {
        /// `AXIsProcessTrustedWithOptions` with the prompt, which also lists
        /// Parrot in the Accessibility pane.
        case promptAccessibility
        case openAccessibilitySettings
        case requestMicrophone
        case openMicrophoneSettings
    }

    /// Whether Parrot.app opens the first-run window at launch: only while a
    /// grant is missing, so an upgrade that keeps its grants never sees it.
    /// A foreground CLI run asks the old way and shows no window.
    static func showsFirstRunWindow(isApp: Bool, state: PermissionState) -> Bool {
        isApp && !state.allGranted
    }

    /// What Continue does for `state`, in order: the Accessibility prompt and
    /// its pane, then the microphone. A denied microphone can only be turned
    /// on in System Settings; its pane opens only when Accessibility is done,
    /// so the two panes don't replace each other.
    static func continueSteps(for state: PermissionState) -> [Step] {
        var steps: [Step] = []
        if !state.accessibility {
            steps += [.promptAccessibility, .openAccessibilitySettings]
        }
        switch state.microphone {
        case .granted:
            break
        case .notDetermined:
            steps.append(.requestMicrophone)
        case .denied:
            if state.accessibility { steps.append(.openMicrophoneSettings) }
        }
        return steps
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
