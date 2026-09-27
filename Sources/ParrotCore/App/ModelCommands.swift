import Foundation

/// Behind `parrot models list` and `parrot models download <id>`.
public enum ModelCommands {
    public static func list() {
        for m in ModelRegistry.shared {
            let star = m.recommended ? "★" : " "
            let id = m.id.padding(toLength: 26, withPad: " ", startingAt: 0)
            let langs = "[\(m.languages.joined(separator: ","))]"
                .padding(toLength: 9, withPad: " ", startingAt: 0)
            let size = String(format: "%5d MB", m.sizeMB)
            print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
        }
    }

    public static func download(_ id: String) throws {
        guard let m = ModelRegistry.find(id) else {
            print("unknown model: \(id)")
            throw SilentExit(1)
        }
        WhisperKitTranscriber.migrateLegacyModels()
        let t = WhisperKitTranscriber(model: m)

        let sem = DispatchSemaphore(value: 0)
        var capturedError: Error?
        Task.detached {
            do { try await t.warmUp() } catch { capturedError = error }
            sem.signal()
        }
        sem.wait()
        if let e = capturedError { throw e }
    }
}
