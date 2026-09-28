import WhisperKit
import XCTest
@testable import ParrotCore

final class TranscriberTimingsTests: XCTestCase {
    func testFoldsWhisperKitStagesIntoParrotStages() {
        var t = TranscriptionTimings()
        t.audioProcessing = 0.002
        t.logmels = 0.003
        t.encoding = 0.020
        t.decodingWindowing = 0.001
        t.fullPipeline = 0.126
        t.totalEncodingRuns = 1
        t.totalDecodingLoops = 17
        let out = WhisperKitTranscriber.timings(from: [t], audioSeconds: 5, preprocessing: 0.001, total: 0.130)
        XCTAssertEqual(out.preprocessing, 0.006, accuracy: 1e-9)
        XCTAssertEqual(out.encoder, 0.020, accuracy: 1e-9)
        XCTAssertEqual(out.decoder, 0.100, accuracy: 1e-9)
        XCTAssertEqual(out.postprocessing, 0.004, accuracy: 1e-9)
        XCTAssertEqual(out.preprocessing + out.encoder + out.decoder + out.postprocessing, out.total, accuracy: 1e-9)
        XCTAssertEqual(out.tokens, 17)
        XCTAssertEqual(out.windows, 1)
        XCTAssertEqual(out.fallbacks, 0)
    }

    func testCountsAFallbackThatWhisperKitRecordsAsIndexZero() {
        var t = TranscriptionTimings()
        t.decodingFallback = 0.05
        t.totalDecodingFallbacks = 0
        XCTAssertEqual(WhisperKitTranscriber.timings(from: [t], audioSeconds: 1, preprocessing: 0, total: 0.1).fallbacks, 1)
    }
}

@MainActor
final class LatencyLogTests: XCTestCase {
    func testLineHasEveryStageAndNoText() {
        let result = DictationResult(
            captureDuration: 5.3,
            transcriptionTime: 0.13,
            charCount: 74,
            captureStop: 0.003,
            transcriber: TranscriberTimings(
                audioSeconds: 4.4, preprocessing: 0.004, encoder: 0.014, decoder: 0.110,
                postprocessing: 0.001, total: 0.129, windows: 1, tokens: 17, fallbacks: 0
            ),
            processing: 0.0004,
            delivery: 0.002,
            releaseToText: 0.140
        )
        XCTAssertEqual(
            LatencyLog.line(for: result),
            "⏱ 140 ms release→text · 5.3 s audio · stop 3 · pre 4 · enc 14 · dec 110 · post 1 · process 0 · deliver 2 ms · trimmed to 4.4 s · 17 tokens · 1 window · 0 fallbacks"
        )
    }

    func testLineWithoutEngineTimings() {
        let result = DictationResult(captureDuration: 2, transcriptionTime: 0.2, charCount: 10, releaseToText: 0.21)
        XCTAssertEqual(
            LatencyLog.line(for: result),
            "⏱ 210 ms release→text · 2.0 s audio · stop 0 · transcribe 200 · process 0 · deliver 0 ms"
        )
    }

    func testLineWithPressToFirstSample() {
        let result = DictationResult(
            captureDuration: 2, transcriptionTime: 0.2, charCount: 10, releaseToText: 0.21, pressToFirstSample: 0.1724
        )
        XCTAssertEqual(
            LatencyLog.line(for: result),
            "⏱ 210 ms release→text · 2.0 s audio · press→first sample 172 ms · stop 0 · transcribe 200 · process 0 · deliver 0 ms"
        )
    }

    func testLogsOnFinish() {
        var lines: [String] = []
        let log = LatencyLog { lines.append($0) }
        log.dictationFinished(DictationResult(captureDuration: 1, transcriptionTime: 0.1, charCount: 3))
        XCTAssertEqual(lines.count, 1)
    }
}

final class WhisperTuningTests: XCTestCase {
    func testDropsTimestampsOnlyWhenTheAudioFitsOneWindow() {
        let tuning = WhisperTuning.standard
        XCTAssertTrue(tuning.decodingOptions(language: "en", promptTokens: nil, audioSeconds: 5).withoutTimestamps)
        XCTAssertTrue(tuning.decodingOptions(language: "en", promptTokens: nil, audioSeconds: 30).withoutTimestamps)
        XCTAssertFalse(tuning.decodingOptions(language: "en", promptTokens: nil, audioSeconds: 30.5).withoutTimestamps)
    }

    func testBaselineKeepsWhisperKitDefaults() {
        let options = WhisperTuning.baseline.decodingOptions(language: "en", promptTokens: [1, 2], audioSeconds: 5)
        XCTAssertFalse(options.withoutTimestamps)
        XCTAssertEqual(options.language, "en")
        XCTAssertEqual(options.promptTokens, [1, 2])
        XCTAssertFalse(WhisperTuning.baseline.trimSilence)
        XCTAssertEqual(WhisperTuning.baseline.melCompute, .cpuAndGPU)
        XCTAssertEqual(WhisperTuning.baseline.leadPadding, 0)
        XCTAssertEqual(WhisperTuning.baseline.trailPadding, 0)
    }

    func testStandardPadsAfterTheTrim() {
        XCTAssertTrue(WhisperTuning.standard.trimSilence)
        XCTAssertEqual(WhisperTuning.standard.leadPadding, 0.3)
        XCTAssertEqual(WhisperTuning.standard.trailPadding, 0.3)
    }

    func testPadsSilenceAroundTheCaptureAfterTheTrim() {
        var tuning = WhisperTuning.baseline
        tuning.leadPadding = 0.25
        tuning.trailPadding = 0.125
        let speech = [Float](repeating: 0.5, count: 1_600)
        let out = tuning.prepare(speech)
        XCTAssertEqual(out.count, 4_000 + 1_600 + 2_000)
        XCTAssertTrue(out[..<4_000].allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(out[4_000..<5_600]), speech)
        XCTAssertTrue(out[5_600...].allSatisfy { $0 == 0 })
    }

    func testPadsWhatTheTrimKeeps() {
        var tuning = WhisperTuning.baseline
        tuning.trimSilence = true
        tuning.leadPadding = 0.3
        let quiet = [Float](repeating: 0, count: 16_000)
        let loud = (0..<16_000).map { 0.3 * sin(Float($0) * 2 * .pi * 220 / 16_000) }
        let audio = quiet + loud + quiet
        let trimmed = SilenceTrimmer.trim(audio)
        XCTAssertLessThan(trimmed.count, audio.count)
        XCTAssertEqual(tuning.prepare(audio), [Float](repeating: 0, count: 4_800) + trimmed)
    }

    func testLeavesAnEmptyCaptureAndZeroPaddingAlone() {
        var tuning = WhisperTuning.baseline
        tuning.leadPadding = 0.5
        XCTAssertEqual(tuning.prepare([]), [])
        let audio: [Float] = [0.1, -0.2, 0.3]
        XCTAssertEqual(WhisperTuning.baseline.prepare(audio), audio)
        tuning.leadPadding = -1
        XCTAssertEqual(tuning.prepare(audio), audio)
    }
}
