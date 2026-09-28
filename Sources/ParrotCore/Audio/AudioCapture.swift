import AVFoundation
import Foundation

/// Captures microphone audio while recording is active and returns a 16 kHz
/// mono Float32 buffer when stopped. Format-converts on the fly so callers
/// don't have to worry about the input device's native rate.
///
/// Each recording gets a fresh `AVAudioEngine`, released on stop. A
/// long-lived engine keeps the input graph it was built with, so after
/// sleep, docking, or connecting AirPods it records the wrong format or
/// nothing; releasing it also lets a Bluetooth mic close between recordings.
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

    /// Counts and timings of the last finished capture, including press to
    /// first sample. Nil until one finishes.
    private(set) var lastStats: CaptureBuffer.Stats?

    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var configurationObserver: NSObjectProtocol?
    private var device = InputDevice(sampleRate: 0, channels: 0)
    private var tap = InputDevice(sampleRate: 0, channels: 0)
    private var engineStartDelay: TimeInterval = 0
    private let converters = ConverterCache(targetFormat: AudioCapture.targetFormat)
    private let buffer = CaptureBuffer()

    /// Begin recording. Idempotent — calling while already recording is a no-op.
    /// Throws `CaptureError`; on a throw nothing is left running.
    func start() throws {
        guard engine == nil else { return }
        // The press. Press-to-first-sample is measured from here.
        let startedAt = HostClock.now()

        if let error = MicrophoneAccess.captureError(for: MicrophoneAccess.status) {
            // A press is the one moment the user is looking; ask again if the
            // system never has (a no-op while its prompt is open).
            MicrophoneAccess.requestIfUndetermined()
            throw error
        }

        // Check the device before AVAudioEngine touches it: a missing input
        // or a 0 Hz / 0 channel format raises an ObjC exception later.
        let device = try InputDevice.current()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        try InputDevice.validate(sampleRate: hardware.sampleRate, channels: hardware.channelCount)
        let tapFormat = input.outputFormat(forBus: 0)
        try InputDevice.validate(sampleRate: tapFormat.sampleRate, channels: tapFormat.channelCount)

        converters.resetAll()
        buffer.reset(startedAt: startedAt)

        let buffer = self.buffer
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            // Tearing the engine down inside this notification is unsafe.
            // Flag it; stop() cleans up and discards the partial capture.
            buffer.markRouteChanged()
        }

        // format: nil taps in whatever format the input actually delivers.
        // Passing a format read before start() crashes when the hardware
        // runs at a different one. The converter is built from the first
        // buffer instead.
        let handle = Self.inputHandler(buffer: buffer, converters: converters, onLevel: onLevel)
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { pcm, when in
            let now = HostClock.now()
            let firstFrame = when.isHostTimeValid
                ? HostClock.nanoseconds(fromHostTime: when.hostTime)
                : now &- UInt64(Double(pcm.frameLength) / pcm.format.sampleRate * 1_000_000_000)
            handle(pcm, firstFrame, now)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NotificationCenter.default.removeObserver(observer)
            throw CaptureError.engineStartFailed(error)
        }

        self.engine = engine
        self.inputNode = input
        self.configurationObserver = observer
        self.device = device
        self.tap = InputDevice(sampleRate: tapFormat.sampleRate, channels: tapFormat.channelCount)
        self.engineStartDelay = HostClock.seconds(from: startedAt, to: HostClock.now())
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

    /// Stop recording, release the engine, and return the captured samples.
    /// Throws `CaptureError.routeChanged` instead of returning a partial
    /// capture if the input route changed mid-recording.
    func finish() throws -> [Float] {
        guard let engine else { return [] }
        engine.stop()
        inputNode?.removeTap(onBus: 0)
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        self.configurationObserver = nil
        self.inputNode = nil
        self.engine = nil

        // The tap has stopped; flush what the resampler still holds.
        converters.drain { buffer.appendTail($0) }
        let stats = buffer.currentStats
        lastStats = stats
        logStats(stats)
        return try buffer.finish()
    }

    /// The body of an input callback: note when the buffer's first sample,
    /// and its first non-zero sample, were captured, then convert to 16 kHz
    /// and append. `firstFrame` and `now` are `HostClock` nanoseconds.
    static func inputHandler(
        buffer: CaptureBuffer,
        converters: ConverterCache,
        onLevel: ((Float) -> Void)?
    ) -> (_ pcm: AVAudioPCMBuffer, _ firstFrame: UInt64, _ now: UInt64) -> Void {
        return { pcm, firstFrame, now in
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
            format: "  input %.0f Hz × %u · tap %.0f Hz × %u · engine start %.0f ms",
            device.sampleRate, device.channels, tap.sampleRate, tap.channels, engineStartDelay * 1000
        )
        line += " · press→first sample \(ms(stats.firstSampleDelay)) · first sound \(ms(stats.firstSoundDelay))"
        line += " · first buffer \(ms(stats.firstBufferDelay)) · \(stats.buffers) buffers · \(stats.inputFrames) frames"
        if stats.conversionFailures > 0 {
            line += " · \(stats.conversionFailures) conversion failures"
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
