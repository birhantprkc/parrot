import XCTest
@testable import parrot_bench

final class CaptureBenchTests: XCTestCase {
    func testSummaryIsMedianAndP90InMilliseconds() {
        let samples = (1...10).map { (i: Int) -> CaptureBench.Sample in
            let ms = Double(i) / 1000
            return CaptureBench.Sample(startCall: ms, firstSample: 0.1 + ms, firstBuffer: nil, stopCall: 0.02 + ms)
        }
        let text = CaptureBench.Summary(label: "cold", samples: samples).text
        XCTAssertEqual(text, "cold   10   105/109        -              -              5/9            25/29")
    }

    func testSampleSummaryMarksMissingTimings() {
        let sample = CaptureBench.Sample(startCall: 0.12, firstSample: 0.118, firstSound: nil, firstBuffer: 0.2, stopCall: 0.004)
        XCTAssertEqual(sample.summary, "first sample 118 · first sound - · first buffer 200 · start() 120 · stop() 4 ms")
    }
}
