import Foundation

/// Converts the old `dictionary.json` to the plain-text table, once, at
/// startup: when `Paths.dictionaryFile` does not exist and
/// `Paths.legacyDictionaryFile` does.
///
/// The new file is written next to the old one's path, in the config
/// directory, and the old path is renamed to `dictionary.json.bak`. When
/// `dictionary.json` is a symlink into a dotfiles repository, the link itself
/// is renamed and the file it points to is left untouched: Parrot never
/// writes into someone's dotfiles repository on its own. The new file is a
/// regular file in the config directory; moving it into the repository and
/// linking it back is the user's call. A symlinked config directory is
/// followed, as `DictionaryStore` does, because the whole directory is the
/// user's.
///
/// The example sentences are returned for the caller to move into
/// `settings.json`; the text file has no place for them.
enum DictionaryMigration {
    enum Outcome: Equatable {
        /// There is nothing to convert, or the new file already exists.
        case nothingToDo
        /// Converted; these are the old file's example sentences.
        case converted(examples: [String: String])
        /// `dictionary.json` is there but could not be converted; it is left
        /// as it was. The caller should not write the first-run template,
        /// which would stop the next launch from trying again.
        case failed
    }

    static func run(
        file: URL = Paths.dictionaryFile,
        legacy: URL = Paths.legacyDictionaryFile,
        log: (String) -> Void = { Log.warning($0) }
    ) -> Outcome {
        guard Paths.fileType(file.path) == nil, Paths.fileType(legacy.path) != nil else { return .nothingToDo }
        let name = legacy.lastPathComponent
        func fail(_ problem: String) -> Outcome {
            log("\(name) not converted, \(problem); fix it and relaunch Parrot")
            return .failed
        }

        // The same checks the store makes: a regular file, yours, not absurd.
        let resolved = legacy.resolvingSymlinksInPath().path
        var st = stat()
        guard stat(resolved, &st) == 0 else { return fail("it points to \(resolved), which doesn't exist") }
        if let problem = DictionaryStore.problem(with: st, at: resolved) { return fail(problem) }
        let old: UserDictionary
        do {
            old = try UserDictionary.parseLegacyJSON(Data(contentsOf: URL(fileURLWithPath: resolved)))
        } catch {
            return fail("\(error)")
        }

        let (text, rows, skipped) = old.text()
        do {
            try writeNew(Data(text.utf8), to: file)
        } catch {
            return fail("couldn't write \(file.path): \(error)")
        }

        // Rename the path, not what it points to: a symlink moves as a link.
        let backup = legacy.deletingLastPathComponent().appendingPathComponent(name + ".bak")
        var kept = ""
        if renamex_np(legacy.path, backup.path, UInt32(RENAME_EXCL)) != 0 {
            kept = "; couldn't rename it to \(backup.lastPathComponent) (\(String(cString: strerror(errno)))), so it stays, unused"
        }
        let examples = old.examples.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        Log.info(
            "dictionary: converted \(name) to \(file.lastPathComponent): \(rows) words, "
                + "\(old.replacements.count) replacements, \(examples.count) example sentences, \(skipped) entries skipped\(kept)"
        )
        return .converted(examples: examples)
    }

    /// Writes `data` to `file`, which must not exist, owner-only. Goes through
    /// a temporary file and an exclusive rename, so the file is never seen
    /// half-written and nothing that appeared meanwhile is overwritten.
    private static func writeNew(_ data: Data, to file: URL) throws {
        let dir = file.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(file.lastPathComponent).\(getpid()).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            guard renamex_np(temp.path, file.path, UInt32(RENAME_EXCL)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            unlink(temp.path)
            throw error
        }
    }
}
