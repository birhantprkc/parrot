import Foundation

/// Turns hotkey edges into dictation actions (ADR-003). Pure, so the rules
/// are tested without an event tap.
///
/// The tap sees modifier changes only, so it cannot see the C in ⌘C. Two
/// rules keep a shortcut typed on the hotkey from producing text:
/// - A hold shorter than `minimumHold` is discarded without transcribing.
/// - A recording is cancelled if another modifier changes while the hotkey
///   is held, and a press while another modifier is already held does not
///   record. Either way the rest of that hold is ignored.
///
/// Recording still starts on key-down, so press latency is unchanged; a
/// discarded hold just throws its audio away.
struct Gesture {
    /// Holds shorter than this are taps or shortcuts, not dictation.
    static let minimumHold: TimeInterval = 0.3

    enum Input: Equatable {
        /// The hotkey went down. `othersHeld`: another modifier was already
        /// down, so this is a chord.
        case hotkeyDown(othersHeld: Bool)
        /// The hotkey went up.
        case hotkeyUp
        /// Another modifier changed while the hotkey was down.
        case otherModifier
    }

    enum Action: Equatable {
        /// Start recording.
        case start
        /// Stop recording and transcribe.
        case transcribe
        /// Stop recording and discard it.
        case cancel
    }

    private enum Phase: Equatable {
        case idle
        /// Recording since this time.
        case recording(since: TimeInterval)
        /// The hotkey is down but this hold is a chord: ignore it until release.
        case ignoring
    }

    private var phase: Phase = .idle

    /// Whether the hotkey is down, as far as the edges seen so far say.
    var isHeld: Bool { phase != .idle }

    /// Feed one edge at `time` (seconds on a monotonic clock).
    mutating func handle(_ input: Input, at time: TimeInterval) -> Action? {
        switch (phase, input) {
        case (.idle, .hotkeyDown(let othersHeld)):
            if othersHeld {
                phase = .ignoring
                return nil
            }
            phase = .recording(since: time)
            return .start
        case (.recording(let since), .hotkeyUp):
            phase = .idle
            return time - since < Self.minimumHold ? .cancel : .transcribe
        case (.recording, .otherModifier):
            phase = .ignoring
            return .cancel
        case (.ignoring, .hotkeyUp):
            phase = .idle
            return nil
        default:
            // A repeated down, an up with no down seen, or a modifier change
            // outside a recording.
            return nil
        }
    }

    /// Forget the current hold, for a switch to another key. A recording in
    /// progress is cancelled.
    mutating func reset() -> Action? {
        defer { phase = .idle }
        if case .recording = phase { return .cancel }
        return nil
    }
}
