import AppKit
import CoreGraphics
import Foundation

/// How a transcript is inserted at the cursor. Paste is the default.
///
/// Paste works in every app that supports paste, including the terminals and
/// Electron editors that ignore `type-unicode` and drop its text with no
/// error. It borrows the clipboard for `TextInjector.settleDelay` and always
/// restores it. `type-unicode` leaves the clipboard alone.
public enum InjectMode: String, CaseIterable, Sendable {
    case paste
    case typeUnicode = "type-unicode"
}

/// Inserts text at the current cursor location by synthesizing keyboard
/// events: ⌘V over the clipboard (`.paste`) or Unicode key events
/// (`.typeUnicode`).
///
/// Every event comes from a private `CGEventSource` with its flags set
/// explicitly. An event with a nil source inherits the modifiers the user is
/// holding, so a held Control or Fn turned typed text into shortcuts.
@MainActor
final class TextInjector {
    /// Where every synthesized event is posted. One constant, so the app
    /// matrix in #38 can switch it in one line if a location fails there.
    ///
    /// `.cgSessionEventTap` enters where hardware events enter the login
    /// session, so the event reaches the focused app exactly as a key press
    /// would. Our own tap is `.listenOnly` and returns every event
    /// unchanged, so it cannot swallow what we post. `.cghidEventTap` posts
    /// below the session, where the window server can merge in the physical
    /// modifier state; `.cgAnnotatedSessionEventTap` skips the session taps
    /// other tools install. Neither has a reason we can verify.
    static let postLocation: CGEventTapLocation = .cgSessionEventTap

    /// How long the target app gets to read the clipboard before it is restored.
    static let settleDelay: TimeInterval = 0.25

    /// Virtual keycode for V on ANSI layouts (kVK_ANSI_V).
    private static let keycodeV: CGKeyCode = 9

    /// `CGEventKeyboardSetUnicodeString` takes about 20 UTF-16 units per event.
    private static let chunkSize = 20

    let mode: InjectMode
    private let clipboard: PasteboardSession

    init(mode: InjectMode, pasteboard: NSPasteboard = .general) {
        self.mode = mode
        self.clipboard = PasteboardSession(
            pasteboard: SystemPasteboard(pasteboard),
            settleDelay: Self.settleDelay,
            postPaste: Self.postCommandV
        )
    }

    /// Inserts `text` at the cursor.
    func inject(_ text: String) {
        guard !text.isEmpty else { return }
        switch mode {
        case .paste: clipboard.paste(text)
        case .typeUnicode: Self.typeUnicode(text)
        }
    }

    /// Leaves `text` on the clipboard for the user to paste.
    func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        clipboard.copy(text)
    }

    /// Virtual keycode for the space bar (kVK_Space), the same on every layout.
    private static let keycodeSpace: CGKeyCode = 49

    /// Presses the space bar: a space some apps would trim from a paste.
    func pressSpace() {
        let source = CGEventSource(stateID: .privateState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: Self.keycodeSpace, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: Self.keycodeSpace, keyDown: false)
        else { return }
        down.flags = []
        up.flags = []
        down.post(tap: Self.postLocation)
        up.post(tap: Self.postLocation)
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .privateState)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: keycodeV, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: keycodeV, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: postLocation)
        up.post(tap: postLocation)
    }

    private static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .privateState)
        let utf16 = Array(text.utf16)
        var index = 0
        while index < utf16.count {
            var end = min(index + chunkSize, utf16.count)
            // Keep a surrogate pair in one event.
            if end < utf16.count, UTF16.isLeadSurrogate(utf16[end - 1]) {
                end -= 1
            }
            var chunk = Array(utf16[index..<end])
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return }
            down.flags = []
            up.flags = []
            // Payload on key-down only: some apps insert a key-up payload too,
            // which typed every chunk twice.
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: postLocation)
            up.post(tap: postLocation)
            index = end
        }
    }
}

// MARK: - Clipboard

/// One representation of one pasteboard item.
struct PasteboardRepresentation: Equatable {
    var type: String
    var data: Data
}

/// Every representation of every item on a pasteboard, so text, images and
/// copied Finder files all come back.
struct PasteboardSnapshot: Equatable {
    var items: [[PasteboardRepresentation]]
}

/// The pasteboard operations paste mode needs. `NSPasteboard` in the app,
/// a fake in tests.
protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    func restore(_ snapshot: PasteboardSnapshot)
    /// Replaces the contents with `text`, plus an empty item of each marker type.
    func write(_ text: String, markers: [String])
}

/// Borrows the clipboard for a paste and gives it back.
///
/// `paste` saves the clipboard, writes the text, posts ⌘V and restores the
/// saved clipboard after the settle delay. A second paste before that
/// restore keeps the first snapshot, so the user's own clipboard comes back,
/// not an earlier transcript. If anything else writes the clipboard during
/// the window, that write wins and nothing is restored over it.
final class PasteboardSession {
    /// nspasteboard.org markers: clipboard managers skip these items.
    static let transientMarkers = ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"]
    /// A clipboard fallback is meant to stay, but is still kept out of history.
    static let concealedMarkers = ["org.nspasteboard.ConcealedType"]

    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void

    private let pasteboard: PasteboardAccess
    private let settleDelay: TimeInterval
    private let postPaste: () -> Void
    private let schedule: Schedule

    /// The user's clipboard while a restore is pending.
    private var saved: PasteboardSnapshot?
    /// The change count right after our last write.
    private var ourChangeCount = 0
    /// Bumped on every write; only the latest scheduled restore runs.
    private var generation = 0

    init(
        pasteboard: PasteboardAccess,
        settleDelay: TimeInterval,
        postPaste: @escaping () -> Void,
        schedule: @escaping Schedule = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.pasteboard = pasteboard
        self.settleDelay = settleDelay
        self.postPaste = postPaste
        self.schedule = schedule
    }

    var isRestorePending: Bool { saved != nil }

    func paste(_ text: String) {
        if saved == nil {
            saved = pasteboard.snapshot()
        }
        pasteboard.write(text, markers: Self.transientMarkers)
        ourChangeCount = pasteboard.changeCount
        postPaste()
        generation += 1
        let current = generation
        schedule(settleDelay) { [weak self] in
            self?.restore(ifGeneration: current)
        }
    }

    /// Puts `text` on the clipboard to stay. Drops any pending restore, which
    /// would otherwise overwrite it.
    func copy(_ text: String) {
        saved = nil
        generation += 1
        pasteboard.write(text, markers: Self.concealedMarkers)
        ourChangeCount = pasteboard.changeCount
    }

    private func restore(ifGeneration expected: Int) {
        guard expected == generation, let snapshot = saved else { return }
        saved = nil
        guard pasteboard.changeCount == ourChangeCount else {
            Log.info("  clipboard changed during paste; not restoring")
            return
        }
        pasteboard.restore(snapshot)
    }
}

/// `PasteboardAccess` over an `NSPasteboard`.
final class SystemPasteboard: PasteboardAccess {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { PasteboardRepresentation(type: type.rawValue, data: $0) }
            }
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        let items = snapshot.items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    func write(_ text: String, markers: [String]) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        for marker in markers {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
        }
        pasteboard.writeObjects([item])
    }
}
