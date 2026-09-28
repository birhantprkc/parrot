import AVFoundation
import Foundation

/// Capture through a fresh `AVAudioEngine` per recording, released on stop.
///
/// A long-lived engine keeps the input graph it was built with, so after
/// sleep, docking, or connecting AirPods it records the wrong format or
/// nothing; releasing it also lets a Bluetooth mic close between recordings.
final class EngineInput: CaptureInput {
    private var engine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var configurationObserver: NSObjectProtocol?

    func start(device: InputDevice, sink: InputSink) throws -> InputDevice {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        try InputDevice.validate(sampleRate: hardware.sampleRate, channels: hardware.channelCount)
        let tapFormat = input.outputFormat(forBus: 0)
        try InputDevice.validate(sampleRate: tapFormat.sampleRate, channels: tapFormat.channelCount)

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            // Tearing the engine down inside this notification is unsafe.
            // Flag it; stop() cleans up and the partial capture is discarded.
            sink.routeChanged()
        }

        // format: nil taps in whatever format the input actually delivers.
        // Passing a format read before start() crashes when the hardware
        // runs at a different one. The converter is built from the first
        // buffer instead.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { pcm, when in
            let now = HostClock.now()
            let firstFrame = when.isHostTimeValid
                ? HostClock.nanoseconds(fromHostTime: when.hostTime)
                : now &- UInt64(Double(pcm.frameLength) / pcm.format.sampleRate * 1_000_000_000)
            sink.deliver(pcm, firstFrame, now)
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
        return InputDevice(sampleRate: tapFormat.sampleRate, channels: tapFormat.channelCount)
    }

    func stop() {
        guard let engine else { return }
        engine.stop()
        inputNode?.removeTap(onBus: 0)
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        self.configurationObserver = nil
        self.inputNode = nil
        self.engine = nil
    }
}
