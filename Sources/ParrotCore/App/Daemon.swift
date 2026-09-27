import AppKit
import Foundation

/// Flags for one foreground run of the dictation loop. Never persisted.
public struct DaemonOptions {
    public var skipDoctor: Bool
    public var debugHotkey: Bool
    public var dumpWav: Bool
    public var noOverlay: Bool
    public var model: String?

    public init(skipDoctor: Bool, debugHotkey: Bool, dumpWav: Bool, noOverlay: Bool, model: String?) {
        self.skipDoctor = skipDoctor
        self.debugHotkey = debugHotkey
        self.dumpWav = dumpWav
        self.noOverlay = noOverlay
        self.model = model
    }
}

/// The dictation daemon (`parrot`, `parrot run`): startup checks, model
/// warmup, then the AppKit run loop. Does not return once running.
public enum Daemon {
    /// Throws `StartupFailure` if the daemon cannot start.
    public static func run(_ options: DaemonOptions) throws {
        let debugHotkey = options.debugHotkey
        let noOverlay = options.noOverlay

        let chosenModel = try Startup.check(modelID: options.model, skipDoctor: options.skipDoctor)

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

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(debug: debugHotkey)
        let capture = AudioCapture()
        let dumpWav = options.dumpWav
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        let menuBar = MainActor.assumeIsolated { MenuBarController(modelID: chosenModel.id) }

        do {
            try monitor.start { event in
                switch event {
                case .pressed:
                    do {
                        try capture.start()
                        Log.info("● recording")
                        MainActor.assumeIsolated {
                            overlay?.show(.recording)
                            menuBar.setRecording(true)
                        }
                    } catch {
                        Log.error("capture failed: \(error)")
                    }
                case .released:
                    let samples = capture.stop()
                    MainActor.assumeIsolated {
                        overlay?.show(.transcribing)
                        menuBar.setTranscribing()
                    }
                    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                    let rms = computeRMS(samples)
                    Log.info(String(format: "○ captured %.2fs · rms %.3f", seconds, rms))
                    if dumpWav, !samples.isEmpty {
                        do {
                            try Paths.prepareDirectory(Paths.caches)
                            let path = try Paths.preparePrivateFile(Paths.dumpWav).path
                            try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                            Log.info("  wrote \(path)")
                        } catch {
                            Log.error("  wav write failed: \(error)")
                        }
                    }
                    guard !samples.isEmpty else {
                        MainActor.assumeIsolated {
                            overlay?.hide()
                            menuBar.setRecording(false)
                        }
                        return
                    }
                    Task {
                        let started = Date()
                        do {
                            let text = try await transcriber.transcribe(samples)
                            let elapsed = Date().timeIntervalSince(started)
                            // Never log the transcript itself: the agent's log is a file on disk.
                            Log.info(String(format: "→ %.2fs · %d chars", elapsed, text.count))
                            await MainActor.run {
                                TextInjector.inject(text)
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        } catch {
                            Log.error("transcription failed: \(error)")
                            await MainActor.run {
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        }
                    }
                }
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

        Log.info("listening on fn hold · model: \(chosenModel.id) · ^C to quit")
        app.run()
    }
}
