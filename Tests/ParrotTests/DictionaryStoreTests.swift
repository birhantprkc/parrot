import XCTest
@testable import ParrotCore

final class DictionaryParseTests: XCTestCase {
    private func parse(_ text: String) throws -> UserDictionary {
        try UserDictionary.parse(Data(text.utf8))
    }

    private func parseError(_ text: String) -> DictionaryParseError? {
        do {
            _ = try parse(text)
            return nil
        } catch {
            return error as? DictionaryParseError
        }
    }

    func testTheAgreedExample() throws {
        let dictionary = try parse("""
            # Words Parrot should spell your way. Replaces lists what it writes instead.
            # Separate the columns with two spaces or a tab.

            Word          Replaces
            Vercel        Versailles, Vercell, ver cell
            Omnigraph     omni graph, omnigraf
            WhisperKit    whisper kit
            Parakeet

            """)
        XCTAssertEqual(dictionary.terms, ["Vercel", "Omnigraph", "WhisperKit", "Parakeet"])
        XCTAssertEqual(dictionary.replacements, [
            .init(from: ["Versailles", "Vercell", "ver cell"], to: "Vercel"),
            .init(from: ["omni graph", "omnigraf"], to: "Omnigraph"),
            .init(from: ["whisper kit"], to: "WhisperKit"),
        ])
        XCTAssertEqual(dictionary.examples, [:])
    }

    func testEmptyAndCommentOnlyFilesAreEmpty() throws {
        XCTAssertEqual(try parse(""), .empty)
        XCTAssertEqual(try parse("\n\n   \n"), .empty)
        XCTAssertEqual(try parse("# only a comment\n  # indented, with, commas\n"), .empty)
    }

    func testHeaderIsSkippedInAnyCaseAndAnywhere() throws {
        let dictionary = try parse("A\nword\tREPLACES\nB  b\nWord    Replaces\n")
        XCTAssertEqual(dictionary.terms, ["A", "B"])
        // "Word" alone is a word, not a header.
        XCTAssertEqual(try parse("Word\n").terms, ["Word"])
    }

    func testTabAndMultiSpaceSeparators() throws {
        let dictionary = try parse("Tab\tt a b\nTwo  two\nMany        many, more\nMixed \t mixed\n")
        XCTAssertEqual(dictionary.replacements, [
            .init(from: ["t a b"], to: "Tab"),
            .init(from: ["two"], to: "Two"),
            .init(from: ["many", "more"], to: "Many"),
            .init(from: ["mixed"], to: "Mixed"),
        ])
    }

    func testASingleSpaceIsPartOfTheWord() throws {
        let dictionary = try parse("Claude Code  cloud code, clawed code\nNew York\n")
        XCTAssertEqual(dictionary.terms, ["Claude Code", "New York"])
        XCTAssertEqual(dictionary.replacements, [.init(from: ["cloud code", "clawed code"], to: "Claude Code")])
    }

    func testEmptyReplacesIsATermOnly() throws {
        let dictionary = try parse("Parakeet\nPostHog  \nKubernetes  , ,  \n")
        XCTAssertEqual(dictionary.terms, ["Parakeet", "PostHog", "Kubernetes"])
        XCTAssertEqual(dictionary.replacements, [])
    }

    func testWhitespaceIsTrimmed() throws {
        let dictionary = try parse("  Vercel   \t  Versailles ,  ver cell  ,, \t \r\nOmnigraph\t\t\r\n")
        XCTAssertEqual(dictionary.terms, ["Vercel", "Omnigraph"])
        XCTAssertEqual(dictionary.replacements, [.init(from: ["Versailles", "ver cell"], to: "Vercel")])
    }

    func testACommaInTheWordIsAMissingSeparator() {
        let text = "# comment\n\nWord  Replaces\nWhisperKit  whisper kit\n\nVercel Versailles, secret-word\nOmnigraph\n"
        let error = parseError(text)
        XCTAssertEqual(error, .missingSeparator(line: 6))
        XCTAssertEqual(error?.description, "line 6: separate the word from Replaces with two spaces or a tab")
        XCTAssertFalse(error!.description.contains("secret-word"))
        XCTAssertFalse(error!.description.contains("Vercel"))
    }

