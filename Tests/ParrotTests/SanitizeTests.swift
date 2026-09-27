import XCTest
@testable import ParrotCore

final class SanitizeTests: XCTestCase {
    func testStripsNonSpeechTokens() {
        XCTAssertEqual(WhisperKitTranscriber.sanitize("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperKitTranscriber.sanitize("(silence)"), "")
        XCTAssertEqual(WhisperKitTranscriber.sanitize("<|nospeech|>"), "")
        XCTAssertEqual(WhisperKitTranscriber.sanitize("*background noise*"), "")
    }

    func testKeepsSpeechAndCollapsesWhitespace() {
        XCTAssertEqual(
            WhisperKitTranscriber.sanitize("  Hello [MUSIC]  there (music playing)\n world <|endoftext|> "),
            "Hello there world"
        )
    }

    func testLeavesPlainTextAlone() {
        XCTAssertEqual(WhisperKitTranscriber.sanitize("Ship it on Friday."), "Ship it on Friday.")
    }
}
