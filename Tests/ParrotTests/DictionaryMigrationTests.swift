import XCTest
@testable import ParrotCore

final class DictionaryMigrationTests: XCTestCase {
    private var dir: TemporaryDirectory!
    private var logs: [String] = []

    override func setUpWithError() throws {
        dir = try TemporaryDirectory()
        logs = []
    }

    override func tearDown() {
        dir = nil
    }

    private var file: URL { dir.url.appendingPathComponent("dictionary") }
    private var legacy: URL { dir.url.appendingPathComponent("dictionary.json") }
    private var backup: URL { dir.url.appendingPathComponent("dictionary.json.bak") }

    private func migrate() -> DictionaryMigration.Outcome {
        DictionaryMigration.run(file: file, legacy: legacy, log: { [unowned self] in self.logs.append($0) })
    }

    /// The maintainer's real file, exactly.
    private let maintainersFile = """
        {
          "terms": ["WhisperKit", "Omnigraph", "Vercel"],
          "replacements": [
            { "from": ["whisper kit"], "to": "WhisperKit" },
            { "from": ["omni graph", "omni-graph", "omnigraf", "omnigraft", "omni graf", "omni graft", "omnigraphe"], "to": "Omnigraph" },
            { "from": ["Versailles", "Versaille", "Vercell", "ver cell", "Versel", "Vercelle", "Verselle"], "to": "Vercel" }
          ],
          "examples": { "en": "I opened Omnigraph to check how the entities connect." }
        }
        """

    func testConvertsTheMaintainersFile() throws {
        try maintainersFile.write(to: legacy, atomically: true, encoding: .utf8)
        let old = try UserDictionary.parseLegacyJSON(Data(maintainersFile.utf8))

        XCTAssertEqual(migrate(), .converted(examples: ["en": "I opened Omnigraph to check how the entities connect."]))
        XCTAssertEqual(logs, [])

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, """
            # Words Parrot should spell your way. Replaces lists what it writes instead.
            # Separate the columns with two spaces or a tab.

            Word          Replaces
            WhisperKit    whisper kit
            Omnigraph     omni graph, omni-graph, omnigraf, omnigraft, omni graf, omni graft, omnigraphe
            Vercel        Versailles, Versaille, Vercell, ver cell, Versel, Vercelle, Verselle

            """)
        let parsed = try UserDictionary.parse(Data(text.utf8))
        XCTAssertEqual(parsed.terms, old.terms)
        XCTAssertEqual(parsed.replacements, old.replacements)

        // The corrections still apply through the store.
        let store = DictionaryStore(file: file, log: { _ in })
        XCTAssertEqual(
            store.current().replacer.apply(to: "deploy on Versailles, open omni graph and whisper kit"),
            "deploy on Vercel, open Omnigraph and WhisperKit"
        )

        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertNil(Paths.fileType(legacy.path), "the JSON is renamed")
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), maintainersFile, "and kept as it was")
        XCTAssertEqual(migrate(), .nothingToDo, "once only")
    }

    func testNothingToDoWithoutTheOldFile() {
        XCTAssertEqual(migrate(), .nothingToDo)
        XCTAssertNil(Paths.fileType(file.path))
    }

    func testNothingToDoWhenTheNewFileExists() throws {
        try "Mine\n".write(to: file, atomically: true, encoding: .utf8)
        try #"{"terms": ["Old"]}"#.write(to: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(migrate(), .nothingToDo)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Mine\n")
        XCTAssertNotNil(Paths.fileType(legacy.path), "left alone")
    }

    func testReplacementTargetThatIsNotATermBecomesARow() throws {
        try #"{"replacements": [{"from": ["k8s", "kube"], "to": "Kubernetes"}]}"#
            .write(to: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(migrate(), .converted(examples: [:]))
        let parsed = try UserDictionary.parse(Data(contentsOf: file))
        XCTAssertEqual(parsed.terms, ["Kubernetes"])
        XCTAssertEqual(parsed.replacements, [.init(from: ["k8s", "kube"], to: "Kubernetes")])
    }

    func testAFileThatDoesNotParseIsLeftAlone() throws {
        try "{\n  \"terms\": [\"secret-word\",\n".write(to: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(migrate(), .failed)
        XCTAssertNil(Paths.fileType(file.path), "no new file, so the next launch tries again")
        XCTAssertNotNil(Paths.fileType(legacy.path))
        XCTAssertEqual(logs.count, 1, "\(logs)")
        XCTAssertTrue(logs[0].contains("line"), logs[0])
        XCTAssertFalse(logs[0].contains("secret-word"), logs[0])
    }

    /// A dotfiles user's symlinked `dictionary.json`: the new file goes next to
    /// the link, the link itself becomes the backup, and the repository's
    /// file is not touched.
    func testASymlinkedFileIsNotWrittenThrough() throws {
        let dotfiles = dir.url.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        let target = dotfiles.appendingPathComponent("dictionary.json")
        try maintainersFile.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: legacy, withDestinationURL: target)

        XCTAssertEqual(migrate(), .converted(examples: ["en": "I opened Omnigraph to check how the entities connect."]))
        XCTAssertEqual(Paths.fileType(file.path), .typeRegular, "a regular file next to the link")
        XCTAssertEqual(Paths.fileType(backup.path), .typeSymbolicLink, "the link itself was renamed")
        XCTAssertEqual(backup.resolvingSymlinksInPath().path, target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), maintainersFile, "the repository's file is untouched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dotfiles.path), ["dictionary.json"])
    }

    /// A symlinked config directory is the user's whole directory, so the
    /// conversion happens inside it, as `DictionaryStore` would read it.
    func testASymlinkedDirectoryIsFollowed() throws {
        let real = dir.url.appendingPathComponent("dotfiles/parrot", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try #"{"terms": ["Linked"]}"#.write(to: real.appendingPathComponent("dictionary.json"), atomically: true, encoding: .utf8)
        let config = dir.url.appendingPathComponent("config-parrot")
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: real)

        let outcome = DictionaryMigration.run(
            file: config.appendingPathComponent("dictionary"),
            legacy: config.appendingPathComponent("dictionary.json"),
            log: { [unowned self] in self.logs.append($0) }
        )
        XCTAssertEqual(outcome, .converted(examples: [:]))
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: real.path)),
            ["dictionary", "dictionary.json.bak"]
        )
        XCTAssertEqual(try UserDictionary.parse(Data(contentsOf: real.appendingPathComponent("dictionary"))).terms, ["Linked"])
    }

    func testAnExistingBackupIsNotOverwritten() throws {
        try "earlier".write(to: backup, atomically: true, encoding: .utf8)
        try #"{"terms": ["New"]}"#.write(to: legacy, atomically: true, encoding: .utf8)
        XCTAssertEqual(migrate(), .converted(examples: [:]))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "earlier")
        XCTAssertNotNil(Paths.fileType(legacy.path), "stays where it was, unused")
        XCTAssertEqual(try UserDictionary.parse(Data(contentsOf: file)).terms, ["New"])
    }
}
