import XCTest
@testable import ParrotCore

final class DictionaryReplacerTests: XCTestCase {
    private func apply(
        _ text: String,
        terms: [String] = [],
        _ replacements: [(from: [String], to: String)] = []
    ) -> String {
        let dictionary = UserDictionary(
            terms: terms,
            replacements: replacements.map { UserDictionary.Replacement(from: $0.from, to: $0.to) }
        )
        return DictionaryReplacer(dictionary).apply(to: text)
    }

    // MARK: Whole words

    func testMatchesWholeWordsOnly() {
        let rules: [(from: [String], to: String)] = [(["api"], "API")]
        XCTAssertEqual(apply("the api is rapid", rules), "the API is rapid")
        XCTAssertEqual(apply("rapid apis capital", rules), "rapid apis capital")
        XCTAssertEqual(apply("my_api api2 api", rules), "my_api api2 API")
    }

    func testPunctuationIsABoundary() {
        let rules: [(from: [String], to: String)] = [(["post hog"], "PostHog")]
        XCTAssertEqual(apply("Open post hog. Then (post hog), \"post hog\"!", rules), "Open PostHog. Then (PostHog), \"PostHog\"!")
        XCTAssertEqual(apply("post-hog", rules), "post-hog")
    }

    func testAccentedLettersAreWordCharacters() {
        let rules: [(from: [String], to: String)] = [(["api"], "API"), (["café"], "Café Rouge")]
        XCTAssertEqual(apply("apié éapi api", rules), "apié éapi API")
        XCTAssertEqual(apply("un café crème, cafés", rules), "un Café Rouge crème, cafés")
        // Decomposed é: the combining mark belongs to the word.
        XCTAssertEqual(apply("cafe\u{301}", [(["cafe"], "X")]), "cafe\u{301}")
    }

    func testNonLatinScripts() {
        XCTAssertEqual(apply("я работаю в яндекс, не в яндексе", terms: ["Яндекс"]), "я работаю в Яндекс, не в яндексе")
        XCTAssertEqual(apply("ΑΘΉΝΑ και αθήνα", terms: ["Αθήνα"]), "Αθήνα και Αθήνα")
        XCTAssertEqual(apply("東京 と 東京都", [(["東京"], "Tokyo")]), "Tokyo と 東京都")
        XCTAssertEqual(apply("in api中 api", [(["api"], "API")]), "in api中 API")
    }

    // MARK: Precedence and passes

    func testLongestMatchWins() {
        let rules: [(from: [String], to: String)] = [(["post"], "POST"), (["post hog"], "PostHog")]
        XCTAssertEqual(apply("post hog and post office", rules), "PostHog and POST office")
        // Order in the file does not matter.
        XCTAssertEqual(apply("post hog", Array(rules.reversed())), "PostHog")
    }

    func testLongerRuleThatIsNotAWholeWordFallsBackToShorter() {
        let rules: [(from: [String], to: String)] = [(["post"], "POST"), (["post ho"], "X")]
        XCTAssertEqual(apply("post hog", rules), "POST hog")
    }

    func testReplacementsDoNotChain() {
        let rules: [(from: [String], to: String)] = [(["alpha"], "beta"), (["beta"], "gamma")]
        XCTAssertEqual(apply("alpha beta", rules), "beta gamma")
        // A term's canonical form is not rewritten by a replacement either.
        XCTAssertEqual(apply("js", terms: ["JavaScript"], [(["js"], "JavaScript"), (["javascript"], "JS")]), "JavaScript")
    }

    func testReplacementIsInsertedLiterally() {
        XCTAssertEqual(apply("home dir", [(["home dir"], "$HOME")]), "$HOME")
        XCTAssertEqual(apply("group", [(["group"], "$0 \\1 $1 \\")]), "$0 \\1 $1 \\")
        XCTAssertEqual(apply("price", terms: ["$5 plan"], [(["price"], "$5")]), "$5")
    }

    func testSourceIsMatchedLiterally() {
        // Regex metacharacters in a `from` are plain text.
        XCTAssertEqual(apply("c++ and cxx", [(["c++"], "C++")]), "C++ and cxx")
        XCTAssertEqual(apply("a.b axb", [(["a.b"], "A.B")]), "A.B axb")
    }

    // MARK: Terms

    func testTermsNormalizeCasing() {
        let terms = ["PostHog", "WhisperKit"]
        XCTAssertEqual(apply("posthog, POSTHOG and Posthog", terms: terms), "PostHog, PostHog and PostHog")
        XCTAssertEqual(apply("whisperkit is fast", terms: terms), "WhisperKit is fast")
        XCTAssertEqual(apply("posthogs", terms: terms), "posthogs")
    }

    func testReplacementTakesPrecedenceOverTermWithSameSource() {
        XCTAssertEqual(apply("posthog", terms: ["Posthog"], [(["posthog"], "PostHog")]), "PostHog")
    }

    // MARK: Input handling

    func testWhitespaceInsideSourceMatchesAnyRun() {
        XCTAssertEqual(apply("post  hog", [(["post hog"], "PostHog")]), "PostHog")
        XCTAssertEqual(apply("post hog", [(["  post   hog "], "PostHog")]), "PostHog")
    }

    func testEmptyEntriesAreIgnored() {
        XCTAssertEqual(apply("a b", terms: ["", "  "], [([""], "X"), (["a"], ""), (["a"], "   ")]), "a b")
        XCTAssertEqual(DictionaryReplacer(.empty).apply(to: "unchanged"), "unchanged")
        XCTAssertEqual(apply("", terms: ["X"]), "")
    }

    func testTemplateWorks() throws {
        let dictionary = try UserDictionary.parse(Data(UserDictionary.template.utf8))
        let replacer = DictionaryReplacer(dictionary)
        XCTAssertEqual(replacer.apply(to: "try whisper kit and whisperkit"), "try WhisperKit and WhisperKit")
        XCTAssertEqual(replacer.apply(to: "a post hoc check"), "a post hoc check")
        XCTAssertNil(dictionary.example(for: "en"))
    }

    func testProcessorAppliesTheStoresDictionary() throws {
        let dir = try TemporaryDirectory()
        let file = dir.url.appendingPathComponent("dictionary")
        try "PostHog\n".write(to: file, atomically: true, encoding: .utf8)
        let processor = DictionaryProcessor(store: DictionaryStore(file: file, log: { _ in }))
        XCTAssertEqual(processor.process(Transcript(text: "open posthog")), Transcript(text: "open PostHog"))
    }
}

/// A directory under the per-user temporary directory, removed on deinit.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
