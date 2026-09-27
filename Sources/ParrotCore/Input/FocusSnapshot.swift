import AppKit
import ApplicationServices
import Foundation

/// What had keyboard focus at one moment: the frontmost app, its focused
/// element, and whether that element is a secure (password) field.
///
/// Taken at recording start and again right before delivery, over
/// Accessibility, so delivery needs no watch on keystrokes or clicks.
struct FocusSnapshot {
    /// The frontmost app, if any.
    var pid: pid_t?
    /// The focused element, if the app exposes one over Accessibility.
    var element: FocusedElement?
    /// The focused element is a secure text field or reports protected content.
    var isSecure: Bool

    /// Upper bound on each Accessibility call, so a hung app cannot stall
    /// the main thread (and with it the hotkey tap).
    private static let messagingTimeout: Float = 0.25

    @MainActor
    static func capture() -> FocusSnapshot {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let systemWide = AXUIElementCreateSystemWide()
        // On the system-wide element, this sets the timeout for every element.
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return FocusSnapshot(pid: pid, element: nil, isSecure: false)
        }
        let element = value as! AXUIElement
        return FocusSnapshot(pid: pid, element: FocusedElement(element), isSecure: isSecure(element))
    }

    /// Whether focus moved from `self` to `now`. The app must match. The
    /// element must match when both snapshots saw one; an element seen only
    /// once is not a change, because Chromium and Electron apps build their
    /// Accessibility tree lazily and may expose nothing at recording start.
    func hasChanged(to now: FocusSnapshot) -> Bool {
        if pid != now.pid { return true }
        if let element, let other = now.element, element != other { return true }
        return false
    }

    /// Secure only when the element says so. An element that cannot be read
    /// is not treated as secure, or every app without Accessibility support
    /// would lose its dictation.
    private static func isSecure(_ element: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           let subrole = subrole as? String,
           subrole == kAXSecureTextFieldSubrole as String {
            return true
        }
        var protected: CFTypeRef?
        let attribute = NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString
        if AXUIElementCopyAttributeValue(element, attribute, &protected) == .success,
           let protected = protected as? Bool {
            return protected
        }
        return false
    }
}

/// An Accessibility element compared by identity (`CFEqual`).
struct FocusedElement: Equatable {
    let ref: AXUIElement

    init(_ ref: AXUIElement) {
        self.ref = ref
    }

    static func == (lhs: FocusedElement, rhs: FocusedElement) -> Bool {
        CFEqual(lhs.ref, rhs.ref)
    }
}
