import Foundation

/// Manage parrot's LaunchAgent so the daemon starts at login.
///
/// We deliberately do NOT use SMAppService.mainApp here — that requires a full
/// .app bundle. Since parrot ships as a single binary in /usr/local/bin, a
/// plain LaunchAgent plist is the simpler, more honest mechanism.
public enum LaunchAgent {
    /// Register parrot to start at login (`parrot install --launch-at-login`).
    public static func install() throws {
        try writeAgent()
    }

    /// Remove the agent and its logs (`parrot install --uninstall`).
    public static func uninstall() throws {
        try removeAgent()
        removeLegacyTmpFiles()
    }

    // MARK: -

    static let label = "com.digimata.parrot"

    private static var plistURL: URL { Paths.launchAgentPlist(label: label) }
    private static var outLog: URL { Paths.daemonOutLog }
    private static var errLog: URL { Paths.daemonErrLog }

    private static func writeAgent() throws {
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
            Log.warning("launchctl bootstrap exited \(result.status):\n\(result.stderr)")
        }

        print("✓ launch-at-login installed")
        print("  plist:  \(url.path)")
        print("  binary: \(binary)")
        print("  logs:   \(Paths.logs.path)/")
    }

    private static func removeAgent() throws {
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
    private static func removeLegacyTmpFiles() {
        for path in Paths.legacyTmpFiles {
            guard
                let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == uid()
            else { continue }
            do {
                try FileManager.default.removeItem(atPath: path)
                print("  removed \(path)")
            } catch {
                Log.warning("couldn't remove \(path): \(error)")
            }
        }
    }

    private static func resolveBinaryPath() throws -> String {
        // /usr/local/bin/parrot is the canonical install path. Honor a real
        // location if running from elsewhere (e.g. dev).
        let candidate = Paths.installedBinary
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        // Fall back to the running executable's resolved path.
        let argv0 = CommandLine.arguments.first ?? "parrot"
        if argv0.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: argv0) {
            Log.info("note: \(candidate) not found; using \(argv0)")
            return argv0
        }
        Log.error("couldn't locate the parrot binary. install it to \(candidate) first.")
        throw SilentExit(1)
    }

    private static func uid() -> uid_t { getuid() }

    private static func runLaunchctl(_ args: [String]) -> (status: Int32, stderr: String) {
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
