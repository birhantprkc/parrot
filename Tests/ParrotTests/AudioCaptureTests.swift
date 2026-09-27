import AVFoundation
import XCTest
@testable import ParrotCore

final class AudioCaptureTests: XCTestCase {
    private struct Boom: Error {}

    // MARK: Input format guard

    func testZeroHzOrZeroChannelsThrowsInsteadOfReachingTheEngine() {
        for (rate, channels) in [(0.0, UInt32(1)), (48_000, 0), (0, 0), (.nan, 1)] {
            XCTAssertThrowsError(try InputDevice.validate(sampleRate: rate, channels: channels)) { error in
                guard case CaptureError.invalidInputFormat = error else {
                    return XCTFail("expected invalidInputFormat, got \(error)")
                }
            }
        }
        XCTAssertNoThrow(try InputDevice.validate(sampleRate: 44_100, channels: 1))
    }

    // MARK: Route change

    func testRouteChangeDiscardsThePartialCapture() {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 0)
        append([0.1, 0.2, 0.3], to: buffer)
        buffer.markRouteChanged()
        append([0.4], to: buffer)

        XCTAssertThrowsError(try buffer.finish()) { error in
            guard case CaptureError.routeChanged = error else {
                return XCTFail("expected routeChanged, got \(error)")
            }
        }
        // The next recording starts clean and succeeds.
        buffer.reset(startedAt: 0)
        append([0.5], to: buffer)
        XCTAssertEqual(try buffer.finish(), [0.5])
    }

    func testFinishReturnsSamplesAndStats() throws {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 1_000_000_000)
        append([0.1, 0.2], inputFrames: 6, at: 1_050_000_000, to: buffer)
        append([0.3], inputFrames: 3, at: 1_090_000_000, to: buffer)
        buffer.recordConversionFailure()

        let stats = buffer.currentStats
        XCTAssertEqual(stats.buffers, 2)
        XCTAssertEqual(stats.inputFrames, 9)
        XCTAssertEqual(stats.conversionFailures, 1)
        XCTAssertEqual(try XCTUnwrap(stats.firstBufferDelay), 0.05, accuracy: 1e-9)
        XCTAssertEqual(try buffer.finish(), [0.1, 0.2, 0.3])
        XCTAssertEqual(try buffer.finish(), [])
    }

    func testResetClearsARouteChangeFromTheLastRecording() {
        let buffer = CaptureBuffer()
        buffer.markRouteChanged()
        buffer.reset(startedAt: 0)
        XCTAssertEqual(try buffer.finish(), [])
        XCTAssertNil(buffer.currentStats.firstBufferDelay)
    }

    // MARK: Converter cache

    func testConverterIsBuiltOncePerInputFormat() throws {
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        let stereo48 = try makeBuffer(sampleRate: 48_000, channels: 2, frames: 4_800)
        let mono44 = try makeBuffer(sampleRate: 44_100, channels: 1, frames: 4_410)

        XCTAssertEqual(cache.count, 0)
        XCTAssertTrue(cache.convert(stereo48) { _ in })
        XCTAssertTrue(cache.convert(stereo48) { _ in })
        XCTAssertEqual(cache.count, 1)
        XCTAssertTrue(cache.convert(mono44) { _ in })
        XCTAssertEqual(cache.count, 2)
        XCTAssertTrue(cache.convert(stereo48) { _ in })
        XCTAssertEqual(cache.count, 2)
    }

    func testConvertsToSixteenKilohertzWithoutLosingTheTail() throws {
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        let input = try makeBuffer(sampleRate: 48_000, channels: 2, frames: 4_800)
        var converted = 0
        // One second in 100 ms buffers. The resampler emits in blocks and
        // holds the remainder until drained.
        for _ in 0..<10 {
            XCTAssertTrue(cache.convert(input) { converted += $0.count })
        }
        XCTAssertLessThan(converted, 16_000)
        var drained = 0
        cache.drain { drained += $0.count }
        XCTAssertGreaterThan(drained, 0)
        XCTAssertEqual(Double(converted + drained), 16_000, accuracy: 32)
    }

    // MARK: Errors and permission

    func testCaptureErrorsAreOneLineUserFacingMessages() {
        let errors: [CaptureError] = [
            .microphoneDenied, .microphonePending, .noInputDevice,
            .invalidInputFormat(sampleRate: 0, channels: 0),
            .engineStartFailed(Boom()), .routeChanged,
        ]
        for error in errors {
            let message = (error as UserFacingError).userMessage
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("\n"), message)
            XCTAssertEqual(RecordingOverlay.message(for: error), message)
        }
        XCTAssertEqual(
            CaptureError.microphoneDenied.userMessage,
            "microphone access denied: System Settings → Privacy & Security → Microphone"
        )
    }

    func testOtherErrorsHaveNoOverlayMessage() {
        XCTAssertNil(RecordingOverlay.message(for: Boom()))
        XCTAssertNil(RecordingOverlay.message(for: DictationError.noAudio))
    }

    func testMicrophoneStatusGatesCapture() {
        XCTAssertNil(MicrophoneAccess.captureError(for: .authorized))
        for status in [AVAuthorizationStatus.denied, .restricted] {
            guard case .microphoneDenied? = MicrophoneAccess.captureError(for: status) else {
                return XCTFail("expected microphoneDenied for \(status.rawValue)")
            }
        }
        guard case .microphonePending? = MicrophoneAccess.captureError(for: .notDetermined) else {
            return XCTFail("expected microphonePending")
        }
    }

    // MARK: Helpers

    private func append(
        _ samples: [Float], inputFrames: Int = 0, at now: UInt64 = 0, to buffer: CaptureBuffer
    ) {
        samples.withUnsafeBufferPointer { buffer.append($0, inputFrames: inputFrames, at: now) }
    }

    private func makeBuffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                data[c][i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
            }
        }
        return buffer
    }
}
