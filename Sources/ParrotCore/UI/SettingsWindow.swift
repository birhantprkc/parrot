import AppKit
import SwiftUI

/// The Settings window (#41), opened from the menu bar's Settings… (⌘,).
/// One instance: opening it again brings the same window to the front, and
/// closing it leaves Parrot running.
@MainActor
final class SettingsWindow {
    private let store: SettingsStore
    private var window: NSWindow?

    init(store: SettingsStore) {
        self.store = store
    }

    func show() {
        let window = self.window ?? make()
        self.window = window
        // An accessory app is never active on its own; without this the
        // window opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Parrot Settings"
        window.contentView = NSHostingView(rootView: SettingsView(store: store))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}


/// Every setting in one scrolling form. Controls write straight through to
/// `settings.json` via `SettingsStore`, and a hand edit of the file updates
/// the controls, so the window and the file never disagree. The window holds
/// no state of its own (ADR-002).
struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Reset to Defaults") { store.write(Settings()) }
                    Spacer()
                    Button("Open Config File") {
                        store.createIfMissing()
                        NSWorkspace.shared.open(store.file)
                    }
                }
                PathLabel(url: store.file)
            }

            HotkeySection(store: store)

            TranscriptionSection(store: store)

            Section("Dictionary") {
                HStack {
                    Text("Terms, replacements and example sentences")
                    Spacer()
                    Button("Open Dictionary File") { NSWorkspace.shared.open(Paths.dictionaryFile) }
                }
                PathLabel(url: Paths.dictionaryFile)
            }

            Section("General") {
                LaunchAtLoginRow()
            }

            // Escape and ⌘W close the window: an accessory app has no menu
            // bar of its own to carry Close.
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 420, idealHeight: 560)
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
    }
}

/// A file path in small monospace, selectable so it can be copied.
struct PathLabel: View {
    let url: URL

    var body: some View {
        Text(url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }
}

/// Launch at login through `SMAppService`. Read live, since the user can
/// change it in System Settings while Parrot runs; not stored in
/// `settings.json`.
private struct LaunchAtLoginRow: View {
    @State private var isOn = LoginItem.isEnabled

    var body: some View {
        if LoginItem.isAvailable {
            Toggle("Launch at login", isOn: Binding(
                get: { isOn },
                set: { on in
                    do {
                        try LoginItem.setEnabled(on)
                    } catch {
                        Log.warning("couldn't change launch at login: \(error)")
                    }
                    isOn = LoginItem.isEnabled
                }
            ))
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                isOn = LoginItem.isEnabled
            }
        } else {
            Text("Launch at login is available when Parrot runs from Parrot.app.")
                .foregroundStyle(.secondary)
        }
    }
}
