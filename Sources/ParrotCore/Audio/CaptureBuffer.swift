import Foundation

/// What one recording has captured so far. The audio thread appends to it;
/// `AudioCapture.stop()` reads it once. It holds no engine, so the rules
/// about what a stop returns are testable without hardware.
final class CaptureBuffer: @unchecked Sendable {
    /// Counts and timings for one recording. Never audio.
    struct Stats: Equatable {
        /// Tap callbacks that delivered converted audio.
        var buffers = 0
        /// Frames received at the input's own sample rate.
        var inputFrames = 0
        /// Buffers the converter failed on.
        var conversionFailures = 0
        /// Seconds from `start()` to the first buffer, or nil if none arrived.
        var firstBufferDelay: TimeInterval?
    }

    private let lock = NSLock()
    private var samples: [Float] = []
    private var stats = Stats()
    private var routeChanged = false
    private var startedAt: UInt64 = 0

    /// Clears everything for a new recording that started at `startedAt`
    /// (`DispatchTime` uptime nanoseconds).
    func reset(startedAt: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        stats = Stats()
        routeChanged = false
        self.startedAt = startedAt
    }

    /// Appends converted 16 kHz samples from one tap callback.
    func append(_ chunk: UnsafeBufferPointer<Float>, inputFrames: Int, at now: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        if stats.firstBufferDelay == nil {
            stats.firstBufferDelay = Double(now &- startedAt) / 1_000_000_000
        }
        stats.buffers += 1
        stats.inputFrames += inputFrames
        samples.append(contentsOf: chunk)
    }

    /// Appends the converter's tail after the last callback. Not counted as
    /// a buffer.
    func appendTail(_ chunk: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: chunk)
    }

    func recordConversionFailure() {
        lock.lock()
        defer { lock.unlock() }
        stats.conversionFailures += 1
    }

    /// Called from the configuration-change notification. Only sets a flag;
    /// the engine is torn down in `stop()`, never inside the notification.
    func markRouteChanged() {
        lock.lock()
        defer { lock.unlock() }
        routeChanged = true
    }

    var currentStats: Stats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    /// Ends the recording and returns its samples. If the route changed at
    /// any point, the partial capture is discarded and this throws
    /// `CaptureError.routeChanged`, so it is never delivered as a success.
    /// Either way the buffer is empty afterwards.
    func finish() throws -> [Float] {
        lock.lock()
        let captured = samples
        let changed = routeChanged
        samples.removeAll(keepingCapacity: true)
        routeChanged = false
        lock.unlock()
        if changed { throw CaptureError.routeChanged }
        return captured
    }
}
