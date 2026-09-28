import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Capture through a Core Audio AUHAL input unit (#52), without
/// `AVAudioEngine`'s graph on top.
///
/// Per press the unit is bound to the default input, set to deliver Float32
/// at the device's own rate, and started; `AudioCapture` converts to 16 kHz.
/// On release it is stopped and, unless `keepsPrepared`, disposed.
///
/// With `keepsPrepared` the unit stays built and initialized between presses
/// but never started: the device is not running, no callback fires, and the
/// microphone indicator is off. A press only starts it. The unit is rebuilt
/// on the next press if the default input or its format changed meanwhile.
///
/// The #39 guarantees hold without an Objective-C exception to guard
/// against: every Core Audio call returns a status, 0 Hz and 0 channel
/// formats are refused before the unit is configured with them, and a
/// change to the default input, the device's rate or channels, or the device
/// going away mid-recording is reported through the sink, so the recording
/// is discarded instead of returned partial.
final class HALInput: CaptureInput {
    let keepsPrepared: Bool

    private var unit: AudioUnit?
    /// The device and client format the unit is built for.
    private var built: InputDevice?
    /// What the built unit delivers.
    private var delivering: InputDevice?
    private var context: RenderContext?
    private var watcher: DeviceWatcher?

    init(keepsPrepared: Bool) {
        self.keepsPrepared = keepsPrepared
    }

    deinit {
        teardown()
    }

    /// Builds and initializes the unit for the current default input without
    /// starting it. Does nothing if it is already built for that device.
    func prepare() throws {
        try prepare(device: InputDevice.current())
    }

    /// With `keepsPrepared`, builds the unit ahead of the first press so a
    /// press only has to start it. Never starts the device. Skipped until
    /// microphone access is granted.
    func prepareIdle() {
        guard keepsPrepared, MicrophoneAccess.status == .authorized else { return }
        do {
            try prepare()
        } catch {
            Log.info("capture: input not prepared ahead of the press: \(error)")
        }
    }

    func start(device: InputDevice, sink: InputSink) throws -> InputDevice {
        try prepare(device: device)
        guard let unit, let context, let delivering else { throw CaptureError.noInputDevice }

        context.begin(sink)
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            context.end()
            teardown()
            throw CaptureError.engineStartFailed(Self.error(status, "AudioOutputUnitStart"))
        }
        return delivering
    }

    func stop() {
        guard let unit, let context else { return }
        if context.isRecording {
            // Returns once the device's IO has stopped: no callback after it.
            AudioOutputUnitStop(unit)
            context.end()
        }
        if !keepsPrepared { teardown() }
    }

    /// Builds the unit for `device` unless it is already built for it and
    /// nothing has changed since.
    private func prepare(device: InputDevice) throws {
        if unit != nil, built.map({ Self.sameInput($0, device) }) == true, context?.isStale == false {
            return
        }
        teardown()

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.engineStartFailed(Self.error(-1, "AudioComponentFindNext"))
        }
        var instance: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &instance), "AudioComponentInstanceNew")
        guard let unit = instance else { throw CaptureError.engineStartFailed(Self.error(-1, "AudioComponentInstanceNew")) }

        do {
            let format = try Self.configure(unit, device: device)
            var maxFrames: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &size)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(maxFrames, 8192)) else {
                throw CaptureError.invalidInputFormat(sampleRate: format.sampleRate, channels: format.channelCount)
            }
            let context = RenderContext(unit: unit, pcm: pcm)
            var callback = AURenderCallbackStruct(
                inputProc: halInputCallback,
                inputProcRefCon: Unmanaged.passUnretained(context).toOpaque()
            )
            try Self.check(AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ), "SetInputCallback")
            try Self.check(AudioUnitInitialize(unit), "AudioUnitInitialize")

            self.unit = unit
            self.delivering = InputDevice(sampleRate: format.sampleRate, channels: format.channelCount, id: device.id)
            self.context = context
            self.built = InputDevice(sampleRate: device.sampleRate, channels: device.channels, id: device.id)
            self.watcher = DeviceWatcher(device: device) { [weak context] in context?.inputChanged() }
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    /// Enables input only, binds the device, and sets the client format:
    /// Float32, non-interleaved, at the device's rate (AUHAL does not
    /// resample input), with at most two channels. Returns that format.
    private static func configure(_ unit: AudioUnit, device: InputDevice) throws -> AVAudioFormat {
        var on: UInt32 = 1
        var off: UInt32 = 0
        let flagSize = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flagSize), "EnableIO input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize), "EnableIO output")
        var id = device.id
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        ), "CurrentDevice")

        // What the device delivers into the unit.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "input format")
        guard let client = clientFormat(sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame) else {
            throw CaptureError.invalidInputFormat(sampleRate: hardware.mSampleRate, channels: hardware.mChannelsPerFrame)
        }
        var asbd = client.streamDescription.pointee
        try check(AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ), "client format")
        return client
    }

    /// The format the unit delivers for an input at `sampleRate` with
    /// `channels`, or nil if that input cannot be recorded (0 Hz, 0 channels,
    /// not finite). Channels past the second are dropped.
    static func clientFormat(sampleRate: Double, channels: UInt32) -> AVAudioFormat? {
        guard (try? InputDevice.validate(sampleRate: sampleRate, channels: channels)) != nil else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(min(channels, 2)),
            interleaved: false
        )
    }

    /// Whether a unit built for `built` can record `current` as is.
    static func sameInput(_ built: InputDevice, _ current: InputDevice) -> Bool {
        built.id == current.id && built.sampleRate == current.sampleRate && built.channels == current.channels
    }

    /// Whether a unit built for `built` can no longer record as built: the
    /// default input moved to another device, the device went away, or its
    /// rate or input channels changed.
    static func hasChanged(built: InputDevice, defaultInput: AudioDeviceID?, isAlive: Bool, current: InputDevice) -> Bool {
        guard defaultInput == built.id, isAlive else { return true }
        return !sameInput(built, current)
    }

    private func teardown() {
        watcher = nil
        if let unit {
            if context?.isRecording == true {
                AudioOutputUnitStop(unit)
                context?.end()
            }
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        context = nil
        built = nil
        delivering = nil
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status != noErr else { return }
        throw CaptureError.engineStartFailed(error(status, step))
    }

    private static func error(_ status: OSStatus, _ step: String) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: step])
    }
}

