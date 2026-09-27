import Foundation

/// The `parrot` command on `PATH`: a symlink from `Paths.commandLineLink` to
/// the executable inside Parrot.app. The app and `parrot install --cli`
/// offer it; neither replaces a plain binary without asking.
public enum CommandLineLink {
    /// `parrot install --cli`: link `Paths.commandLineLink` to this app's
    /// executable. Asks on the terminal before replacing anything.
    public static func installFromTerminal() throws {
        guard AppBundle.current != nil, let executable = Bundle.main.executableURL else {
            Log.error("the parrot command links into Parrot.app. Install the app from the DMG, then run "
                + "/Applications/Parrot.app/Contents/MacOS/parrot install --cli")
            throw SilentExit(1)
        }
        let link = Paths.commandLineLink
        switch state(at: link, target: executable) {
        case .linked:
            print("✓ \(link.path) already points to \(executable.path)")
            return
        case .missing:
            break
        case .other:
            Log.error("\(link.path) is not a file or a link; remove it yourself, then run this again.")
            throw SilentExit(1)
        case .plainFile, .linkedElsewhere:
            guard isatty(STDIN_FILENO) != 0 else {
                Log.error("\(link.path) exists (\(describe(link))). Not replacing it without a terminal to ask on.")
                throw SilentExit(1)
            }
            print("\(link.path) exists (\(describe(link))).")
            guard confirm("Replace it with a link to \(executable.path)?") else {
                print("left \(link.path) as it was")
                return
            }
        }
        do {
            try install(at: link, target: executable, privileged: false)
        } catch LinkError.notWritable(let dir) {
            Log.error("\(dir) is not writable. Run:\n  sudo \(shellQuote(executable.path)) install --cli")
            throw SilentExit(1)
        }
        print("✓ \(link.path) → \(executable.path)")
    }

    private static func describe(_ link: URL) -> String {
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            return "a link to \(destination)"
        }
        return "a separate parrot program, likely from an earlier install"
    }

    private static func confirm(_ question: String) -> Bool {
        print("\(question) [y/N] ", terminator: "")
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    enum State: Equatable {
        /// Nothing at the link path.
        case missing
        /// A symlink to `target`: nothing to do.
        case linked
        /// A symlink to somewhere else, such as a Parrot.app that moved.
        case linkedElsewhere(String)
        /// A regular file: the binary a pre-app install put there.
        case plainFile
        /// A directory or anything else. Left alone.
        case other
    }

    /// What is at `link` now, compared with `target`.
    static func state(at link: URL, target: URL) -> State {
        guard let type = Paths.fileType(link.path) else { return .missing }
        switch type {
        case .typeSymbolicLink:
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
                return .other
            }
            let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
            if resolved.standardizedFileURL.resolvingSymlinksInPath().path
                == target.standardizedFileURL.resolvingSymlinksInPath().path {
                return .linked
            }
            return .linkedElsewhere(destination)
        case .typeRegular:
            return .plainFile
        default:
            return .other
        }
    }

    /// Points `link` at `target`, replacing a file or link already there.
    /// Call only after the user agreed to replace whatever `state` reported.
    /// Uses an administrator prompt when the directory is not writable and
    /// `privileged` is true; otherwise throws on a permission error.
    static func install(at link: URL, target: URL, privileged: Bool) throws {
        let dir = link.deletingLastPathComponent()
        let fm = FileManager.default
        if isWritable(dir) {
            if Paths.fileType(link.path) != nil {
                try fm.removeItem(at: link)
            }
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
            return
        }
        guard privileged else { throw LinkError.notWritable(dir.path) }
        try runAsAdministrator(
            "/bin/mkdir -p \(shellQuote(dir.path)) && /bin/ln -sfn \(shellQuote(target.path)) \(shellQuote(link.path))"
        )
    }

    enum LinkError: Error, CustomStringConvertible {
        case notWritable(String)
        case cancelled
        case failed(String)

        var description: String {
            switch self {
            case .notWritable(let dir): return "\(dir) is not writable"
            case .cancelled: return "cancelled"
            case .failed(let message): return message
            }
        }
    }

    private static func isWritable(_ dir: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: dir.path)
    }

    /// Runs `command` through osascript's administrator prompt. The system
    /// dialog asks for the password; Parrot never sees it.
    private static func runAsAdministrator(_ command: String) throws {
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe()
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            let message = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // osascript reports a cancelled password dialog as error -128.
            if message.contains("-128") { throw LinkError.cancelled }
            throw LinkError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
