import Foundation

/// Diagnostic output on stderr. Under the LaunchAgent, stderr is a file in
/// `Paths.logs`, so everything written here lands on disk.
///
/// Never pass transcript text (or anything derived from it beyond counts)
/// to these functions. Log timings and lengths instead.
public enum Log {
    /// Writes `message` and a newline to stderr.
    public static func info(_ message: String) {
        write(message)
    }

    /// Writes `warning: <message>` to stderr.
    public static func warning(_ message: String) {
        write("warning: \(message)")
    }

    /// Writes `message` to stderr. Callers phrase the message; no prefix is added.
    public static func error(_ message: String) {
        write(message)
    }

    private static func write(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
