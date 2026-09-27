import ArgumentParser
import Foundation

/// Manage parrot's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since parrot ships as a single binary in /usr/local/bin, a
/// plain LaunchAgent plist is the simpler, more honest mechanism.
struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or remove the launch-at-login LaunchAgent."
    )

    @Flag(name: .long, help: "Register parrot to start at login.")
    var launchAtLogin: Bool = false

    @Flag(name: .long, help: "Remove the launch-at-login agent.")
    var uninstall: Bool = false

    func run() throws {
        if launchAtLogin == uninstall {
            FileHandle.standardError.write(Data(
                "specify exactly one of --launch-at-login or --uninstall\n".utf8
            ))
            throw ExitCode(64)
        }

        if uninstall {
            try removeAgent()
            removeLegacyTmpFiles()
        } else {
            try writeAgent()
        }
    }

    // MARK: -

    static let label = "com.digimata.parrot"

    private var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    private var outLog: URL { Paths.logs.appendingPathComponent("parrot.out.log") }
    private var errLog: URL { Paths.logs.appendingPathComponent("parrot.err.log") }

    private func writeAgent() throws {
        let binary = try resolveBinaryPath()

        // launchd opens these as the user; the 0700 directory keeps them
        // private. No Umask key: it would also apply to WhisperKit's model
        // directories and break downloads from the daemon.
        try Paths.prepareDirectory(Paths.logs)
        try Paths.preparePrivateFile(outLog)
        try Paths.preparePrivateFile(errLog)

        // Move old models now, while we have the terminal's ~/Documents
        // access. The daemon can't read ~/Documents.
        WhisperKitTranscriber.migrateLegacyModels()

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [binary, "run", "--skip-doctor"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false] as [String: Any],
            "ProcessType": "Interactive",
            "StandardOutPath": outLog.path,
            "StandardErrorPath": errLog.path,
        ]

        let url = plistURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)

        // Best-effort bootstrap; ignore failure if already loaded.
        _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
        // After bootout so the old agent is gone, before bootstrap so the
        // new one doesn't find them and warn.
        removeLegacyTmpFiles()
        let result = runLaunchctl(["bootstrap", "gui/\(uid())", url.path])
        if result.status != 0 {
            FileHandle.standardError.write(Data(
                "warning: launchctl bootstrap exited \(result.status):\n\(result.stderr)\n".utf8
            ))
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   \(Paths.logs.path)/")
    }

    private func removeAgent() throws {
        let url = plistURL
        if FileManager.default.fileExists(atPath: url.path) {
            _ = runLaunchctl(["bootout", "gui/\(uid())", url.path])
            try FileManager.default.removeItem(at: url)
            print("✓ launch-at-login removed")
        } else {
            print("nothing to remove (no agent at \(url.path))")
        }
        for dir in [Paths.logs, Paths.caches] where Paths.fileType(dir.path) != nil {
            try FileManager.default.removeItem(at: dir)
            print("  removed \(dir.path)")
        }
    }

    /// Delete the pre-0.0.6 /tmp logs and capture. They hold the user's
    /// transcripts; only touch files this user owns.
    private func removeLegacyTmpFiles() {
        for path in Paths.legacyTmpFiles {
            guard
                let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == uid()
            else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
                print("  removed \(path)")
            } catch {
                FileHandle.standardError.write(Data("warning: couldn't remove \(path): \(error)\n".utf8))
            }
        }
    }

    private func resolveBinaryPath() throws -> String {
        // /usr/local/bin/parrot is the canonical install path. Honor a real
        // location if running from elsewhere (e.g. dev).
        let candidate = "/usr/local/bin/parrot"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to the running executable's resolved path.
        let argv0 = CommandLine.arguments.first ?? "parrot"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            FileHandle.standardError.write(Data(
                "note: /usr/local/bin/parrot not found; using \(argv0)\n".utf8
            ))
            return argv0
        }
        FileHandle.standardError.write(Data(
            "couldn't locate the parrot binary. install it to /usr/local/bin/parrot first.\n".utf8
        ))
        throw ExitCode(1)
    }

    private func uid() -> uid_t { getuid() }

    private func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = args
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return (-1, "\(error)")
        }
        task.waitUntilExit()
        let err = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return (task.terminationStatus, err)
    }
}
