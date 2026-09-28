import XCTest
@testable import ParrotCore

final class CaptureBenchTests: XCTestCase {
    func testSummaryIsMedianAndP90InMilliseconds() {
        let samples = (1...10).map { i in
            CaptureBench.Sample(startCall: Double(i) / 1000, firstSample: Double(100 + i) / 1000, firstBuffer: nil)
        }
        let text = CaptureBench.Summary(label: "cold", samples: samples).text
        XCTAssertEqual(text, "cold   10   105/109        -              -              5/9")
    }

    func testSampleSummaryMarksMissingTimings() {
        let sample = CaptureBench.Sample(startCall: 0.12, firstSample: 0.118, firstSound: nil, firstBuffer: 0.2)
        XCTAssertEqual(sample.summary, "first sample 118 · first sound - · first buffer 200 · start() 120 ms")
    }
}