    func testCRLFCountsLines() {
        XCTAssertEqual(parseError("A\r\nB\r\nC, D\r\n"), .missingSeparator(line: 3))
    }

    func testNotUTF8IsRefused() {
        XCTAssertThrowsError(try UserDictionary.parse(Data([0x41, 0xFF, 0x0A]))) { error in
            XCTAssertEqual(error as? DictionaryParseError, .notText)
        }
    }

    func testByteOrderMarkIsIgnored() throws {
        XCTAssertEqual(try UserDictionary.parse(Data("\u{FEFF}Vercel  ver cell\n".utf8)).terms, ["Vercel"])
    }

    // MARK: Writing

    func testTextRoundTrips() throws {
        let dictionary = UserDictionary(
            terms: ["Vercel", "Claude Code", "Parakeet"],
            replacements: [
                .init(from: ["Versailles", "ver cell"], to: "Vercel"),
                .init(from: ["cloud code"], to: "Claude Code"),
            ]
        )
        let (text, rows, skipped) = dictionary.text()
        XCTAssertEqual([rows, skipped], [3, 0])
        XCTAssertEqual(text, """
            # Words Parrot should spell your way. Replaces lists what it writes instead.
            # Separate the columns with two spaces or a tab.

            Word           Replaces
            Vercel         Versailles, ver cell
            Claude Code    cloud code
            Parakeet

            """)
        XCTAssertEqual(try UserDictionary.parse(Data(text.utf8)), dictionary)
    }

    func testTextMergesTargetsAndAddsTargetsThatAreNotTerms() throws {
        let dictionary = UserDictionary(
            terms: ["A"],
            replacements: [
                .init(from: ["a1"], to: "A"),
                .init(from: ["k8s"], to: "Kubernetes"),
                .init(from: ["a2", "a1"], to: "A"),
            ]
        )
        let parsed = try UserDictionary.parse(Data(dictionary.text().text.utf8))
        XCTAssertEqual(parsed.terms, ["A", "Kubernetes"])
        XCTAssertEqual(parsed.replacements, [.init(from: ["a1", "a2"], to: "A"), .init(from: ["k8s"], to: "Kubernetes")])
    }

    func testTextSkipsWhatTheTableCannotHold() throws {
        let dictionary = UserDictionary(
            terms: ["Smith, John", "#hashtag", "Tab\tbed"],
            replacements: [.init(from: ["one, two", "three"], to: "Three")]
        )
        let (text, rows, skipped) = dictionary.text()
        XCTAssertEqual([rows, skipped], [2, 3])
        let parsed = try UserDictionary.parse(Data(text.utf8))
        XCTAssertEqual(parsed.terms, ["Tab bed", "Three"])
        XCTAssertEqual(parsed.replacements, [.init(from: ["three"], to: "Three")])
    }

    func testTemplateIsTheAgreedShape() {
        XCTAssertEqual(UserDictionary.template, """
            # Words Parrot should spell your way. Replaces lists what it writes instead.
            # Separate the columns with two spaces or a tab.

            Word          Replaces
            WhisperKit    whisper kit

            """)
    }

    // MARK: Examples

    func testExampleMatchesLanguage() {
        let dictionary = UserDictionary(examples: ["en": "English.", "pt-BR": "Português.", "de": "  "])
        XCTAssertEqual(dictionary.example(for: "en"), "English.")
        XCTAssertEqual(dictionary.example(for: "EN-us"), "English.")
        XCTAssertEqual(dictionary.example(for: "pt"), "Português.")
        XCTAssertEqual(dictionary.example(for: "pt-BR"), "Português.")
    }

    func testNoExampleWhenLanguageDoesNotMatch() {
        let dictionary = UserDictionary(examples: ["pt-BR": "Português.", "de": "  "])
        XCTAssertNil(dictionary.example(for: "en"))
        XCTAssertNil(dictionary.example(for: "de"), "a blank sentence is no sentence")
        XCTAssertNil(dictionary.example(for: nil))
        XCTAssertNil(dictionary.example(for: ""))
    }

    func testVocabularyIsTermsAndTargets() {
        let dictionary = UserDictionary(
            terms: ["PostHog", " WhisperKit "],
            replacements: [.init(from: ["post hog"], to: "PostHog"), .init(from: ["k8s"], to: "Kubernetes")]
        )
        XCTAssertEqual(dictionary.vocabulary, ["PostHog", "WhisperKit", "Kubernetes"])
    }
}

