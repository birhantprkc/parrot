import AppKit
import SwiftUI

/// The onboarding window (#51): one page with the hotkey, the languages the
/// user speaks, and both permissions, each with its own Allow button, so
/// macOS never asks before the window has said why. Parrot.app opens it at
/// launch until the user has been through it once (Get Started or closing
/// it), and afterwards while a grant is missing. "Grant Permissions…" in the
/// menu bar reopens it while one is. One instance, reused.
@MainActor
enum OnboardingWindow {
    /// How often the grants are re-read. Accessibility has no change
    /// notification, so this polls, like `Daemon.startHotkey`.
    private static let pollInterval: TimeInterval = 1

    private static var store: SettingsStore?
    private static var menuBar: MenuBarController?
    private static var window: NSWindow?
    private static var model: OnboardingModel?
    private static var poll: Timer?
    private static let delegate = Delegate()

    /// Opens the window if this is Parrot.app and `Onboarding.showsWindow`
    /// says so, and keeps "Grant Permissions…" shown while a grant is
    /// missing. Does nothing in a foreground CLI run.
    static func startIfNeeded(store: SettingsStore, menuBar: MenuBarController) {
        guard AppLaunch.isApp else { return }
        self.store = store
        self.menuBar = menuBar
        menuBar.onGrantPermissions = { show() }
        refresh()
        guard Onboarding.showsWindow(
            isApp: true,
            completed: store.current.onboarding.completed,
            state: PermissionState.current
        ) else { return }
        Log.info("showing the onboarding window")
        // Once the run loop is up, so activation brings the window forward.
        DispatchQueue.main.async { show() }
    }

    static func show() {
        guard let store else { return }
        let window = self.window ?? makeWindow(store: store)
        self.window = window
        startPolling()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // An accessory app's activation can be refused (a login-item launch
        // while the user works elsewhere); the window still comes forward.
        window.orderFrontRegardless()
    }

    private static func makeWindow(store: SettingsStore) -> NSWindow {
        let model = OnboardingModel(settings: store.current)
        model.onGetStarted = { [weak store] in
            guard let store else { return }
            store.write(Onboarding.apply(
                hotkey: model.hotkey,
                languages: model.languages,
                preferred: model.preferred,
                to: store.current
            ))
            Log.info("onboarding done: hold \(model.hotkey.shortName); languages \(model.languages.joined(separator: ", "))")
            self.window?.close()
        }
        self.model = model
        let hosting = NSHostingView(rootView: OnboardingView(model: model))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.contentView = hosting
        window.title = "Welcome to Parrot"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.center()
        return window
    }

    /// Polls while the window is open or a grant is missing, so the
    /// checkmarks and the menu item follow System Settings.
    private static func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated { refresh() }
        }
    }

    private static func refresh() {
        let state = PermissionState.current
        model?.update(state)
        menuBar?.grantPermissionsItem.isHidden = state.allGranted
        if state.allGranted && window == nil {
            poll?.invalidate()
            poll = nil
        } else {
            startPolling()
        }
    }

    /// Closing the window counts as done, like Get Started, without saving
    /// the hotkey and languages shown.
    fileprivate static func closed() {
        window = nil
        model = nil
        if let store, !store.current.onboarding.completed {
            store.update { $0.onboarding.completed = true }
        }
        refresh()
    }

    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { OnboardingWindow.closed() }
        }
    }
}

/// The choices on the page, the grants, and the Allow and Get Started actions.
@MainActor
final class OnboardingModel: ObservableObject {
    @Published private(set) var state = PermissionState.current
    @Published var hotkey: HotkeyKey
    /// Ticked languages as codes, in the order ticked.
    @Published private(set) var languages: [String]

    let hotkeyChoices: [HotkeyKey]
    let preferred: [String]
    let menu: (mac: [String], common: [String], more: [String])
    var onGetStarted: (() -> Void)?

    init(settings: Settings, preferred: [String] = SpokenLanguage.preferredCodes()) {
        hotkey = settings.hotkey.key
        hotkeyChoices = Onboarding.hotkeyChoices(current: settings.hotkey.key)
        self.preferred = preferred
        menu = Onboarding.languageMenu(preferred: preferred)
        languages = settings.language.spokenOrPreferred.filter(SpokenLanguage.whisperLanguages.contains)
    }

    var canGetStarted: Bool { state.allGranted && !languages.isEmpty }

    func update(_ now: PermissionState) {
        if now != state { state = now }
    }

    func isTicked(_ code: String) -> Bool { languages.contains(code) }

    func toggle(_ code: String) {
        if let index = languages.firstIndex(of: code) {
            languages.remove(at: index)
        } else {
            languages.append(code)
        }
    }

