import XCTest
@testable import ParrotCore

final class SpokenLanguageTests: XCTestCase {
    private var base: TranscriptionModel { ModelRegistry.find("whisper-base.en")! }
    private var turbo: TranscriptionModel { ModelRegistry.find("whisper-large-v3-turbo")! }

    // MARK: Plan

    func testEnglishOnlyModelIsNeverGivenALanguageOrAskedToDetect() {
        XCTAssertEqual(SpokenLanguage.plan(setting: nil, spoken: ["en", "es"], model: base), .none)
        XCTAssertEqual(SpokenLanguage.plan(setting: "pt", spoken: [], model: base), .none)
        XCTAssertEqual(SpokenLanguage.plan(setting: "en", spoken: [], model: base), .none)
        XCTAssertFalse(base.isMultilingual)
    }

    func testExplicitLanguageIsFixed() {
        XCTAssertEqual(SpokenLanguage.plan(setting: "pt", spoken: ["en", "es"], model: turbo), .fixed("pt"))
        XCTAssertEqual(SpokenLanguage.plan(setting: "SR", spoken: [], model: turbo), .fixed("sr"))
    }

    func testAutomaticDetectsAmongTheSpokenLanguagesOnly() {
        XCTAssertEqual(SpokenLanguage.plan(setting: nil, spoken: ["en", "es"], model: turbo), .detect(among: ["en", "es"]))
    }

    func testOneSpokenLanguageNeedsNoDetection() {
        XCTAssertEqual(SpokenLanguage.plan(setting: nil, spoken: ["es"], model: turbo), .fixed("es"))
        // Repeats and codes the model doesn't know don't count.
        XCTAssertEqual(SpokenLanguage.plan(setting: nil, spoken: ["ES", "es", "tlh"], model: turbo), .fixed("es"))
    }

    func testWithNoUsableSpokenLanguageEveryLanguageCompetes() {
        XCTAssertEqual(SpokenLanguage.plan(setting: nil, spoken: [], model: turbo), .detect(among: []))
        XCTAssertEqual(SpokenLanguage.plan(setting: nil, spoken: ["tlh"], model: turbo), .detect(among: []))
    }

    func testUnknownCodeCountsAsAutomatic() {
        XCTAssertEqual(SpokenLanguage.plan(setting: "xx", spoken: ["en", "es"], model: turbo), .detect(among: ["en", "es"]))
        XCTAssertEqual(SpokenLanguage.plan(setting: "", spoken: ["en", "es"], model: turbo), .detect(among: ["en", "es"]))
    }

    func testMultilingualModelSupportsWhisperLanguages() {
        XCTAssertTrue(turbo.isMultilingual)
        XCTAssertTrue(turbo.supportedLanguages.isSuperset(of: ["en", "pt", "sr", "es", "sv"]))
        XCTAssertEqual(base.supportedLanguages, ["en"])
    }

    // MARK: Probabilities

    func testProbabilitiesAreSharedAmongTheGivenLanguagesOnly() {
        // Logits where Italian would win if it were allowed to compete: it
        // is not passed in, so Spanish takes it among English and Spanish.
        let ranked = SpokenLanguage.probabilities([("en", 1.0), ("es", 4.0)])
        XCTAssertEqual(ranked.map(\.code), ["es", "en"])
        XCTAssertEqual(ranked.map(\.probability).reduce(0, +), 1, accuracy: 1e-5)
        XCTAssertEqual(ranked[0].probability, 0.9526, accuracy: 1e-3)
    }

    func testProbabilitiesSurviveLargeLogits() {
        let ranked = SpokenLanguage.probabilities([("en", 900), ("es", 899)])
        XCTAssertEqual(ranked[0].code, "en")
        XCTAssertFalse(ranked[0].probability.isNaN)
    }

    func testNoScoresNoProbabilities() {
        XCTAssertTrue(SpokenLanguage.probabilities([]).isEmpty)
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
