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

    func testMicrophoneAllowAsksOnceThenOpensItsPane() {
        XCTAssertEqual(Permissions.allowSteps(for: .microphone, in: state(false, .notDetermined)), [.requestMicrophone])
        XCTAssertEqual(Permissions.allowSteps(for: .microphone, in: state(false, .denied)), [.openMicrophoneSettings])
        XCTAssertEqual(Permissions.allowSteps(for: .microphone, in: state(false, .granted)), [])
    }

    func testAccessibilityAllowPromptsAndOpensItsPane() {
        XCTAssertEqual(
            Permissions.allowSteps(for: .accessibility, in: state(false, .granted)),
            [.promptAccessibility, .openAccessibilitySettings]
        )
        XCTAssertEqual(Permissions.allowSteps(for: .accessibility, in: state(true, .notDetermined)), [])
    }
}
