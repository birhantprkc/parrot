import CoreAudio
import Foundation

/// Flags for `parrot bench capture`.
public struct CaptureBenchOptions {
    /// Rounds. Each is one cold capture after `idle` seconds and one warm
    /// capture `gap` seconds later.
    public var runs: Int
    /// Seconds without capture before each cold press.
    public var idle: Double
    /// Seconds between a cold capture's release and the warm press.
    public var gap: Double
    /// Seconds each capture is held after its first buffer arrives.
    public var hold: Double
    public var mode: CaptureMode
    /// Write the last capture to `Paths.dumpWav`, to listen to it.
    public var dumpWav: Bool

    public init(
        runs: Int = 5, idle: Double = 300, gap: Double = 2, hold: Double = 0.5,
        mode: CaptureMode = .standard, dumpWav: Bool = false
    ) {
        self.runs = runs
        self.idle = idle
        self.gap = gap
        self.hold = hold
        self.mode = mode
        self.dumpWav = dumpWav
    }
}

/// `parrot bench capture`: opens and closes the default input the way a
/// dictation does and reports press-to-first-sample, cold (after an idle
/// gap) and warm (seconds after the last capture), for one capture mode
/// (#52). It also checks, between presses, that neither this process nor any
/// other runs the device, which is the promise every mode keeps.
///
/// Prints timings and counts, never audio.
public enum CaptureBench {
    public static func run(_ options: CaptureBenchOptions) throws {
        guard options.runs > 0, options.idle >= 0, options.gap >= 0, options.hold >= 0 else {
            print("--runs must be at least 1, and --idle, --gap and --hold not negative")
            throw SilentExit(64)
        }
        if let error = MicrophoneAccess.captureError(for: MicrophoneAccess.status) {
            MicrophoneAccess.requestIfUndetermined()
            print(error.userMessage)
            throw SilentExit(1)
        }
        let device: InputDevice
        do {
            device = try InputDevice.current()
        } catch {
            print("\(error)")
            throw SilentExit(1)
        }
        let name = InputDevice.name(of: device.id) ?? "unnamed device"

        let capture = AudioCapture(mode: options.mode)
        print(String(
            format: "%@ · %.0f Hz × %u · mode %@ · %d rounds · %.0f s idle before cold, %.0f s before warm · ms, median/p90",
            name, device.sampleRate, device.channels, options.mode.rawValue, options.runs, options.idle, options.gap
        ))

        // The first capture in a process pays for loading Core Audio's
        // components; the daemon pays it once, on its first press.
        let first = try sample(capture, hold: options.hold)
        print("first capture in this process: \(first.summary)")

        var checks = IdleChecks()
        var cold: [Sample] = []
        var warm: [Sample] = []
        for round in 1...options.runs {
            checks.wait(options.idle, device: device.id)
            let c = try sample(capture, hold: options.hold)
            cold.append(c)
            checks.wait(options.gap, device: device.id)
            let w = try sample(capture, hold: options.hold)
            warm.append(w)
            print("round \(round): cold \(c.summary) | warm \(w.summary)")
        }

        print("")
        print(Summary.header)
        print(Summary(label: "cold", samples: cold).text)
        print(Summary(label: "warm", samples: warm).text)
        print("")
        let all = [first] + cold + warm
        let held = all.filter { $0.runningWhileHeld == true }.count
        print("while held: this process's input running in \(held)/\(all.count) captures")
        print(checks.text + " · \(capture.buffersWhileStopped) buffers delivered while stopped")
        let failed = all.filter { $0.failure != nil }.count
        if failed > 0 {
            print("\(failed) captures failed: \(all.compactMap(\.failure).first ?? "")")
        }
        if options.dumpWav, let last = all.last, !last.audio.isEmpty {
            try Paths.prepareDirectory(Paths.caches)
            let path = try Paths.preparePrivateFile(Paths.dumpWav).path
            try WAVWriter.write(samples: last.audio, sampleRate: Int(AudioCapture.targetSampleRate), to: path)
            print("wrote the last capture to \(path)")
        }
    }

