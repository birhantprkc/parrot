import AppKit
import SwiftUI

/// The first-run window (#51): explains Accessibility and Microphone before
/// macOS asks for either. Parrot.app opens it at launch while a grant is
/// missing; nothing asks until the user clicks Continue. It follows the
/// grants live, closes itself once both are on, and can be reopened from
/// the menu bar's "Grant Permissions…" until then. One instance, reused.
@MainActor
enum FirstRunWindow {
    /// How often the grants are re-read while one is missing. Accessibility
    /// has no change notification, so this polls, like `Daemon.startHotkey`.
    private static let pollInterval: TimeInterval = 1

    private static var window: NSWindow?
    private static let model = FirstRunModel()
    private static var poll: Timer?
    private static var menuItem: NSMenuItem?

    /// Opens the window if this is Parrot.app and a grant is missing, and
    /// shows the menu item that reopens it. Otherwise does nothing.
    static func startIfNeeded(menuBar: MenuBarController) {
        model.refresh()
        guard Permissions.showsFirstRunWindow(isApp: AppLaunch.isApp, state: model.state) else { return }
        Log.info("a permission is missing; showing the first-run window")
        menuItem = menuBar.grantPermissionsItem
        menuBar.grantPermissionsItem.isHidden = false
        menuBar.onGrantPermissions = { show() }
        poll = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        // Once the run loop is up, so activation brings the window forward.
        DispatchQueue.main.async { show() }
    }

    static func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // An accessory app's activation can be refused (a login-item launch
        // while the user works elsewhere); the window still comes forward.
        window.orderFrontRegardless()
    }

    private static func makeWindow() -> NSWindow {
        let hosting = NSHostingView(rootView: FirstRunView(model: model))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Parrot"
        window.center()
        return window
    }

    private static func refresh() {
        model.refresh()
        guard model.state.allGranted else { return }
        Log.info("permissions granted; closing the first-run window")
        poll?.invalidate()
        poll = nil
        menuItem?.isHidden = true
        window?.close()
        window = nil
    }
}

/// The grants the window shows, and its one action.
@MainActor
final class FirstRunModel: ObservableObject {
    @Published private(set) var state = PermissionState.current
    /// Set by Continue, to point at System Settings while a grant is still off.
    @Published private(set) var continued = false

    func refresh() {
        let now = PermissionState.current
        if now != state { state = now }
    }

    func continueClicked() {
        continued = true
        run(Permissions.continueSteps(for: state)[...])
    }

    /// Performs `steps` in order, waiting for the microphone prompt to be
    /// answered before the Accessibility steps, so the two system dialogs
    /// never stack.
    private func run(_ steps: ArraySlice<Permissions.Step>) {
        guard let step = steps.first else {
            refresh()
            return
        }
        let rest = steps.dropFirst()
        if step == .requestMicrophone {
            MicrophoneAccess.requestIfUndetermined { [weak self] in
                MainActor.assumeIsolated { self?.run(rest) }
            }
            return
        }
        Permissions.perform(step)
        run(rest)
    }

    func openMicrophoneSettings() {
        Permissions.perform(.openMicrophoneSettings)
    }
}

/// The window's content: both permissions with their reasons and live
/// state, the privacy line, and Continue.
struct FirstRunView: View {
    @ObservedObject var model: FirstRunModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parrot needs two permissions")
                        .font(.title2.weight(.semibold))
                    Text("Hold the hotkey, speak, and let go: your words appear at the cursor.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                PermissionRow(
                    symbol: "accessibility",
                    title: "Accessibility",
                    reason: "To notice when you hold the hotkey and paste your words at the cursor. macOS calls this \u{201C}controlling your computer.\u{201D}",
                    granted: model.state.accessibility
                ) {
                    if model.continued && !model.state.accessibility {
                        Text("In System Settings, turn on Parrot under Accessibility.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                PermissionRow(
                    symbol: "mic",
                    title: "Microphone",
                    reason: "To hear you while the hotkey is held.",
                    granted: model.state.microphone == .granted
                ) {
                    if model.state.microphone == .denied {
                        HStack(spacing: 6) {
                            Text("Microphone access is off.")
                                .foregroundStyle(.orange)
                            Button("Open Microphone Settings") { model.openMicrophoneSettings() }
                                .buttonStyle(.link)
                        }
                        .font(.callout)
                    }
                }
            }

            Label("Audio and text never leave your Mac.", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Continue") { model.continueClicked() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// One permission: its symbol, name and reason, a checkmark once granted,
/// and any note under the reason.
private struct PermissionRow<Note: View>: View {
    let symbol: String
    let title: String
    let reason: String
    let granted: Bool
    @ViewBuilder let note: () -> Note

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(reason)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                note()
            }
            Spacer(minLength: 8)
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.secondary.opacity(0.5))
                .accessibilityLabel(granted ? "Granted" : "Not granted")
        }
    }
}
