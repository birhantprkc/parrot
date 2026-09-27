import XCTest
@testable import ParrotCore

final class HotkeyRecoveryTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testBackoffDoublesFromOneSecondToThirty() {
        let delays = (0...8).map { TapRecovery.delay(afterFailures: $0) }
        XCTAssertEqual(delays, [0, 1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(TapRecovery.delay(afterFailures: 10_000), 30)
    }

    func testFirstDisableReenablesAtOnce() {
        var recovery = TapRecovery()
        XCTAssertEqual(recovery.disabled(at: t0), 0)
        XCTAssertEqual(recovery.failures, 0)
    }

    func testFailedEnableBacksOff() {
        var recovery = TapRecovery()
        XCTAssertEqual(recovery.disabled(at: t0), 0)
        XCTAssertEqual(recovery.enableFailed(), 1)
        XCTAssertEqual(recovery.enableFailed(), 2)
        XCTAssertEqual(recovery.enableFailed(), 4)
    }

    /// Secure Input can undo each re-enable at once. That must back off
    /// rather than loop.
    func testReenableUndoneQuicklyCountsAsFailure() {
        var recovery = TapRecovery()
        XCTAssertEqual(recovery.disabled(at: t0), 0)
        recovery.enabled(at: t0)
        XCTAssertEqual(recovery.disabled(at: t0 + 0.1), 1)
        recovery.enabled(at: t0 + 1.1)
        XCTAssertEqual(recovery.disabled(at: t0 + 1.2), 2)
        recovery.enabled(at: t0 + 3.2)
        XCTAssertEqual(recovery.disabled(at: t0 + 3.3), 4)
    }

    func testStableTapStartsOver() {
        var recovery = TapRecovery()
        _ = recovery.disabled(at: t0)
        _ = recovery.enableFailed()
        _ = recovery.enableFailed()
        recovery.enabled(at: t0 + 10)
        let later = t0 + 10 + TapRecovery.stableInterval
        XCTAssertEqual(recovery.disabled(at: later), 0)
        XCTAssertEqual(recovery.failures, 0)
    }

    func testResyncEmitsOnlyAMissedRelease() {
        XCTAssertEqual(HotkeyMonitor.resyncEvent(wasPressed: true, heldNow: false), .released)
        XCTAssertNil(HotkeyMonitor.resyncEvent(wasPressed: true, heldNow: true))
        XCTAssertNil(HotkeyMonitor.resyncEvent(wasPressed: false, heldNow: true))
        XCTAssertNil(HotkeyMonitor.resyncEvent(wasPressed: false, heldNow: false))
    }

    func testDegradedHealthNamesTheCause() {
        XCTAssertEqual(HotkeyHealth.degraded(secureInput: true), .secureInputActive)
        XCTAssertEqual(HotkeyHealth.degraded(secureInput: false), .tapDisabled)
        XCTAssertNil(HotkeyHealth.ok.statusText)
        XCTAssertEqual(HotkeyHealth.secureInputActive.statusText, "hotkey unavailable, secure input active")
        XCTAssertEqual(HotkeyHealth.tapDisabled.statusText, "hotkey tap disabled")
    }
}
