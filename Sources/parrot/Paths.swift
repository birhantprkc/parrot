import Foundation

/// Where parrot keeps files on disk. Everything lives under ~/Library, never
/// /tmp or ~/Documents. Directories are owner-only (0700).
enum Paths {
    /// `~/Library/Logs/parrot` — the LaunchAgent's stdout/stderr.
    static var logs: URL { library("Logs/parrot") }

    /// `~/Library/Caches/parrot` — debug output such as `--dump-wav`.
    static var caches: URL { library("Caches/parrot") }

    /// Pre-0.0.6 files that held transcripts and audio in world-readable /tmp.
    static let legacyTmpFiles = ["/tmp/parrot.out.log", "/tmp/parrot.err.log", "/tmp/parrot-last.wav"]

    /// Creates `dir` if needed and restricts it to the owner. Refuses a path
    /// that exists but isn't a real directory (e.g. a symlink).
    @discardableResult
    static func prepareDirectory(_ dir: URL) throws -> URL {
        let fm = FileManager.default
        if let type = fileType(dir.path) {
            guard type == .typeDirectory else { throw PathError.notADirectory(dir.path) }
        } else {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// Creates `file` empty at 0600 if missing, or tightens an existing one.
    /// Refuses a symlink or anything else that isn't a regular file.
    @discardableResult
    static func preparePrivateFile(_ file: URL) throws -> URL {
        let fm = FileManager.default
        if let type = fileType(file.path) {
            guard type == .typeRegular else { throw PathError.notARegularFile(file.path) }
        } else {
            // O_EXCL | O_NOFOLLOW: never write through a link planted after the check.
            let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw PathError.notARegularFile(file.path) }
            close(fd)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// The type of the item at `path` without following symlinks, or nil if
    /// nothing is there.
    static func fileType(_ path: String) -> FileAttributeType? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.type] as? FileAttributeType
    }

    private static func library(_ sub: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(sub, isDirectory: true)
    }
}

enum PathError: Error, CustomStringConvertible {
    case notADirectory(String)
    case notARegularFile(String)

    var description: String {
        switch self {
        case .notADirectory(let p): return "\(p) exists but is not a directory"
        case .notARegularFile(let p): return "\(p) is a symlink or not a regular file"
        }
    }
}
