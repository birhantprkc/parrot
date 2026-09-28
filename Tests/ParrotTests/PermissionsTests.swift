import AVFoundation
import XCTest
@testable import ParrotCore

final class PermissionsTests: XCTestCase {
    private func state(_ accessibility: Bool, _ microphone: MicrophonePermission) -> PermissionState {
        PermissionState(accessibility: accessibility, microphone: microphone)
    }

    func testMicrophoneStatusMapping() {
        XCTAssertEqual(MicrophonePermission(.authorized), .granted)
        XCTAssertEqual(MicrophonePermission(.notDetermined), .notDetermined)
        XCTAssertEqual(MicrophonePermission(.denied), .denied)
        XCTAssertEqual(MicrophonePermission(.restricted), .denied)
    }

    func testAllGrantedNeedsBoth() {
        XCTAssertTrue(state(true, .granted).allGranted)
        XCTAssertFalse(state(false, .granted).allGranted)
        XCTAssertFalse(state(true, .notDetermined).allGranted)
        XCTAssertFalse(state(true, .denied).allGranted)
    }

    func testWindowShowsInTheAppWhileAGrantIsMissing() {
        XCTAssertTrue(Permissions.showsFirstRunWindow(isApp: true, state: state(false, .notDetermined)))
        XCTAssertTrue(Permissions.showsFirstRunWindow(isApp: true, state: state(false, .granted)))
        XCTAssertTrue(Permissions.showsFirstRunWindow(isApp: true, state: state(true, .notDetermined)))
        XCTAssertTrue(Permissions.showsFirstRunWindow(isApp: true, state: state(true, .denied)))
    }

    func testUpgradeWithGrantsIntactShowsNoWindow() {
        XCTAssertFalse(Permissions.showsFirstRunWindow(isApp: true, state: state(true, .granted)))
    }

    func testForegroundRunShowsNoWindow() {
        XCTAssertFalse(Permissions.showsFirstRunWindow(isApp: false, state: state(false, .notDetermined)))
        XCTAssertFalse(Permissions.showsFirstRunWindow(isApp: false, state: state(true, .granted)))
    }

    func testContinueOnAFreshInstallAsksForAccessibilityThenTheMicrophone() {
        XCTAssertEqual(
            Permissions.continueSteps(for: state(false, .notDetermined)),
            [.promptAccessibility, .openAccessibilitySettings, .requestMicrophone]
        )
    }

    func testContinueSkipsWhatIsGranted() {
        XCTAssertEqual(
            Permissions.continueSteps(for: state(false, .granted)),
            [.promptAccessibility, .openAccessibilitySettings]
        )
        XCTAssertEqual(Permissions.continueSteps(for: state(true, .notDetermined)), [.requestMicrophone])
        XCTAssertEqual(Permissions.continueSteps(for: state(true, .granted)), [])
    }

    func testDeniedMicrophoneOpensItsPaneOnlyOnceAccessibilityIsDone() {
        XCTAssertEqual(Permissions.continueSteps(for: state(true, .denied)), [.openMicrophoneSettings])
        XCTAssertEqual(
            Permissions.continueSteps(for: state(false, .denied)),
            [.promptAccessibility, .openAccessibilitySettings]
        )
    }
}