/// The old `dictionary.json` parser, kept for the one-time conversion.
final class LegacyDictionaryParseTests: XCTestCase {
    private func parse(_ json: String) throws -> UserDictionary {
        try UserDictionary.parseLegacyJSON(Data(json.utf8))
    }

    private func parseError(_ json: String) -> LegacyDictionaryError? {
        do {
            _ = try parse(json)
            return nil
        } catch {
            return error as? LegacyDictionaryError
        }
    }

    func testMissingKeysAreEmptyAndUnknownKeysIgnored() throws {
        XCTAssertEqual(try parse("{}"), .empty)
        XCTAssertEqual(try parse(#"{"terms": ["A"], "future": 1}"#), UserDictionary(terms: ["A"]))
    }

    func testFullFormat() throws {
        let dictionary = try parse(#"""
            {
              "terms": ["PostHog"],
              "replacements": [{ "from": ["post hog"], "to": "PostHog" }],
              "examples": { "en": "One sentence.", "pt-BR": "Uma frase." }
            }
            """#)
        XCTAssertEqual(dictionary.terms, ["PostHog"])
        XCTAssertEqual(dictionary.replacements, [.init(from: ["post hog"], to: "PostHog")])
        XCTAssertEqual(dictionary.examples, ["en": "One sentence.", "pt-BR": "Uma frase."])
    }

    func testSyntaxErrorNamesLineAndColumn() {
        let error = parseError("{\n  \"terms\": [\"secret-word\" \"x\"]\n}")
        guard case .syntax(let position?) = error else {
            return XCTFail("expected a syntax error with a position, got \(String(describing: error))")
        }
        XCTAssertEqual(position.line, 2)
        XCTAssertTrue(error!.description.hasPrefix("invalid JSON at line 2, column "), error!.description)
        XCTAssertFalse(error!.description.contains("secret-word"))
    }

    func testSchemaErrorNamesTheKeyPath() {
        XCTAssertEqual(parseError(#"{"terms": "PostHog"}"#)?.description, "terms: expected an array")
        XCTAssertEqual(
            parseError(#"{"replacements": [{"from": ["a"], "to": "A"}, {"from": ["b"]}]}"#)?.description,
            "replacements[1].to: missing"
        )
        XCTAssertEqual(parseError(#"{"examples": {"en": 1}}"#)?.description, "examples.en: expected a string")
        XCTAssertEqual(parseError(#"["PostHog"]"#), .notAnObject)
        guard case .syntax = parseError("") else { return XCTFail("empty file is a syntax error") }
    }

    func testPositionCountsCharactersNotBytes() {
        let data = Data("{\"é\": x}".utf8)
        // Byte offset 7 is "x"; "é" is two bytes but one column.
        XCTAssertEqual(UserDictionary.Position(offset: 7, in: data), .init(line: 1, column: 7))
    }
}

final class DictionaryStoreTests: XCTestCase {
    private var dir: TemporaryDirectory!
    private var logs: [String] = []

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
        logs = []
    }

    override func tearDown() {
        dir = nil
    }

    private func store(_ file: URL) -> DictionaryStore {
        DictionaryStore(file: file, log: { [unowned self] in self.logs.append($0) })
    }

    private func write(_ text: String, to file: URL) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    func testCreatesTheTemplateWhenNothingExists() throws {
        let file = dir.url.appendingPathComponent("config/parrot/dictionary")
        let store = store(file)
        XCTAssertTrue(store.createIfMissing())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), UserDictionary.template)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertFalse(store.createIfMissing(), "never overwrites")

        let loaded = store.current().dictionary
        XCTAssertEqual(loaded.terms, ["WhisperKit"])
        XCTAssertEqual(loaded.replacements, [.init(from: ["whisper kit"], to: "WhisperKit")])
        XCTAssertEqual(logs, [])
    }

    func testDoesNotCreateOverADanglingSymlink() throws {
        let file = dir.url.appendingPathComponent("dictionary")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: dir.url.appendingPathComponent("missing"))
        XCTAssertFalse(store(file).createIfMissing())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("missing").path))
    }

    func testReloadsWhenTheFileChanges() throws {
        let file = dir.url.appendingPathComponent("dictionary")
        try write("One\n", to: file)
        let store = store(file)
        XCTAssertEqual(store.current().dictionary.terms, ["One"])
        try write("One\nTwo  too\n", to: file)
        XCTAssertEqual(store.current().dictionary.terms, ["One", "Two"])
        XCTAssertEqual(store.current().replacer.apply(to: "two too"), "Two Two")
    }

    func testMalformedFileKeepsTheLastGoodVersionAndLogsOnce() throws {
        let file = dir.url.appendingPathComponent("dictionary")
        try write("Good\n", to: file)
        let store = store(file)
        XCTAssertEqual(store.current().dictionary.terms, ["Good"])

        try write("Word  Replaces\nGood\nsecret-word other, words\n", to: file)
        XCTAssertEqual(store.current().dictionary.terms, ["Good"])
        XCTAssertEqual(store.current().dictionary.terms, ["Good"])
        XCTAssertEqual(logs.count, 1, "\(logs)")
        XCTAssertTrue(logs[0].contains("line 3"), logs[0])
        XCTAssertFalse(logs[0].contains("secret-word"), logs[0])

        try write("Fixed\n", to: file)
        XCTAssertEqual(store.current().dictionary.terms, ["Fixed"])
    }

    func testMalformedFileOnFirstLoadGivesAnEmptyDictionary() throws {
        let file = dir.url.appendingPathComponent("dictionary")
        try write("no separator, here\n", to: file)
        XCTAssertEqual(store(file).current().dictionary, .empty)
        XCTAssertEqual(logs.count, 1)
    }

    func testTooLargeFileKeepsTheLastGoodVersion() throws {
        let file = dir.url.appendingPathComponent("dictionary")
        try write("Good\n", to: file)
        let store = store(file)
        XCTAssertEqual(store.current().dictionary.terms, ["Good"])
        try write(String(repeating: "Word\n", count: DictionaryStore.maxBytes / 5 + 1), to: file)
        XCTAssertEqual(store.current().dictionary.terms, ["Good"])
        XCTAssertEqual(logs.count, 1, "\(logs)")
        XCTAssertTrue(logs[0].contains("larger than"), logs[0])
    }

    func testMissingFileIsAnEmptyDictionary() throws {
        let file = dir.url.appendingPathComponent("dictionary")
        try write("Gone\n", to: file)
        let store = store(file)
        XCTAssertEqual(store.current().dictionary.terms, ["Gone"])
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(store.current().dictionary, .empty)
    }

    func testFollowsASymlinkedFile() throws {
        let dotfiles = dir.url.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("dictionary")
        try write("Linked\n", to: target)
        let file = dir.url.appendingPathComponent("dictionary")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        let store = store(file)
        XCTAssertFalse(store.createIfMissing())
        XCTAssertEqual(store.current().dictionary.terms, ["Linked"])
        // An editor's atomic save replaces the target; the link still resolves.
        try write("Linked\nEdited\n", to: target)
        XCTAssertEqual(store.current().dictionary.terms, ["Linked", "Edited"])
        XCTAssertEqual(logs, [])
    }

    func testFollowsASymlinkedDirectory() throws {
        let dotfiles = dir.url.appendingPathComponent("dotfiles/parrot", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let config = dir.url.appendingPathComponent("config-parrot")
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: dotfiles)
        let file = config.appendingPathComponent("dictionary")

        let store = store(file)
        XCTAssertTrue(store.createIfMissing(), "creates the file inside the linked directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dotfiles.appendingPathComponent("dictionary").path))
        XCTAssertEqual(Paths.fileType(config.path), .typeSymbolicLink, "the link is left alone")
        XCTAssertFalse(store.current().dictionary.terms.isEmpty)
        XCTAssertEqual(logs, [])
    }

    func testRefusesSomethingThatIsNotAFile() throws {
        let file = dir.url.appendingPathComponent("dictionary")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let store = store(file)
        XCTAssertEqual(store.current().dictionary, .empty)
        _ = store.current()
        XCTAssertEqual(logs.count, 1, "\(logs)")
        XCTAssertTrue(logs[0].contains("not a regular file"), logs[0])
    }
}
