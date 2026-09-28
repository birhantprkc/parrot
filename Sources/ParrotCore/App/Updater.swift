import AppKit
import Foundation
import Sparkle

/// In-app updates through Sparkle (#50), in the app role only.
///
/// Sparkle reads its configuration from Info.plist: `SUFeedURL` (the
/// appcast published with each release), `SUPublicEDKey` (updates must be
/// signed with the matching private key), and a daily automatic check. An
/// update replaces Parrot.app in place and relaunches it; the Developer ID
/// identity does not change, so the Microphone and Accessibility grants
/// carry over (ADR-005). The `parrot` CLI is a symlink into the bundle, so
/// it updates with the app.
@MainActor
public enum Updater {
    private static var controller: SPUStandardUpdaterController?
    private static let reminders = UpdateReminders()

    /// True once Sparkle started. The menu shows "Check for Updates…" only then.
    static var isRunning: Bool { controller != nil }

    /// Starts Sparkle's scheduled checks. Does nothing, with one log line,
    /// when the bundle can't update itself: a development build, or no
    /// real signing key yet.
    static func start(bundle: Bundle = .main) {
        guard controller == nil else { return }
        if let problem = configurationProblem(info: bundle.infoDictionary ?? [:]) {
            Log.info("updates off: \(problem)")
            return
        }
        // Started by hand rather than by the controller, which reports a
        // failed start in a modal alert; a log line is enough here.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: reminders
        )
        do {
            try controller.updater.start()
        } catch {
            Log.warning("updates off: Sparkle didn't start: \(error.localizedDescription)")
            return
        }
        self.controller = controller
        Log.info("updates on: checking \(controller.updater.feedURL?.absoluteString ?? "?") every \(Int(controller.updater.updateCheckInterval / 3600))h")
    }

    /// "Check for Updates…" from the menu.
    static func checkForUpdates() {
        guard let controller else { return }
        // An accessory app is never frontmost; without this the update
        // window can open behind the app the user is in.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    /// Why this bundle can't update itself, or nil if it can. A development
    /// build (`git describe` versions such as `0.0.6-3-gabc1234-dirty`) must
    /// not replace itself with a release, and a bundle still carrying the
    /// placeholder key would fail every check.
    nonisolated static func configurationProblem(info: [String: Any]) -> String? {
        let version = info["CFBundleVersion"] as? String ?? ""
        let isRelease = !version.isEmpty
            && version.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
        guard isRelease else { return "development build \(version.isEmpty ? "without a version" : version)" }

        guard let feed = info["SUFeedURL"] as? String, URL(string: feed)?.scheme != nil else {
            return "no SUFeedURL"
        }
        // An Ed25519 public key is 32 bytes, base64-encoded.
        guard let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32 else {
            return "SUPublicEDKey is not set to a real key"
        }
        return nil
    }
}

/// Parrot has no Dock icon and is never frontmost, so a scheduled check
/// that finds an update brings its window forward instead of leaving it
/// behind the app in use. Declaring gentle-reminder support also stops
/// Sparkle warning that a background app might miss the alert. Sparkle
/// calls its delegates on the main thread only.
@MainActor
private final class UpdateReminders: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}
