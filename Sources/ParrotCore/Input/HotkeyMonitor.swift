import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Watches a single modifier key (default: fn) and emits dictation edges.
/// Requires Accessibility permission. If the tap fails to register, callers
/// will see an error from `start()`.
///
/// Side-specific keys are matched by the keycode on each `flagsChanged`
/// event, because left and right share one `CGEventFlags` bit and the
/// device-dependent low bits vary by keyboard. Fn is matched by its flag, as
/// it always was. Edges go through `Gesture`, which discards short taps and
/// chords, so a shortcut typed on the hotkey produces no text.
///
/// macOS disables a tap that is slow to respond or that user input disables.
/// The monitor re-enables it, with backoff when that does not stick, checks
/// it on a watchdog timer in case a disable event is missed, and reports a
/// tap it cannot recover through `onHealthChange`.
///
/// Everything here runs on the main thread: the tap's run loop source, the
/// watchdog and the retries are all on the main run loop.
final class HotkeyMonitor {
    enum Event: Equatable {
        /// Start recording.
        case pressed
        /// Stop recording and transcribe.
        case released
        /// Stop recording and discard it: a short tap, a chord, or a key switch.
        case cancelled
    }
    enum HotkeyError: Error { case tapCreateFailed }

    /// How often the watchdog checks that the tap is still enabled.
    static let watchdogInterval: TimeInterval = 5

    /// The modifier held to dictate. Change it with `setKey(_:)`.
    private(set) var key: HotkeyKey
    private let debug: Bool
    private var onEvent: ((Event) -> Void)?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var gesture = Gesture()

    private var recovery = TapRecovery()
    private var pendingRetry: DispatchWorkItem?
    private var watchdog: Timer?

    /// Called on the main thread when the tap's health changes.
    var onHealthChange: ((HotkeyHealth) -> Void)?
    private(set) var health: HotkeyHealth = .ok {
        didSet {
            if health != oldValue { onHealthChange?(health) }
        }
    }

    init(key: HotkeyKey = .fn, debug: Bool = false) {
        self.key = key
        self.debug = debug
    }

    /// Switch to another key without recreating the tap; the next press of
    /// `newKey` records. A recording in progress on the old key is cancelled.
    func setKey(_ newKey: HotkeyKey) {
        guard newKey != key else { return }
        let action = gesture.reset()
        key = newKey
        if let action { emit(action) }
    }

