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

    func testLogsOnFinish() {
        var lines: [String] = []
        let log = LatencyLog { lines.append($0) }
        log.dictationFinished(DictationResult(captureDuration: 1, transcriptionTime: 0.1, charCount: 3))
        XCTAssertEqual(lines.count, 1)
    }
}

