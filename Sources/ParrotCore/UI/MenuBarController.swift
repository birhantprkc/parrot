import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
///
/// The menu has named slots, top to bottom: `statusLine`, `modelLine`,
/// `settingsItem`, `launchAtLoginItem`, `checkForUpdatesItem`, `quitItem`. Features update a slot rather than rebuilding
/// the menu.
@MainActor
final class MenuBarController {
    private static let readyStatus = "idle · hold fn to dictate"

    private let statusItem: NSStatusItem
    /// Slot: what the dictation loop is doing. Driven as a `DictationObserver`.
    let statusLine: NSMenuItem
    /// Slot: the loaded model.
    let modelLine: NSMenuItem
    /// Slot: opens the settings window. Disabled until that window exists (#41).
    let settingsItem: NSMenuItem
    /// Slot: launch at login through `SMAppService`, checked while on.
    /// Hidden outside Parrot.app, where there is no bundle to register.
    let launchAtLoginItem: NSMenuItem
    private let launchAtLogin = LaunchAtLoginToggle()
    /// Slot: asks Sparkle to check now. Hidden unless the updater is running,
    /// which it is only in Parrot.app's release builds.
    let checkForUpdatesItem: NSMenuItem
    /// Slot: quits parrot.
    let quitItem: NSMenuItem

    /// A degraded hotkey tap replaces the idle line, so the menu bar does not
    /// claim fn works when it does not (#37).
    private var hotkeyHealth: HotkeyHealth = .ok
    private var isIdle = true
    private var idleStatus: String { hotkeyHealth.statusText ?? Self.readyStatus }

    init(modelID: String) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        statusLine = NSMenuItem(title: Self.readyStatus, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        modelLine = NSMenuItem(title: "model: \(modelID)", action: nil, keyEquivalent: "")
        modelLine.isEnabled = false
        menu.addItem(modelLine)

        menu.addItem(.separator())

        settingsItem = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
        settingsItem.isEnabled = false
        menu.addItem(settingsItem)

        launchAtLoginItem = launchAtLogin.item
        menu.addItem(launchAtLoginItem)
        menu.delegate = launchAtLogin

        checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesClicked),
            keyEquivalent: ""
        )
        checkForUpdatesItem.isHidden = !Updater.isRunning
        menu.addItem(checkForUpdatesItem)

        quitItem = NSMenuItem(
            title: "Quit parrot",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        quitItem.target = self
        checkForUpdatesItem.target = self
        configureButton()
    }

    func setStatus(_ text: String) {
        statusLine.title = text
    }

    func setHotkeyHealth(_ health: HotkeyHealth) {
        hotkeyHealth = health
        if isIdle { setStatus(idleStatus) }
    }

    func setModel(_ modelID: String) {
        modelLine.title = "model: \(modelID)"
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        let image = Self.birdImage()
        image?.isTemplate = true
        button.image = image
    }

    // Inlined Lucide bird SVG. Keeping it in source means the executable has
    // no separate resource bundle to install alongside it — true single-binary.
    private static let birdSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M16 7h.01"/>\
    <path d="M3.4 18H12a8 8 0 0 0 8-8V7a4 4 0 0 0-7.28-2.3L2 20"/>\
    <path d="m20 7 2 .5-2 .5"/>\
    <path d="M10 18v3"/>\
    <path d="M14 17.75V21"/>\
    <path d="M7 18a6 6 0 0 0 3.84-10.61"/>\
    </svg>
    """

    private static func birdImage() -> NSImage? {
        guard let data = birdSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func checkForUpdatesClicked() {
        Updater.checkForUpdates()
    }

    @objc private func quitClicked() {
        NSApp.terminate(nil)
    }
}

/// Target of the "Launch at login" item. Also the menu's delegate, to
/// re-read the state each time the menu opens: the user can change it in
/// System Settings while Parrot runs.
@MainActor
private final class LaunchAtLoginToggle: NSObject, NSMenuDelegate {
    let item = NSMenuItem(title: "Launch at login", action: nil, keyEquivalent: "")

    override init() {
        super.init()
        item.action = #selector(toggle)
        item.target = self
        item.isHidden = !LoginItem.isAvailable
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    private func refresh() {
        guard LoginItem.isAvailable else { return }
        item.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func toggle() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            Log.warning("couldn't change launch at login: \(error)")
        }
        refresh()
    }
}

extension MenuBarController: DictationObserver {
    func dictationStarted() {
        isIdle = false
        setStatus("● recording")
    }

    func dictationTranscribing() {
        isIdle = false
        setStatus("transcribing…")
    }

    func dictationFinished(_ result: DictationResult) {
        isIdle = true
        setStatus(idleStatus)
    }

    func dictationFailed(_ error: Error) {
        isIdle = true
        setStatus(idleStatus)
    }
}
