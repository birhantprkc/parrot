import XCTest
@testable import ParrotCore

final class WordErrorRateTests: XCTestCase {
    func testIdenticalTextIgnoringCaseAndPunctuation() {
        let wer = WordErrorRate(reference: "Send the draft to Maria, today.", hypothesis: "send the draft to maria today")
        XCTAssertEqual(wer.errors, 0)
        XCTAssertEqual(wer.referenceWords, 6)
        XCTAssertEqual(wer.rate, 0)
    }

    func testCountsSubstitutionsDeletionsAndInsertions() {
        // one substitution (bank → tank), one deletion (me), one insertion (now)
        let wer = WordErrorRate(reference: "remind me to call the bank", hypothesis: "remind to call the tank now")
        XCTAssertEqual(wer.errors, 3)
        XCTAssertEqual(wer.rate, 0.5, accuracy: 1e-9)
    }

    func testKeepsApostrophesInsideWordsAndSplitsHyphens() {
        XCTAssertEqual(WordErrorRate.words("Don't re-run ‘it’."), ["don't", "re", "run", "it"])
    }

    func testEmptyReference() {
        XCTAssertEqual(WordErrorRate(reference: "", hypothesis: "").rate, 0)
        XCTAssertEqual(WordErrorRate(reference: "", hypothesis: "hello").rate, 1)
    }
}

final class PercentileTests: XCTestCase {
    func testNearestRank() {
        let values = (1...10).map(Double.init).shuffled()
        XCTAssertEqual(Percentile.of(values, 50), 5)
        XCTAssertEqual(Percentile.of(values, 90), 9)
        XCTAssertEqual(Percentile.of(values, 100), 10)
        XCTAssertEqual(Percentile.of([7], 90), 7)
        XCTAssertEqual(Percentile.of([], 50), 0)
    }
}

final class BenchRecordingsTests: XCTestCase {
    func testFindsWavFilesInOrderWithTheirReferences() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["b.wav", "a.WAV", "notes.md"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        try "hello there".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let found = try Bench.recordings(in: dir.path)
        XCTAssertEqual(found.map(\.audio.lastPathComponent), ["a.WAV", "b.wav"])
        XCTAssertNil(found[0].reference)
        XCTAssertEqual(found[1].reference, "hello there")
    }
}