    /// Runs `kind`'s steps, waiting for the microphone prompt's answer before
    /// re-reading the grants.
    func allow(_ kind: Permissions.Kind) {
        let steps = Permissions.allowSteps(for: kind, in: state)
        if steps == [.requestMicrophone] {
            MicrophoneAccess.requestIfUndetermined { [weak self] in
                MainActor.assumeIsolated { self?.update(PermissionState.current) }
            }
            return
        }
        steps.forEach(Permissions.perform)
    }

    func getStarted() { onGetStarted?() }
}

/// The page: the bird in a circle, the name, the hotkey and languages as
/// pills, the two permissions, and Get Started. Styled after the Ollama app:
/// capsule buttons with a light fill and no border.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    @State private var showsLanguages = false

    var body: some View {
        VStack(spacing: 0) {
            BirdBadge()
            Text("Parrot")
                .font(.system(size: 24, weight: .semibold))
                .padding(.top, 16)
            Text("Hold a key, speak, and let go.")
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow {
                    label("Hotkey")
                    hotkeyMenu
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    // Always laid out, so the window doesn't change height.
                    Text("fn doesn't work on some third-party keyboards; pick Right Option if yours has none.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 230, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(model.hotkey == .fn ? 1 : 0)
                        .padding(.top, -4)
                }
                GridRow {
                    label("Languages")
                    Button { showsLanguages.toggle() } label: {
                        PillLabel(
                            title: Onboarding.summary(model.languages.map { SpokenLanguage.displayName($0) }),
                            chevron: true
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showsLanguages, arrowEdge: .bottom) {
                        LanguageList(model: model)
                    }
                }
                GridRow {
                    label("Microphone")
                    permission(.microphone, granted: model.state.microphone == .granted,
                               action: model.state.microphone == .denied ? "Open Settings" : "Allow")
                }
                .padding(.top, 8)
                GridRow {
                    label("Accessibility")
                    permission(.accessibility, granted: model.state.accessibility, action: "Allow")
                }
            }
            .fixedSize()
            .padding(.top, 32)

            Button { model.getStarted() } label: {
                Text("Get Started")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.primary))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canGetStarted)
            .opacity(model.canGetStarted ? 1 : 0.35)
            .padding(.top, 32)

            Label("Audio and text never leave your Mac.", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 14)
        }
        .padding(.horizontal, 40)
        .padding(.top, 44)
        .padding(.bottom, 28)
        .frame(width: 420)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private var hotkeyMenu: some View {
        Menu {
            ForEach(model.hotkeyChoices, id: \.self) { key in
                Toggle(key.displayName, isOn: Binding(
                    get: { model.hotkey == key },
                    set: { if $0 { model.hotkey = key } }
                ))
            }
        } label: {
            PillLabel(title: model.hotkey.displayName, chevron: true)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func permission(_ kind: Permissions.Kind, granted: Bool, action: String) -> some View {
        if granted {
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.multicolor)
                .padding(.vertical, 6)
        } else {
            Button { model.allow(kind) } label: { PillLabel(title: action, chevron: false) }
                .buttonStyle(.plain)
        }
    }
}

/// A capsule with a light fill, the Ollama app's button and menu style.
private struct PillLabel: View {
    let title: String
    let chevron: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 13, weight: .medium))
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .contentShape(Capsule())
    }
}

/// The Parrot bird on a filled circle, like Ollama's llama: a white circle
/// with a dark bird in dark mode, the reverse in light mode.
private struct BirdBadge: View {
    private static let bird: NSImage? = {
        guard let image = NSImage(data: Data(MenuBarController.birdSVG.utf8)) else { return nil }
        image.size = NSSize(width: 44, height: 44)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        ZStack {
            Circle().fill(Color.primary)
            if let bird = Self.bird {
                Image(nsImage: bird)
                    .renderingMode(.template)
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(width: 72, height: 72)
    }
}

/// The Languages popover: ticks stay open between clicks, which a menu
/// can't do. The Mac's languages, the common ones, then More Languages.
private struct LanguageList: View {
    @ObservedObject var model: OnboardingModel
    @State private var showsMore = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                rows(model.menu.mac)
                if !model.menu.mac.isEmpty { Divider().padding(.vertical, 2) }
                rows(model.menu.common)
                Divider().padding(.vertical, 2)
                DisclosureGroup("More Languages", isExpanded: $showsMore) {
                    VStack(alignment: .leading, spacing: 6) {
                        rows(model.menu.more)
                    }
                    .padding(.top, 6)
                }
            }
            .padding(14)
        }
        .frame(width: 240, height: 340)
    }

    private func rows(_ codes: [String]) -> some View {
        ForEach(codes, id: \.self) { code in
            Toggle(SpokenLanguage.displayName(code), isOn: Binding(
                get: { model.isTicked(code) },
                set: { _ in model.toggle(code) }
            ))
            .toggleStyle(.checkbox)
        }
    }
}
