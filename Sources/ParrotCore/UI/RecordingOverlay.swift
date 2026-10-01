import AppKit
import SwiftUI

/// Borderless, click-through pill near the bottom of the active screen.
/// Driven by the dictation loop as a `DictationObserver`.
///
/// Besides the recording and transcribing states, the pill can show a
/// one-line message (`showMessage`). A `UserFacingError` reaching
/// `dictationFailed` is shown that way; any other error just hides the pill.
@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        case transcribing
        /// One line of text, for example why a recording failed.
        case message(String)
    }

    /// How long a message stays up unless another state replaces it.
    nonisolated static let messageDuration: TimeInterval = 4

    /// Wide enough for a one-line message; the panel is transparent and
    /// click-through, so the unused width is invisible. Taller than the pill
    /// so its SwiftUI shadow is not clipped.
    private static let panelSize = NSSize(width: 640, height: 64)

    /// How long the pill takes to grow or shrink; on hide, the window is
    /// ordered out once it has.
    nonisolated static let scaleDuration: TimeInterval = 0.3

    init() {
        // Build the panel now, not on the first press, so the first pill
        // appears as quickly as every later one.
        ensureWindow()
    }

    private var window: NSPanel?
    private let model = OverlayModel()
    /// Bumped by every `show`, so a message timer only hides its own message.
    private var generation = 0

    func show(_ state: State) {
        generation += 1
        ensureWindow()
        if state == .recording {
            model.resetLevels()
        }
        guard let window else { return }
        let needsAppear = !window.isVisible
        if needsAppear {
            positionAtBottomCenter(window)
            window.orderFrontRegardless()
            // Defer the state change so SwiftUI lays out in the .hidden style
            // first, then animates to the visible style on the next runloop tick.
            DispatchQueue.main.async { [model] in
                model.state = state
            }
        } else {
            model.state = state
        }
    }

    func hide() {
        model.state = .hidden
        // Let the SwiftUI scale+fade animation play out before yanking the
        // window — otherwise it just pops away. Skip it if something was
        // shown again in the meantime.
        let window = self.window
        let model = self.model
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scaleDuration) {
            guard model.state == .hidden else { return }
            window?.orderOut(nil)
        }
    }

    /// Shows `text` on one line in the pill for `duration` seconds, then
    /// hides it, unless another state has replaced it by then. Never pass
    /// transcript text.
    func showMessage(_ text: String, for duration: TimeInterval = RecordingOverlay.messageDuration) {
        show(.message(text))
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == shown else { return }
                self.hide()
            }
        }
    }

    /// The message to show for a failed dictation, or nil to just hide.
    nonisolated static func message(for error: Error) -> String? {
        (error as? UserFacingError)?.userMessage
    }

    /// Push a new audio level (0…~1). Safe to call from any thread.
    nonisolated func pushLevel(_ level: Float) {
        Task { @MainActor in
            self.model.pushLevel(level)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The pill draws its own shadow. A window shadow is computed from the
        // window's contents when it is shown, so it would not follow the pill
        // as it grows and shrinks, and would linger after it had gone.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(rootView: OverlayPill(model: model))
        // Keep the panel its fixed size and let SwiftUI center the pill in it,
        // so a wider message grows both ways instead of off to the right.
        host.sizingOptions = []
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host

        window = panel
    }

    private func positionAtBottomCenter(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = window.frame
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        // The pill sits 32 pt above the bottom of the visible frame; the
        // panel extends below it by half its extra height.
        let y = visible.minY + 32 - (frame.height - 44) / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

extension RecordingOverlay: DictationObserver {
    func dictationStarted() {
        show(.recording)
    }

    func dictationTranscribing() {
        show(.transcribing)
    }

    func dictationFinished(_ result: DictationResult) {
        hide()
    }

    func dictationFailed(_ error: Error) {
        if let text = Self.message(for: error) {
            showMessage(text)
        } else {
            hide()
        }
    }
}

/// Observable state for the SwiftUI pill.
@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 6
    /// Per-bar height multiplier — center bars peak higher than edge bars.
    private static let envelope: [Float] = [0.55, 0.85, 1.0, 1.0, 0.85, 0.55]

    @Published var state: RecordingOverlay.State = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)

    /// How often the bars move. Capture delivers a level per buffer, about
    /// every 12 ms with the AUHAL input (#52); the bars are tuned for about
    /// 100 ms and look twitchy any faster.
    static let refreshInterval: TimeInterval = 0.1

    private var pendingPower: Float = 0
    private var pendingCount = 0
    private var lastRefresh: TimeInterval = 0

    /// Collects levels and moves the bars once per `refreshInterval`, with
    /// the RMS over that interval.
    func pushLevel(_ level: Float) {
        pendingPower += level * level
        pendingCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRefresh >= Self.refreshInterval else { return }
        let rms = (pendingPower / Float(pendingCount)).squareRoot()
        pendingPower = 0
        pendingCount = 0
        lastRefresh = now
        showLevel(rms)
    }

    private func showLevel(_ level: Float) {
        let shaped = min(1.0, sqrt(max(0, level)) * 3.4)
        var next = [Float]()
        next.reserveCapacity(Self.barCount)
        for i in 0..<Self.barCount {
            // Small per-bar jitter so the bars don't all move in lockstep.
            let jitter = Float.random(in: 0.78...1.0)
            next.append(shaped * Self.envelope[i] * jitter)
        }
        levels = next
    }

    func resetLevels() {
        pendingPower = 0
        pendingCount = 0
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

private struct OverlayPill: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        content
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                Capsule()
                    .fill(Color(red: 16/255, green: 18/255, blue: 18/255))
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
            )
            .scaleEffect(model.state == .hidden ? 0 : 1)
            .animation(
                .timingCurve(0.16, 1, 0.3, 1, duration: RecordingOverlay.scaleDuration),
                value: model.state
            )
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden, .recording, .transcribing:
            // The same bars in both states, so transcribing is the recording
            // bars settling into a wave rather than a swap to a spinner.
            Waveform(levels: model.levels, transcribing: model.state == .transcribing)
                .frame(width: 51, height: 20)
        case .message(let text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(red: 235/255, green: 238/255, blue: 242/255))
                .lineLimit(1)
                .fixedSize()
                .frame(height: 20)
        }
    }
}

private struct Waveform: View {
    let levels: [Float]
    /// Ignore `levels` and run a wave across the bars, left to right.
    var transcribing = false
    private let color = Color(red: 181/255.0, green: 209/255.0, blue: 255/255.0)

    /// Seconds for one wave to cross a bar, and the phase step between bars.
    private static let wavePeriod = 0.45
    private static let barPhase = 0.9

    var body: some View {
        TimelineView(.animation(paused: !transcribing)) { context in
            bars(transcribing ? wave(at: context.date) : levels)
        }
    }

    private func wave(at date: Date) -> [Float] {
        let t = date.timeIntervalSinceReferenceDate * 2 * .pi / Self.wavePeriod
        return levels.indices.map { i in
            let s = (sin(t - Double(i) * Self.barPhase) + 1) / 2
            return Float(0.2 + 0.45 * s)
        }
    }

    private func bars(_ levels: [Float]) -> some View {
        HStack(alignment: .center, spacing: 3.75) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color)
                    .frame(width: 2.5)
                    .frame(maxHeight: .infinity)
                    .scaleEffect(y: max(0.10, CGFloat(level)), anchor: .center)
                    // The wave is already smooth frame to frame; easing it
                    // too only makes it trail.
                    .animation(transcribing ? nil : .easeOut(duration: 0.09), value: level)
            }
        }
    }
}
