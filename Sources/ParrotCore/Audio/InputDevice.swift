import CoreAudio
import Foundation

/// The default input device as Core Audio reports it, read before
/// `AVAudioEngine` touches it.
///
/// With no input device, or one that reports 0 Hz or 0 channels,
/// `AVAudioEngine` raises an Objective-C exception on `installTap` or
/// `start()`, which Swift cannot catch. Checking here turns that into a
/// `CaptureError`.
struct InputDevice: Equatable {
    var sampleRate: Double
    var channels: UInt32

    /// The current default input. Throws `CaptureError.noInputDevice` if there
    /// is none, or `.invalidInputFormat` if it cannot be recorded.
    static func current() throws -> InputDevice {
        guard let id = defaultInputID() else { throw CaptureError.noInputDevice }
        let device = InputDevice(sampleRate: nominalSampleRate(id), channels: inputChannels(id))
        try validate(sampleRate: device.sampleRate, channels: device.channels)
        return device
    }

    /// Throws `CaptureError.invalidInputFormat` unless both are positive.
    static func validate(sampleRate: Double, channels: UInt32) throws {
        guard sampleRate > 0, sampleRate.isFinite, channels > 0 else {
            throw CaptureError.invalidInputFormat(sampleRate: sampleRate, channels: channels)
        }
    }

    private static func defaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    private static func inputChannels(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }
}