    /// One capture: press, wait for the first buffer, hold, release.
    static func sample(_ capture: AudioCapture, hold: Double) throws -> Sample {
        let pressed = HostClock.now()
        do {
            try capture.start()
        } catch {
            print("capture failed to start: \(error)")
            throw SilentExit(1)
        }
        var result = Sample(startCall: HostClock.seconds(from: pressed, to: HostClock.now()))
        let deadline = pressed + 3_000_000_000
        while capture.currentStats.firstBufferDelay == nil, HostClock.now() < deadline {
            usleep(1_000)
        }
        result.runningWhileHeld = InputActivity.thisProcessIsRunningInput()
        Thread.sleep(forTimeInterval: hold)
        let released = HostClock.now()
        do {
            result.audio = try capture.finish()
        } catch {
            result.failure = "\(error)"
        }
        result.stopCall = HostClock.seconds(from: released, to: HostClock.now())
        let stats = capture.lastStats
        result.firstSample = stats?.firstSampleDelay
        result.firstSound = stats?.firstSoundDelay
        result.firstBuffer = stats?.firstBufferDelay
        return result
    }

    /// What one capture measured, in seconds.
    struct Sample {
        /// How long `start()` blocked the caller.
        var startCall: Double
        var firstSample: Double?
        var firstSound: Double?
        var firstBuffer: Double?
        /// How long `finish()` blocked the caller.
        var stopCall: Double = 0
        /// The capture, 16 kHz mono.
        var audio: [Float] = []
        var runningWhileHeld: Bool?
        var failure: String?

        var startCallValue: Double? { startCall }
        var stopCallValue: Double? { stopCall }

        var summary: String {
            func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0 * 1000) } ?? "-" }
            return "first sample \(ms(firstSample)) · first sound \(ms(firstSound)) · first buffer \(ms(firstBuffer)) · start() \(ms(startCall)) · stop() \(ms(stopCall)) ms"
        }
    }

    /// Median and p90 of each measure over a set of captures.
    struct Summary {
        static let header = "        n   first sample   first sound    first buffer   start()        stop()"

        var label: String
        var samples: [Sample]

        var text: String {
            func column(_ key: KeyPath<Sample, Double?>) -> String {
                let values = samples.compactMap { $0[keyPath: key] }.map { $0 * 1000 }
                guard !values.isEmpty else { return "-".padding(toLength: 15, withPad: " ", startingAt: 0) }
                return String(format: "%.0f/%.0f", Percentile.of(values, 50), Percentile.of(values, 90))
                    .padding(toLength: 15, withPad: " ", startingAt: 0)
            }
            var line = label.padding(toLength: 6, withPad: " ", startingAt: 0)
                + String(format: "%3d   ", samples.count)
                + column(\.firstSample)
                + column(\.firstSound)
                + column(\.firstBuffer)
                + column(\.startCallValue)
                + column(\.stopCallValue)
            while line.hasSuffix(" ") { line.removeLast() }
            return line
        }
    }

    /// Checks between presses that the input is not running: for this
    /// process (the microphone indicator) and for the device in any process.
    struct IdleChecks {
        var checks = 0
        var processRunning = 0
        var deviceRunning = 0
        var unknown = 0

        /// Sleeps `seconds`, checking shortly after the release, halfway,
        /// and just before the next press.
        mutating func wait(_ seconds: Double, device: AudioDeviceID) {
            let first = min(0.25, seconds)
            let middle = (seconds - first) / 2
            Thread.sleep(forTimeInterval: first)
            check(device)
            Thread.sleep(forTimeInterval: middle)
            check(device)
            Thread.sleep(forTimeInterval: seconds - first - middle)
            check(device)
        }

        mutating func check(_ device: AudioDeviceID) {
            checks += 1
            let process = InputActivity.thisProcessIsRunningInput()
            let anywhere = InputActivity.deviceIsRunningSomewhere(device)
            if process == nil || anywhere == nil { unknown += 1 }
            if process == true { processRunning += 1 }
            if anywhere == true { deviceRunning += 1 }
        }

        var text: String {
            var line = "between presses: this process's input running in \(processRunning)/\(checks) checks"
                + " · device running in any process in \(deviceRunning)/\(checks)"
            if unknown > 0 { line += " · \(unknown) checks Core Audio could not answer" }
            return line
        }
    }
}