/// What the render callback needs, shared between the realtime thread, the
/// listener queue and the caller.
private final class RenderContext: @unchecked Sendable {
    let unit: AudioUnit
    let pcm: AVAudioPCMBuffer
    private let lock = NSLock()
    private var sink: InputSink?
    private var stale = false

    init(unit: AudioUnit, pcm: AVAudioPCMBuffer) {
        self.unit = unit
        self.pcm = pcm
    }

    var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sink != nil
    }

    /// True once the input changed after the unit was built.
    var isStale: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stale
    }

    func begin(_ sink: InputSink) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        sink = nil
    }

    /// The default input, or the device's format or presence, changed. A
    /// recording in progress is discarded; an idle unit is rebuilt on the
    /// next press.
    func inputChanged() {
        lock.lock()
        stale = true
        let sink = self.sink
        lock.unlock()
        sink?.routeChanged()
    }

    func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frames: UInt32
    ) -> OSStatus {
        let now = HostClock.now()
        lock.lock()
        let sink = self.sink
        lock.unlock()
        guard let sink else { return noErr }
        guard frames <= pcm.frameCapacity else {
            sink.inputFailed()
            return noErr
        }
        pcm.frameLength = frames
        let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for i in 0..<buffers.count {
            buffers[i].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        }
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, pcm.mutableAudioBufferList)
        guard status == noErr else {
            sink.inputFailed()
            return status
        }
        let stamp = timestamp.pointee
        let firstFrame = stamp.mFlags.contains(.hostTimeValid)
            ? HostClock.nanoseconds(fromHostTime: stamp.mHostTime)
            : now &- UInt64(Double(frames) / pcm.format.sampleRate * 1_000_000_000)
        sink.deliver(pcm, firstFrame, now)
        return noErr
    }
}

private let halInputCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    Unmanaged<RenderContext>.fromOpaque(refCon).takeUnretainedValue().render(flags, timestamp, bus, frames)
}

/// Listens for the changes that invalidate a built unit: the default input
/// switching, the device's rate or input channels changing, or the device
/// disappearing. Calls `changed` only when a re-read shows a real change, so
/// a notification that changes nothing does not discard a recording.
/// Listeners are removed when this is released.
private final class DeviceWatcher {
    private let queue = DispatchQueue(label: "parrot.capture.device-watcher")
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(device: InputDevice, changed: @escaping () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            guard DeviceWatcher.hasChanged(from: device) else { return }
            changed()
        }
        let system = AudioObjectID(kAudioObjectSystemObject)
        add(system, kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, block)
        add(device.id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, block)
        add(device.id, kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput, block)
        add(device.id, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, block)
    }

    deinit {
        for (object, address, block) in registrations {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
    }

    private func add(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
        _ block: @escaping AudioObjectPropertyListenerBlock
    ) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            registrations.append((object, address, block))
        }
    }

    /// Whether the default input is no longer `device` as it was built.
    static func hasChanged(from device: InputDevice) -> Bool {
        HALInput.hasChanged(
            built: device,
            defaultInput: InputDevice.defaultInputID(),
            isAlive: isAlive(device.id),
            current: InputDevice(
                sampleRate: InputDevice.nominalSampleRate(device.id),
                channels: InputDevice.inputChannels(device.id),
                id: device.id
            )
        )
    }

    private static func isAlive(_ id: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr else { return false }
        return alive != 0
    }
}