    func start(onEvent: @escaping (Event) -> Void) throws {
        self.onEvent = onEvent

        // The caller waits for the grant before starting (Daemon.startHotkey);
        // this is a guard, not the place that asks.
        if !AXIsProcessTrusted() {
            throw HotkeyError.tapCreateFailed
        }

        // flagsChanged only, in every mode including --debug-hotkey. Do not
        // widen this mask: keyDown/keyUp would route every keystroke,
        // password fields included, through a process that holds
        // Accessibility, and the extra work per keystroke makes macOS more
        // likely to disable the tap for being slow. The hotkey is a modifier,
        // so flagsChanged carries everything we need.
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        // .cgSessionEventTap is the right level for an accessibility-granted
        // user process (.cghidEventTap requires root).
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        else {
            throw HotkeyError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source

        let watchdog = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            self?.checkTap()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        self.watchdog = watchdog
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        pendingRetry?.cancel()
        pendingRetry = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        onEvent = nil
    }

    fileprivate func handle(event: CGEvent) {
        let flags = event.flags
        // flagsChanged carries the modifier's keycode, never a character.
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        if debug {
            Log.info("  [debug] modifier keycode=\(keycode) flags=\(String(flags.rawValue, radix: 16))")
        }
        guard let input = Self.input(keycode: keycode, flags: flags, key: key, held: gesture.isHeld) else { return }
        feed(input)
    }

    private func feed(_ input: Gesture.Input) {
        if let action = gesture.handle(input, at: ProcessInfo.processInfo.systemUptime) {
            emit(action)
        }
    }

    private func emit(_ action: Gesture.Action) {
        switch action {
        case .start: onEvent?(.pressed)
        case .transcribe: onEvent?(.released)
        case .cancel: onEvent?(.cancelled)
        }
    }

    // MARK: - Matching

    /// The modifier keycodes that count as another key in a chord: both
    /// sides of ⌘ ⇧ ⌥ ⌃, and fn. Caps Lock and unknown keycodes do not.
    static let modifierKeycodes: Set<Int64> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    /// Flags that mean another modifier is down at the press.
    static let chordFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    /// What one `flagsChanged` event means for `key`, given whether the key
    /// is already held. Pure, so the matching is tested without a tap.
    ///
    /// - Press: the key's keycode arrives with its flag set (fn: its flag is
    ///   set on any event, as before #42).
    /// - Release: the key's keycode arrives again, or its flag is clear on
    ///   any event while held, which also covers a missed release.
    /// - Another modifier's keycode while held is a chord.
    static func input(keycode: Int64, flags: CGEventFlags, key: HotkeyKey, held: Bool) -> Gesture.Input? {
        let flagSet = flags.contains(key.flag)
        if held {
            if !flagSet { return .hotkeyUp }
            // Our side went up while the other side still holds the shared flag.
            if key != .fn, keycode == key.keycode { return .hotkeyUp }
            if keycode != key.keycode, modifierKeycodes.contains(keycode) { return .otherModifier }
            return nil
        }
        guard flagSet, key == .fn || keycode == key.keycode else { return nil }
        let others = flags.intersection(chordFlags).subtracting(key.flag)
        return .hotkeyDown(othersHeld: !others.isEmpty)
    }

    // MARK: - Recovery

    fileprivate func tapWasDisabled(_ type: CGEventType) {
        noteDisabled(reason: type == .tapDisabledByTimeout ? "timeout" : "user input")
    }

    /// The tap is off. Re-enable now, or later if earlier attempts did not
    /// stick. A retry already scheduled covers any further disable events.
    private func noteDisabled(reason: String) {
        guard tap != nil, pendingRetry == nil else { return }
        let delay = recovery.disabled(at: Date())
        if delay == 0 {
            reenable(reason: reason)
        } else {
            scheduleRetry(after: delay, reason: reason)
        }
    }

    private func reenable(reason: String) {
        pendingRetry = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CGEvent.tapIsEnabled(tap: tap) else {
            scheduleRetry(after: recovery.enableFailed(), reason: reason)
            return
        }
        recovery.enabled(at: Date())
        Log.info("hotkey tap disabled (\(reason)); re-enabled")
        health = .ok
        resync()
    }

    private func scheduleRetry(after delay: TimeInterval, reason: String) {
        let secureInput = IsSecureEventInputEnabled()
        health = .degraded(secureInput: secureInput)
        let detail = secureInput ? ", secure input active" : ""
        Log.warning("hotkey tap disabled (\(reason)\(detail)); retrying in \(Int(delay))s")
        let retry = DispatchWorkItem { [weak self] in
            self?.reenable(reason: reason)
        }
        pendingRetry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
    }

    /// Watchdog tick: catches a disable whose event never arrived.
    private func checkTap() {
        guard let tap, pendingRetry == nil else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            noteDisabled(reason: "watchdog")
        }
    }

    /// While the tap was off, the hotkey may have been released unseen.
    private func resync() {
        let held = CGEventSource.flagsState(.combinedSessionState).contains(key.flag)
        guard Self.resyncEvent(wasPressed: gesture.isHeld, heldNow: held) != nil else { return }
        feed(.hotkeyUp)
    }

    /// The edge to emit after re-enabling, given what the monitor last saw
    /// and what the keyboard holds now. Only a missed release is emitted: a
    /// press missed while the tap was off does not start a recording halfway
    /// through, and its release is then ignored because no press was seen.
    static func resyncEvent(wasPressed: Bool, heldNow: Bool) -> Event? {
        wasPressed && !heldNow ? .released : nil
    }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    // Return at once and do the work on the next main run loop turn: a slow
    // callback is what gets a tap disabled by timeout.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DispatchQueue.main.async {
            monitor.tapWasDisabled(type)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .flagsChanged, let copy = event.copy() else {
        return Unmanaged.passUnretained(event)
    }
    DispatchQueue.main.async {
        monitor.handle(event: copy)
    }
    return Unmanaged.passUnretained(event)
}
