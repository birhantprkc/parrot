import XCTest
@testable import ParrotCore

final class SpokenLanguageTests: XCTestCase {
    private var base: TranscriptionModel { ModelRegistry.find("whisper-base.en")! }
    private var turbo: TranscriptionModel { ModelRegistry.find("whisper-large-v3-turbo")! }

    // MARK: Plan

    func testEnglishOnlyModelIsNeverGivenALanguageOrAskedToDetect() {
        XCTAssertEqual(SpokenLanguage.plan(setting: nil, model: base), .none)
        XCTAssertEqual(SpokenLanguage.plan(setting: "pt", model: base), .none)
        XCTAssertEqual(SpokenLanguage.plan(setting: "en", model: base), .none)
        XCTAssertFalse(base.isMultilingual)
    }

    func testExplicitLanguageIsFixed() {
        XCTAssertEqual(SpokenLanguage.plan(setting: "pt", model: turbo), .fixed("pt"))
        XCTAssertEqual(SpokenLanguage.plan(setting: "SR", model: turbo), .fixed("sr"))
    }

    func testAutomaticDetects() {
        XCTAssertEqual(SpokenLanguage.plan(setting: nil, model: turbo), .detect)
    }

    func testUnknownCodeCountsAsAutomatic() {
        XCTAssertEqual(SpokenLanguage.plan(setting: "xx", model: turbo), .detect)
        XCTAssertEqual(SpokenLanguage.plan(setting: "", model: turbo), .detect)
    }

    func testMultilingualModelSupportsWhisperLanguages() {
        XCTAssertTrue(turbo.isMultilingual)
        XCTAssertTrue(turbo.supportedLanguages.isSuperset(of: ["en", "pt", "sr", "es", "sv"]))
        XCTAssertEqual(base.supportedLanguages, ["en"])
    }

    // MARK: Resolve

    private let whisper = SpokenLanguage.whisperLanguages

    func testPreferredLanguageIsTrustedAtAnyProbability() {
        let chosen = SpokenLanguage.resolve(detected: "es", probability: 0.2, preferred: ["en", "es"], supported: whisper)
        XCTAssertEqual(chosen, "es")
    }

    func testForeignLanguageIsTrustedAtTheThreshold() {
        let t = SpokenLanguage.foreignThreshold
        XCTAssertEqual(SpokenLanguage.resolve(detected: "pt", probability: t, preferred: ["en"], supported: whisper), "pt")
        XCTAssertEqual(SpokenLanguage.resolve(detected: "pt", probability: 0.99, preferred: ["en"], supported: whisper), "pt")
    }

    func testForeignLanguageBelowTheThresholdFallsBackToTheFirstPreferred() {
        // #15: a short English phrase detected as Portuguese came back translated.
        let chosen = SpokenLanguage.resolve(detected: "pt", probability: 0.6, preferred: ["en", "es"], supported: whisper)
        XCTAssertEqual(chosen, "en")
    }

    func testFallbackSkipsPreferredLanguagesTheModelDoesNotSupport() {
        let chosen = SpokenLanguage.resolve(detected: "es", probability: 0.5, preferred: ["tlh", "sr"], supported: whisper)
        XCTAssertEqual(chosen, "sr")
    }

    func testWithNoUsablePreferredLanguageDetectionStands() {
        XCTAssertEqual(SpokenLanguage.resolve(detected: "es", probability: 0.3, preferred: [], supported: whisper), "es")
        XCTAssertEqual(SpokenLanguage.resolve(detected: "es", probability: 0.3, preferred: ["tlh"], supported: whisper), "es")
    }

    // MARK: Preferred languages

    func testPreferredCodesReduceToISO6391InOrderWithoutRepeats() {
        let codes = SpokenLanguage.preferredCodes(["en-US", "pt-BR", "en-GB", "zh-Hans-CN", "sr-Latn-RS", "es"])
        XCTAssertEqual(codes, ["en", "pt", "zh", "sr", "es"])
    }

    // MARK: Names

    func testDisplayNameIsLocalized() {
        XCTAssertEqual(SpokenLanguage.displayName("pt", locale: Locale(identifier: "en_US")), "Portuguese")
        XCTAssertEqual(SpokenLanguage.displayName("pt", locale: Locale(identifier: "pt_BR")), "Português")
    }
}
