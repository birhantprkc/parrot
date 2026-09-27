import XCTest
@testable import ParrotCore

final class DictionaryParseTests: XCTestCase {
    private func parse(_ json: String) throws -> UserDictionary {
        try UserDictionary.parse(Data(json.utf8))
    }

    private func parseError(_ json: String) -> DictionaryParseError? {
        do {
            _ = try parse(json)
            return nil
        } catch {
            return error as? DictionaryParseError
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

    private func write(_ json: String, to file: URL) throws {
        try json.write(to: file, atomically: true, encoding: .utf8)
    }

    func testCreatesTheTemplateWhenNothingExists() throws {
        let file = dir.url.appendingPathComponent("config/parrot/dictionary.json")
        let store = store(file)
        XCTAssertTrue(store.createIfMissing())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), UserDictionary.template)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertFalse(store.createIfMissing(), "never overwrites")

        let loaded = store.current().dictionary
        XCTAssertFalse(loaded.terms.isEmpty)
        XCTAssertFalse(loaded.replacements.isEmpty)
        XCTAssertNotNil(loaded.example(for: "en"))
        XCTAssertEqual(logs, [])
    }

    func testDoesNotCreateOverADanglingSymlink() throws {
        let file = dir.url.appendingPathComponent("dictionary.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: dir.url.appendingPathComponent("missing.json"))
        XCTAssertFalse(store(file).createIfMissing())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.url.appendingPathComponent("missing.json").path))
    }

    func testReloadsWhenTheFileChanges() throws {
        let file = dir.url.appendingPathComponent("dictionary.json")
        try write(#"{"terms": ["One"]}"#, to: file)
        let store = store(file)
        XCTAssertEqual(store.current().dictionary.terms, ["One"])
        try write(#"{"terms": ["One", "Two"]}"#, to: file)
        XCTAssertEqual(store.current().dictionary.terms, ["One", "Two"])
        XCTAssertEqual(store.current().replacer.apply(to: "two"), "Two")
    }

    func testMalformedFileKeepsTheLastGoodVersionAndLogsOnce() throws {
        let file = dir.url.appendingPathComponent("dictionary.json")
        try write(#"{"terms": ["Good"]}"#, to: file)
        let store = store(file)
        XCTAssertEqual(store.current().dictionary.terms, ["Good"])

        try write("{\n  \"terms\": [\"secret-word\",\n", to: file)
        XCTAssertEqual(store.current().dictionary.terms, ["Good"])
        XCTAssertEqual(store.current().dictionary.terms, ["Good"])
        XCTAssertEqual(logs.count, 1, "\(logs)")
        XCTAssertTrue(logs[0].contains("line"), logs[0])
        XCTAssertFalse(logs[0].contains("secret-word"), logs[0])

        try write(#"{"terms": ["Fixed"]}"#, to: file)
        XCTAssertEqual(store.current().dictionary.terms, ["Fixed"])
    }

    func testMalformedFileOnFirstLoadGivesAnEmptyDictionary() throws {
        let file = dir.url.appendingPathComponent("dictionary.json")
        try write("not json", to: file)
        XCTAssertEqual(store(file).current().dictionary, .empty)
        XCTAssertEqual(logs.count, 1)
    }

    func testMissingFileIsAnEmptyDictionary() throws {
        let file = dir.url.appendingPathComponent("dictionary.json")
        try write(#"{"terms": ["Gone"]}"#, to: file)
        let store = store(file)
        XCTAssertEqual(store.current().dictionary.terms, ["Gone"])
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(store.current().dictionary, .empty)
    }

    func testFollowsASymlinkedFile() throws {
        let dotfiles = dir.url.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("dictionary.json")
        try write(#"{"terms": ["Linked"]}"#, to: target)
        let file = dir.url.appendingPathComponent("dictionary.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        let store = store(file)
        XCTAssertFalse(store.createIfMissing())
        XCTAssertEqual(store.current().dictionary.terms, ["Linked"])
        // An editor's atomic save replaces the target; the link still resolves.
        try write(#"{"terms": ["Linked", "Edited"]}"#, to: target)
        XCTAssertEqual(store.current().dictionary.terms, ["Linked", "Edited"])
        XCTAssertEqual(logs, [])
    }

    func testFollowsASymlinkedDirectory() throws {
        let dotfiles = dir.url.appendingPathComponent("dotfiles/parrot", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let config = dir.url.appendingPathComponent("config-parrot")
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: dotfiles)
        let file = config.appendingPathComponent("dictionary.json")

        let store = store(file)
        XCTAssertTrue(store.createIfMissing(), "creates the file inside the linked directory")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dotfiles.appendingPathComponent("dictionary.json").path))
        XCTAssertEqual(Paths.fileType(config.path), .typeSymbolicLink, "the link is left alone")
        XCTAssertFalse(store.current().dictionary.terms.isEmpty)
        XCTAssertEqual(logs, [])
    }

    func testRefusesSomethingThatIsNotAFile() throws {
        let file = dir.url.appendingPathComponent("dictionary.json")
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        let store = store(file)
        XCTAssertEqual(store.current().dictionary, .empty)
        _ = store.current()
        XCTAssertEqual(logs.count, 1, "\(logs)")
        XCTAssertTrue(logs[0].contains("not a regular file"), logs[0])
    }
}
