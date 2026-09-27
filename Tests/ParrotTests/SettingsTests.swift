import XCTest
@testable import ParrotCore

final class SettingsTests: XCTestCase {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testEmptyObjectDecodesToDefaults() throws {
        XCTAssertEqual(try decode("{}"), Settings())
    }

    func testPartialObjectDecodesMissingKeysToDefaults() throws {
        XCTAssertEqual(try decode(#"{"hotkey": {}, "stats": {}}"#), Settings())
    }

    func testUnknownKeysAreIgnored() throws {
        XCTAssertEqual(try decode(#"{"fromTheFuture": 1}"#), Settings())
    }

    func testRoundTrips() throws {
        let data = try JSONEncoder().encode(Settings())
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), Settings())
    }
}
