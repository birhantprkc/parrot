import XCTest
@testable import ParrotCore

final class StartupTests: XCTestCase {
    private struct Boom: Error {}

    func testUserActionFailuresArePermanent() {
        XCTAssertTrue(StartupFailure.accessibilityMissing.isPermanent)
        XCTAssertTrue(StartupFailure.microphoneDenied.isPermanent)
        XCTAssertTrue(StartupFailure.unknownModel("bogus").isPermanent)
        XCTAssertTrue(StartupFailure.noModelsRegistered.isPermanent)
    }

    func testRetryableFailuresAreNotPermanent() {
        XCTAssertFalse(StartupFailure.checksFailed.isPermanent)
        XCTAssertFalse(StartupFailure.warmupFailed(Boom()).isPermanent)
        XCTAssertFalse(StartupFailure.hotkeyUnavailable(Boom()).isPermanent)
    }

    func testPermanentMessagesNameTheFixAndRestart() {
        let failures: [StartupFailure] = [
            .accessibilityMissing, .microphoneDenied, .unknownModel("bogus"), .noModelsRegistered,
        ]
        for failure in failures {
            XCTAssertTrue(failure.message.contains("\n  fix: "), failure.message)
            XCTAssertTrue(
                failure.message.contains("`launchctl kickstart gui/\(getuid())/com.digimata.parrot`"),
                failure.message
            )
        }
    }

    func testUnknownModelMessage() {
        XCTAssertTrue(StartupFailure.unknownModel("bogus").message.hasPrefix("unknown model: bogus\n"))
    }

    func testResolveModel() throws {
        XCTAssertEqual(try Startup.resolveModel(nil).id, ModelRegistry.recommended()?.id)
        XCTAssertEqual(try Startup.resolveModel("whisper-small.en").id, "whisper-small.en")
        XCTAssertThrowsError(try Startup.resolveModel("bogus")) { error in
            guard case StartupFailure.unknownModel("bogus") = error else {
                return XCTFail("expected unknownModel, got \(error)")
            }
        }
    }
}
