import XCTest
@testable import ParrotCore

final class SilenceTrimmerTests: XCTestCase {
    private func tone(_ seconds: Double, level: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { level * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    private func noise(_ seconds: Double, level: Float) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -level...level, using: &generator) }
    }

    func testCutsQuietEdgesAndKeepsMargins() {
        let audio = noise(1.0, level: 0.002) + tone(2.0, level: 0.3) + noise(2.0, level: 0.002)
        let trimmed = SilenceTrimmer.trim(audio)
        let expected = 2.0 + SilenceTrimmer.leadMargin + SilenceTrimmer.trailMargin
        XCTAssertEqual(Double(trimmed.count) / 16_000, expected, accuracy: 0.02)
        let range = SilenceTrimmer.voicedRange(audio)!
        XCTAssertEqual(Double(range.lowerBound) / 16_000, 1.0 - SilenceTrimmer.leadMargin, accuracy: 0.02)
    }

    func testKeepsAudioWithNothingAboveTheFloor() {
        let silence = noise(2.0, level: 0.001)
        XCTAssertEqual(SilenceTrimmer.trim(silence), silence)
        XCTAssertEqual(SilenceTrimmer.trim([]), [])
    }

    func testLeavesSpeechToTheEdgesAlone() {
        let speech = tone(1.0, level: 0.3)
        XCTAssertEqual(SilenceTrimmer.trim(speech).count, speech.count)
    }

    func testKeepsQuietWordsBetweenLoudOnes() {
        // A soft word in the middle is inside the kept range whatever its level.
        let audio = noise(0.5, level: 0.001) + tone(0.5, level: 0.3) + tone(0.5, level: 0.004) + tone(0.5, level: 0.3) + noise(0.5, level: 0.001)
        let range = SilenceTrimmer.voicedRange(audio)!
        XCTAssertLessThanOrEqual(range.lowerBound, 8_000)
        XCTAssertGreaterThanOrEqual(range.upperBound, 32_000)
    }

    func testNoiseLoudEnoughToHideSpeechLeavesTheCaptureWhole() {
        // Noise above 5% of the peak counts as voiced, so nothing is cut.
        let audio = noise(1.0, level: 0.05) + tone(1.0, level: 0.3) + noise(1.0, level: 0.05)
        XCTAssertEqual(SilenceTrimmer.trim(audio).count, audio.count)
    }
}
