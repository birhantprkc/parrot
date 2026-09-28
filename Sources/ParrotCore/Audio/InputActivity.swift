import CoreAudio
import Foundation

/// Whether the microphone is running, as Core Audio reports it: for this
/// process (what the menu bar's microphone indicator follows) and for a
/// device across every process. Used to check that nothing runs the input
/// between presses (#52).
enum InputActivity {
    /// True while this process has input running, nil if Core Audio cannot
    /// say.
    static func thisProcessIsRunningInput() -> Bool? {
        guard let process = processObject(pid: getpid()) else { return nil }
        return boolProperty(process, kAudioProcessPropertyIsRunningInput)
    }

    /// True while any process runs `device`, nil if Core Audio cannot say.
    static func deviceIsRunningSomewhere(_ device: AudioDeviceID) -> Bool? {
        boolProperty(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
    }

    private static func processObject(pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        guard status == noErr, object != kAudioObjectUnknown else { return nil }
        return object
    }

    private static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool? {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }
}
