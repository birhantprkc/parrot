/// Ends a command with `code` after its message has already been printed.
/// The entry point maps it to an exit code without printing anything more.
public struct SilentExit: Error {
    public let code: Int32

    public init(_ code: Int32) {
        self.code = code
    }
}
