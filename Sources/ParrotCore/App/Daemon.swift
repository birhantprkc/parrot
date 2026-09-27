import AppKit
import ApplicationServices
import AVFoundation
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
    public static func run(_ options: DaemonOptions) throws {
        let skipDoctor = options.skipDoctor
        let debugHotkey = options.debugHotkey
        let noOverlay = options.noOverlay
        let model = options.model

        // Agents installed before 0.0.6 log to /tmp until the plist is rewritten.
        if Paths.legacyTmpFiles.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
            FileHandle.standardError.write(Data(
                "note: old parrot logs found in /tmp; run `parrot install --launch-at-login` again to remove them and log privately.\n".utf8
            ))
        }

        if !skipDoctor {
            let checks = DoctorReport.run()
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw SilentExit(1)
            }
        }

        // Checks that retrying can't fix run before the model loads, so a
        // failing start costs nothing and exits 0 (see permanentFailure).
        let chosenModel: TranscriptionModel
        if let id = model {
            guard let m = ModelRegistry.find(id) else {
                throw permanentFailure("unknown model: \(id)", fix: "pick one from `parrot models list` and update --model")
            }
            chosenModel = m
        } else {
            guard let m = ModelRegistry.recommended() else {
                throw permanentFailure("no models registered", fix: "reinstall parrot")
            }
            chosenModel = m
        }

        // No prompt here: prompting on every relaunch re-fires the system
        // dialog. `parrot setup` is the only place that prompts.
        if !AXIsProcessTrusted() {
            throw permanentFailure("accessibility not granted", fix: "run `parrot setup`")
        }

        // .notDetermined is left to the first recording, which requests access.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            throw permanentFailure(
                "microphone access denied",
                fix: "run `parrot setup`, or enable parrot in System Settings → Privacy & Security → Microphone"
            )
        default:
            break
        }

        // Don't look in ~/Documents for an old cache: under launchd that read
        // is denied or prompts. Name the command that can migrate instead.
        if !WhisperKitTranscriber.isCached(chosenModel) {
            FileHandle.standardError.write(Data(
                "\(chosenModel.id) not in \(Paths.appSupport.path), downloading. to reuse a copy from ~/Documents/huggingface, run `parrot setup` instead.\n".utf8
            ))
        }

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
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw SilentExit(1)
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
                        FileHandle.standardError.write(Data("● recording\n".utf8))
                        MainActor.assumeIsolated {
                            overlay?.show(.recording)
                            menuBar.setRecording(true)
                        }
                    } catch {
                        FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                    }
                case .released:
                    let samples = capture.stop()
                    MainActor.assumeIsolated {
                        overlay?.show(.transcribing)
                        menuBar.setTranscribing()
                    }
                    let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                    let rms = computeRMS(samples)
                    FileHandle.standardError.write(Data(
                        String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
                    ))
                    if dumpWav, !samples.isEmpty {
                        do {
                            let dir = try Paths.prepareDirectory(Paths.caches)
                            let path = try Paths.preparePrivateFile(dir.appendingPathComponent("last-capture.wav")).path
                            try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                            FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                        } catch {
                            FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
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
                            FileHandle.standardError.write(Data(
                                String(format: "→ %.2fs · %d chars\n", elapsed, text.count).utf8
                            ))
                            await MainActor.run {
                                TextInjector.inject(text)
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        } catch {
                            FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                            await MainActor.run {
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            throw SilentExit(1)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data("listening on fn hold · model: \(chosenModel.id) · ^C to quit\n".utf8))
        app.run()
    }

    /// A startup failure the user has to fix. The LaunchAgent's
    /// KeepAlive{SuccessfulExit: false} relaunches on nonzero exit, and a
    /// relaunch can't fix these, so print the fix once and exit 0. Crashes
    /// and warmup errors still exit nonzero and get restarted.
    private static func permanentFailure(_ problem: String, fix: String) -> SilentExit {
        FileHandle.standardError.write(Data((
            "\(problem)\n"
            + "  fix: \(fix), then restart parrot "
            + "(`launchctl kickstart gui/\(getuid())/\(LaunchAgent.label)`, or log in again).\n"
        ).utf8))
        return SilentExit(0)
    }
}
