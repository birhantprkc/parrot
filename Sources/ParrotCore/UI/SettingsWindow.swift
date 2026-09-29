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
                    Text("Config")
                    Spacer()
                    Button("Open Config File") {
                        store.createIfMissing()
                        NSWorkspace.shared.open(store.file)
                    }
                }
                HotkeyRow(store: store)
                LaunchAtLoginRow()
                HStack {
                    Text("Reset")
                    Spacer()
                    Button("Reset to Defaults") { store.write(Settings()) }
                }
            } header: {
                VStack(alignment: .leading, spacing: 0) {
                    SettingsHeader()
                    Text("General")
                }
            }

            TranscriptionSection(store: store)
        }
        .formStyle(.grouped)
        // Escape and ⌘W close the window: an accessory app has no menu bar
        // of its own to carry Close. Behind the form, so it takes no row.
        .background {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .frame(width: 460)
        .frame(minHeight: 420, idealHeight: 560)
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
    }
}

/// The Parrot bird with the title and version centered under it. A section
/// header, so it sits on the window background rather than in a row.
private struct SettingsHeader: View {
    private static let bird: NSImage? = {
        guard let image = NSImage(data: Data(MenuBarController.birdSVG.utf8)) else { return nil }
        image.size = NSSize(width: 72, height: 72)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        VStack(spacing: 4) {
            if let bird = Self.bird {
                Image(nsImage: bird)
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .padding(.bottom, 12)
            }
            Text("Parrot · Settings")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Version \(AppBundle.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 28)
        .textCase(nil)
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
