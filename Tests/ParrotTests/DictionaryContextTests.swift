import WhisperKit
import XCTest
@testable import ParrotCore

final class DictionaryContextTests: XCTestCase {
    // MARK: Context

    func testContextGivesThePromptOnlyForAKnownMatchingLanguage() throws {
        let dir = try TemporaryDirectory()
        let file = dir.url.appendingPathComponent("dictionary.json")
        try #"{"terms": ["PostHog"], "examples": {"en": "I opened PostHog."}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let store = DictionaryStore(file: file, log: { _ in })

        let english = DictionaryContext(store: store, language: "en").context()
        XCTAssertEqual(english, TranscriptionContext(language: "en", prompt: "I opened PostHog.", vocabulary: ["PostHog"]))

        // Automatic: no prompt yet; the examples go along for the engine to pick from.
        let unknown = DictionaryContext(store: store, language: nil).context()
        XCTAssertNil(unknown.prompt)
        XCTAssertNil(unknown.language)
        XCTAssertEqual(unknown.examples, ["en": "I opened PostHog."])

        XCTAssertNil(DictionaryContext(store: store, language: "pt").context().prompt)
    }

    func testKnownLanguageOnlyForSingleLanguageModels() throws {
        let base = try XCTUnwrap(ModelRegistry.find("whisper-base.en"))
        let turbo = try XCTUnwrap(ModelRegistry.find("whisper-large-v3-turbo"))
        XCTAssertEqual(DictionaryContext.knownLanguage(of: base), "en")
        XCTAssertNil(DictionaryContext.knownLanguage(of: turbo))
    }

    func testLanguageFollowsTheSettingOnlyForMultilingualModels() throws {
        let base = try XCTUnwrap(ModelRegistry.find("whisper-base.en"))
        let turbo = try XCTUnwrap(ModelRegistry.find("whisper-large-v3-turbo"))
        XCTAssertEqual(DictionaryContext.language(of: base, setting: "pt"), "en")
        XCTAssertEqual(DictionaryContext.language(of: turbo, setting: "pt"), "pt")
        XCTAssertNil(DictionaryContext.language(of: turbo, setting: nil))
        XCTAssertNil(DictionaryContext.language(of: turbo, setting: "xx"))
    }

    /// In Automatic the transcriber picks the example for the language it
    /// settled on, and never one in another language.
    func testDetectedLanguagePicksItsOwnExample() {
        let examples = ["en": "I opened PostHog.", "pt-BR": "Abri o PostHog."]
        XCTAssertEqual(WhisperKitTranscriber.example(in: examples, for: "pt"), "Abri o PostHog.")
        XCTAssertEqual(WhisperKitTranscriber.example(in: examples, for: "en"), "I opened PostHog.")
        XCTAssertNil(WhisperKitTranscriber.example(in: examples, for: "es"))
        XCTAssertNil(WhisperKitTranscriber.example(in: examples, for: nil))
        XCTAssertNil(WhisperKitTranscriber.example(in: [:], for: "en"))
    }

    // MARK: Whisper prompt tokens

    /// Encodes each character as its scalar value, prefixed with a special
    /// token; a "<" also becomes a special token.
    private struct FakeTokenizer: WhisperTokenizer {
        static let specialBegin = 50_000

        func encode(text: String) -> [Int] {
            [Self.specialBegin + 7] + text.unicodeScalars.map { $0 == "<" ? Self.specialBegin + 1 : Int($0.value) }
        }

        func decode(tokens: [Int]) -> String { "" }
        func convertTokenToId(_ token: String) -> Int? { nil }
        func convertIdToToken(_ id: Int) -> String? { nil }
        var allLanguageTokens: Set<Int> { [] }
        func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) { ([], []) }

        var specialTokens: SpecialTokens {
            SpecialTokens(
                endToken: Self.specialBegin, englishToken: Self.specialBegin + 2, noSpeechToken: Self.specialBegin + 3,
                noTimestampsToken: Self.specialBegin + 4, specialTokenBegin: Self.specialBegin,
                startOfPreviousToken: Self.specialBegin + 5, startOfTranscriptToken: Self.specialBegin + 6,
                timeTokenBegin: Self.specialBegin + 100, transcribeToken: Self.specialBegin + 8,
                translateToken: Self.specialBegin + 9, whitespaceToken: 32
            )
        }
    }

    func testPromptTokensDropSpecialTokensAndLeadWithASpace() {
        let tokens = WhisperKitTranscriber.promptTokens(for: " a<b ", tokenizer: FakeTokenizer())
        XCTAssertEqual(tokens, [32, 97, 98])
    }

    func testNoPromptTokensWithoutAPrompt() {
        XCTAssertNil(WhisperKitTranscriber.promptTokens(for: nil, tokenizer: FakeTokenizer()))
        XCTAssertNil(WhisperKitTranscriber.promptTokens(for: "  \n", tokenizer: FakeTokenizer()))
        XCTAssertNil(WhisperKitTranscriber.promptTokens(for: "text", tokenizer: nil))
    }
}
