import ArgumentParser
import Foundation
import ParrotCore

// The entry point parses flags and calls ParrotCore. Behaviour lives there.

struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold Fn, speak, release.",
        version: AppBundle.version,
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Install.self, Bench.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print each modifier change the hotkey tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to ~/Library/Caches/parrot/last-capture.wav for inspection.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Option(
        name: .long,
        help: "How text is inserted: paste (default; borrows the clipboard and restores it) or type-unicode.",
        transform: { raw in
            guard let mode = InjectMode(rawValue: raw) else {
                throw ValidationError("expected one of: \(InjectMode.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return mode
        }
    )
    var injectMode: InjectMode = .paste

    func run() throws {
        // The app and a foreground run would both paste every dictation.
        guard AppLaunch.claimSingleInstance() else {
            Log.error("Parrot is already running. Quit it from the menu bar first.")
            throw ExitCode(1)
        }
        do {
            try Daemon.run(DaemonOptions(
                skipDoctor: skipDoctor,
                debugHotkey: debugHotkey,
                dumpWav: dumpWav,
                noOverlay: noOverlay,
                model: model,
                injectMode: injectMode
            ))
        } catch let failure as StartupFailure {
            // The one exit-code rule. A supervisor that relaunches on nonzero
            // exit can't fix a permanent failure, so print its fix once and
            // exit 0. Everything else exits nonzero. The app has no terminal,
            // so it also shows the failure in a dialog.
            Log.error(failure.message)
            MainActor.assumeIsolated { AppLaunch.presentStartupFailure(failure) }
            throw ExitCode(failure.isPermanent ? 0 : 1)
        }
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Walk through first-run permission setup."
    )

    func run() throws {
        try exiting { try SetupFlow.run() }
    }
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            ModelCommands.list()
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            try exiting { try ModelCommands.download(id) }
        }
    }
}

/// `parrot bench <folder>` times transcription; `parrot bench capture` times
/// the microphone.
struct Bench: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measure latency: the model over recordings, or microphone capture.",
        subcommands: [BenchTranscription.self, BenchCapture.self],
        defaultSubcommand: BenchTranscription.self
    )
}

/// Press-to-first-sample of the default input (#52).
struct BenchCapture: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture",
        abstract: "Time press-to-first-sample on the default input, cold and warm.",
        discussion: """
            Opens and closes the default input the way a dictation does and \
            prints the median and p90, in milliseconds, of the time from the \
            press to the first captured sample, cold (after --idle seconds \
            without capture) and warm (--gap seconds after the last). It also \
            checks between presses that the input is not running. Speak or \
            not; no audio is kept.
            """
    )

    @Option(name: .long, help: "Rounds: one cold and one warm capture each.") var runs: Int = 5

    @Option(name: .long, help: "Seconds without capture before each cold capture.") var idle: Double = 300

    @Option(name: .long, help: "Seconds between a cold capture and the warm one.") var gap: Double = 2

    @Option(name: .long, help: "Seconds to hold each capture after its first buffer.") var hold: Double = 0.5

    @Option(
        name: .long,
        help: "Capture mode: \(CaptureMode.allCases.map(\.rawValue).joined(separator: ", ")).",
        transform: { raw in
            guard let mode = CaptureMode(rawValue: raw) else {
                throw ValidationError("expected one of: \(CaptureMode.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return mode
        }
    )
    var mode: CaptureMode = .standard

    func run() throws {
        try exiting {
            try CaptureBench.run(CaptureBenchOptions(runs: runs, idle: idle, gap: gap, hold: hold, mode: mode))
        }
    }
}

/// Transcription latency over local recordings (#49).
struct BenchTranscription: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcription",
        abstract: "Time the model over a folder of recordings: median and p90 per stage.",
        discussion: """
            Runs the model over every .wav file in the folder and prints each \
            transcription stage's median and p90 in milliseconds. A .txt file \
            beside a recording, holding what was said, adds its word error rate. \
            Prints timings and counts, never transcript text.
            """
    )

    @Argument(help: "Folder of .wav recordings.") var folder: String

    @Option(name: .long, help: "Timed runs per file.") var runs: Int = 10

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.") var model: String?

    @Option(name: .long, help: "Prompt text to use instead of the dictionary's example sentence.") var prompt: String?

    @Flag(name: .long, help: "Run without a prompt.") var noPrompt: Bool = false

    @Flag(name: .long, help: "Use WhisperKit's default settings, as Parrot ran before #49, to compare.") var baseline: Bool = false

    @Option(name: .long, help: "Compute units for the audio encoder: ane, gpu, cpu or all.") var encoder: String?

    @Option(name: .long, help: "Compute units for the text decoder: ane, gpu, cpu or all.") var decoder: String?

    @Option(name: .long, help: "Seconds to sit idle before each timed run.") var pause: Double = 0

    func run() throws {
        try exiting {
            try ParrotCore.Bench.run(BenchOptions(
                folder: folder,
                runs: runs,
                model: model,
                prompt: prompt,
                noPrompt: noPrompt,
                baseline: baseline,
                encoder: encoder,
                decoder: decoder,
                pause: pause
            ))
        }
    }
}

/// Launch at login and the `parrot` command on PATH.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Set up launch at login and the parrot command, or remove them."
    )

    @Flag(name: .long, help: "Start Parrot.app at login, and start it now.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Link /usr/local/bin/parrot to the executable in Parrot.app.")
    var cli: Bool = false

    @Flag(name: .long, help: "Stop starting at login, quit Parrot, and remove its logs.")
    var uninstall: Bool = false

    func run() throws {
        if [launchAtLogin, cli, uninstall].filter({ $0 }).count != 1 {
            Log.error("specify exactly one of --launch-at-login, --cli, or --uninstall")
            throw ExitCode(64)
        }

        try exiting {
            if uninstall {
                try LoginItem.uninstall()
            } else if cli {
                try CommandLineLink.installFromTerminal()
            } else {
                try LoginItem.install()
            }
        }
    }
}

/// Maps ParrotCore's `SilentExit` to an exit code. Any other error reaches
/// ArgumentParser, which prints it and exits nonzero.
private func exiting(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let exit as SilentExit {
        throw ExitCode(exit.code)
    }
}

// Through the /usr/local/bin symlink, become the executable inside
// Parrot.app so the bundle (version, login item) is found.
AppBundle.resolveSymlinkedLaunch()

if AppLaunch.launchedAsApp {
    // Opened from Finder, `open`, or the login item: the menu-bar app.
    MainActor.assumeIsolated { AppLaunch.prepare() }
    Parrot.main(["run", "--skip-doctor"])
} else {
    Parrot.main()
}
