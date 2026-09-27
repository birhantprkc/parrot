import AppKit
import Foundation

/// Flags for one foreground run of the dictation loop. Never persisted.
public struct DaemonOptions {
    public var skipDoctor: Bool
    public var debugHotkey: Bool
    public var dumpWav: Bool
    public var noOverlay: Bool
    public var model: String?
    /// How transcripts are inserted. Paste unless `--inject-mode` says otherwise.
    public var injectMode: InjectMode

    public init(
        skipDoctor: Bool,
        debugHotkey: Bool,
        dumpWav: Bool,
        noOverlay: Bool,
        model: String?,
        injectMode: InjectMode = .paste
    ) {
        self.skipDoctor = skipDoctor
        self.debugHotkey = debugHotkey
        self.dumpWav = dumpWav
        self.noOverlay = noOverlay
        self.model = model
        self.injectMode = injectMode
    }
}

/// The dictation daemon (`parrot`, `parrot run`): startup checks, model
/// warmup, then the AppKit run loop. Does not return once running.
public enum Daemon {
    /// Throws `StartupFailure` if the daemon cannot start.
    public static func run(_ options: DaemonOptions) throws {
        let chosenModel = try Startup.check(modelID: options.model, skipDoctor: options.skipDoctor)

        // Startup has already exited on denied access. If the system has never
        // asked, ask now, without waiting, so the prompt is answered during
        // warmup rather than on the first press.
        MicrophoneAccess.requestIfUndetermined()

        let transcriber = WhisperKitTranscriber(model: chosenModel)
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            throw StartupFailure.warmupFailed(warmupError)
        }

        // ArgumentParser calls run() on the main thread.
        try MainActor.assumeIsolated {
            try runLoop(model: chosenModel, transcriber: transcriber, options: options)
        }
    }

    /// Wires the hotkey, capture and UI to a `DictationController` and runs
    /// the AppKit loop. Returns only if the app terminates.
    @MainActor
    private static func runLoop(model: TranscriptionModel, transcriber: Transcriber, options: DaemonOptions) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(debug: options.debugHotkey)
        let capture = AudioCapture()
        let overlay: RecordingOverlay? = options.noOverlay ? nil : RecordingOverlay()
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let menuBar = MenuBarController(modelID: model.id)

        // Overlay first, then menu bar: the order the UI updated in before.
        var observers: [DictationObserver] = []
        if let overlay { observers.append(overlay) }
        observers.append(menuBar)
        let controller = DictationController(
            capture: capture,
            transcriber: transcriber,
            processors: [],
            observers: observers,
            dumpWav: options.dumpWav,
            delivery: TextDelivery(mode: options.injectMode)
        )

        // HotkeyMonitor reports health on the main thread.
        monitor.onHealthChange = { health in
            MainActor.assumeIsolated { menuBar.setHotkeyHealth(health) }
        }
        do {
            // HotkeyMonitor delivers events on the main queue.
            try monitor.start { event in
                MainActor.assumeIsolated { controller.handle(event) }
            }
        } catch {
            throw StartupFailure.hotkeyUnavailable(error)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            Log.info("\nshutting down")
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        Log.info("listening on fn hold · model: \(model.id) · inject: \(options.injectMode.rawValue) · ^C to quit")
        app.run()
    }
}
