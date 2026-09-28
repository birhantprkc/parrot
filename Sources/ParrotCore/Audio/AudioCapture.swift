import AVFoundation
import Foundation

/// Captures microphone audio while recording is active and returns a 16 kHz
/// mono Float32 buffer when stopped. Format-converts on the fly so callers
/// don't have to worry about the input device's native rate.
///
/// The microphone runs only between `start()` and `stop()`. How it runs is
/// the `CaptureMode`'s `CaptureInput`; the checks before it (permission, a
/// usable device) and the conversion and bookkeeping after it are here and
/// shared by every mode.
final class AudioCapture {
    static let targetSampleRate: Double = 16_000

    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
    )!

    /// Called for every audio buffer with the buffer's RMS level (0…~1).
    /// Invoked on an arbitrary thread; hop to main if you touch UI.
    var onLevel: ((Float) -> Void)?

    let mode: CaptureMode

    /// Counts and timings of the last finished capture, including press to
    /// first sample. Nil until one finishes.
    private(set) var lastStats: CaptureBuffer.Stats?

    /// Buffers any input delivered while no recording was open. Stays 0
    /// unless an input ran between presses.
    var buffersWhileStopped: Int { buffer.buffersWhileClosed }

    /// The recording so far, for callers that wait on the first sample.
    var currentStats: CaptureBuffer.Stats { buffer.currentStats }

    private let input: CaptureInput
    private var recording = false
    private var device = InputDevice(sampleRate: 0, channels: 0)
    private var delivered = InputDevice(sampleRate: 0, channels: 0)
    private var startDelay: TimeInterval = 0
    private let converters = ConverterCache(targetFormat: AudioCapture.targetFormat)
    private let buffer = CaptureBuffer()

    init(mode: CaptureMode = .standard) {
        self.mode = mode
        self.input = mode.makeInput()
    }

    /// Begin recording. Idempotent — calling while already recording is a no-op.
    /// Throws `CaptureError`; on a throw nothing is left running.
    func start() throws {
        guard !recording else { return }
        // The press. Press-to-first-sample is measured from here.
        let startedAt = HostClock.now()

        if let error = MicrophoneAccess.captureError(for: MicrophoneAccess.status) {
            // A press is the one moment the user is looking; ask again if the
            // system never has (a no-op while its prompt is open).
            MicrophoneAccess.requestIfUndetermined()
            throw error
        }

        // Check the device before any input touches it: a missing input or a
        // 0 Hz / 0 channel format raises an ObjC exception in AVAudioEngine.
        let device = try InputDevice.current()

        converters.resetAll()
        buffer.reset(startedAt: startedAt)
        let buffer = self.buffer
        let sink = InputSink(
            deliver: Self.inputHandler(buffer: buffer, converters: converters, onLevel: onLevel),
            routeChanged: { buffer.markRouteChanged() },
            inputFailed: { buffer.recordInputFailure() }
        )
        do {
            delivered = try input.start(device: device, sink: sink)
        } catch {
            _ = try? buffer.finish()
            throw error
        }
        recording = true
        self.device = device
        startDelay = HostClock.seconds(from: startedAt, to: HostClock.now())
    }

    /// Stop recording and return all captured samples (16 kHz mono Float32).
    /// Returns nothing if the capture failed, for example because the input
    /// route changed mid-recording; the failure is logged. `finish()` is the
    /// same with the failure thrown instead.
    @discardableResult
    func stop() -> [Float] {
        do {
            return try finish()
        } catch {
            Log.error("capture failed: \(error)")
            return []
        }
    }

    /// Stop recording, stop the input, and return the captured samples.
    /// Throws `CaptureError.routeChanged` instead of returning a partial
    /// capture if the input route changed mid-recording.
    func finish() throws -> [Float] {
        guard recording else { return [] }
        recording = false
        input.stop()

        // The input has stopped; flush what the resampler still holds.
        converters.drain { buffer.appendTail($0) }
        let stats = buffer.currentStats
        lastStats = stats
        logStats(stats)
        return try buffer.finish()
    }

    /// The body of an input callback: note when the buffer's first sample,
    /// and its first non-zero sample, were captured, then convert to 16 kHz
    /// and append. `firstFrame` and `now` are `HostClock` nanoseconds. A
    /// buffer outside a recording is counted and dropped.
    static func inputHandler(
        buffer: CaptureBuffer,
        converters: ConverterCache,
        onLevel: ((Float) -> Void)?
    ) -> (_ pcm: AVAudioPCMBuffer, _ firstFrame: UInt64, _ now: UInt64) -> Void {
        return { pcm, firstFrame, now in
            guard buffer.admit() else { return }
            var firstSound: UInt64?
            if buffer.awaitingSound, pcm.format.sampleRate > 0, let frame = firstNonZeroFrame(pcm) {
                firstSound = firstFrame &+ UInt64(Double(frame) / pcm.format.sampleRate * 1_000_000_000)
            }
            buffer.noteInput(firstFrameAt: firstFrame, firstSoundAt: firstSound)
            let converted = converters.convert(pcm) { chunk in
                buffer.append(chunk, inputFrames: Int(pcm.frameLength), at: now)
                onLevel?(computeRMS(chunk))
            }
            if !converted { buffer.recordConversionFailure() }
        }
    }

    /// The first frame in which any channel is not exactly zero, or nil.
    static func firstNonZeroFrame(_ pcm: AVAudioPCMBuffer) -> Int? {
        guard let channels = pcm.floatChannelData else { return nil }
        let interleaved = pcm.format.isInterleaved
        let stride = pcm.stride
        var first: Int?
        for c in 0..<Int(pcm.format.channelCount) {
            let data = channels[interleaved ? 0 : c]
            let offset = interleaved ? c : 0
            var i = 0
            let limit = first ?? Int(pcm.frameLength)
            while i < limit {
                if data[i * stride + offset] != 0 {
                    first = i
                    break
                }
                i += 1
            }
        }
        return first
    }

    /// One line per recording: counts and timings, never audio. Press to
    /// first sample is the start of the dictation the user loses.
    private func logStats(_ stats: CaptureBuffer.Stats) {
        func ms(_ delay: TimeInterval?) -> String { delay.map { String(format: "%.0f ms", $0 * 1000) } ?? "none" }
        var line = String(
            format: "  input %.0f Hz × %u · delivered %.0f Hz × %u · %@ start %.0f ms",
            device.sampleRate, device.channels, delivered.sampleRate, delivered.channels,
            mode.rawValue, startDelay * 1000
        )
        line += " · press→first sample \(ms(stats.firstSampleDelay)) · first sound \(ms(stats.firstSoundDelay))"
        line += " · first buffer \(ms(stats.firstBufferDelay)) · \(stats.buffers) buffers · \(stats.inputFrames) frames"
        if stats.conversionFailures > 0 {
            line += " · \(stats.conversionFailures) conversion failures"
        }
        if stats.inputFailures > 0 {
            line += " · \(stats.inputFailures) input failures"
        }
        Log.info(line)
    }
}

// MARK: - WAV writer (for debugging M3 captures)

enum WAVWriter {
    /// Write Float32 mono samples as 16-bit PCM WAV to `path`.
    static func write(samples: [Float], sampleRate: Int, to path: String) throws {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32LE(36 + UInt32(dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(uint32LE(16))                       // fmt chunk size
        data.append(uint16LE(1))                        // PCM
        data.append(uint16LE(1))                        // mono
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(UInt32(sampleRate * bytesPerSample)))
        data.append(uint16LE(UInt16(bytesPerSample)))   // block align
        data.append(uint16LE(16))                       // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32LE(UInt32(dataSize)))

        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let i = Int16(clamped * 32767.0)
            data.append(uint16LE(UInt16(bitPattern: i)))
        }

        try data.write(to: URL(fileURLWithPath: path))
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}

func computeRMS<C: Collection>(_ samples: C) -> Float where C.Element == Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Double = 0
    for s in samples { sum += Double(s * s) }
    return Float((sum / Double(samples.count)).squareRoot())
}
