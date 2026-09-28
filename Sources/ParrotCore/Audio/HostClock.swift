import Darwin

/// Host time in nanoseconds: the clock Core Audio stamps each buffer with
/// (`mach_absolute_time`), so a press and the capture time of a sample can
/// be compared directly.
package enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Now, in host nanoseconds.
    package static func now() -> UInt64 {
        nanoseconds(fromHostTime: mach_absolute_time())
    }

    /// A Core Audio host time (`AudioTimeStamp.mHostTime`,
    /// `AVAudioTime.hostTime`) in host nanoseconds.
    static func nanoseconds(fromHostTime hostTime: UInt64) -> UInt64 {
        let info = timebase
        if info.numer == info.denom { return hostTime }
        return UInt64((Double(hostTime) * Double(info.numer) / Double(info.denom)).rounded())
    }

    /// Seconds from `start` to `end`, negative if `end` came first.
    package static func seconds(from start: UInt64, to end: UInt64) -> Double {
        Double(Int64(bitPattern: end &- start)) / 1_000_000_000
    }
}
