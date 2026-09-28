import XCTest
@testable import ParrotCore

final class UpdaterTests: XCTestCase {
    // A syntactically valid Ed25519 public key (32 zero bytes); never used to verify anything.
    private let key = Data(count: 32).base64EncodedString()
    private let feed = "https://github.com/humanitas-labs/parrot/releases/latest/download/appcast.xml"

    private func info(version: String, key: String? = nil, feed: String? = nil) -> [String: Any] {
        var info: [String: Any] = ["CFBundleVersion": version]
        info["SUPublicEDKey"] = key ?? self.key
        info["SUFeedURL"] = feed ?? self.feed
        return info
    }

    func testAReleaseBuildWithARealKeyUpdates() {
        XCTAssertNil(Updater.configurationProblem(info: info(version: "0.1.0")))
        XCTAssertNil(Updater.configurationProblem(info: info(version: "12")))
    }

    func testDevelopmentBuildsDoNotUpdate() {
        for version in ["0.0.6-3-gabc1234", "0.0.6-3-gabc1234-dirty", "abc1234", "0.0.0.", "", "1..2"] {
            XCTAssertNotNil(Updater.configurationProblem(info: info(version: version)), version)
        }
        XCTAssertNotNil(Updater.configurationProblem(info: [:]))
    }

    func testThePlaceholderKeyTurnsUpdatesOff() {
        let placeholder = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"
        XCTAssertNotNil(Updater.configurationProblem(info: info(version: "0.1.0", key: placeholder)))
        XCTAssertNotNil(Updater.configurationProblem(info: info(version: "0.1.0", key: Data(count: 16).base64EncodedString())))
    }

    func testTheFeedMustBeSet() {
        XCTAssertNotNil(Updater.configurationProblem(info: info(version: "0.1.0", feed: "not a url")))
    }

    func testThePackagedInfoPlistPointsAtTheReleaseFeed() throws {
        // packaging/Info.plist, found from this file: Tests/ParrotTests/ → repo root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("packaging/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["SUFeedURL"] as? String, feed)
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUScheduledCheckInterval"] as? Int, 86400)
        XCTAssertEqual(plist["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(plist["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertNotNil(plist["SUPublicEDKey"] as? String)
    }
}
