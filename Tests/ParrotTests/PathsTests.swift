import XCTest
@testable import ParrotCore

final class PathsTests: XCTestCase {
    func testFilesLiveUnderTheirDirectories() {
        XCTAssertEqual(Paths.settingsFile.deletingLastPathComponent().path, Paths.config.path)
        XCTAssertEqual(Paths.dictionaryFile.deletingLastPathComponent().path, Paths.config.path)
        XCTAssertEqual(Paths.daemonOutLog.deletingLastPathComponent().path, Paths.logs.path)
        XCTAssertEqual(Paths.daemonErrLog.deletingLastPathComponent().path, Paths.logs.path)
        XCTAssertEqual(Paths.dumpWav.deletingLastPathComponent().path, Paths.caches.path)
    }

    func testNothingLivesInTmpOrDocuments() {
        let all = [
            Paths.config, Paths.appSupport, Paths.logs, Paths.caches, Paths.settingsFile, Paths.dictionaryFile,
            Paths.daemonOutLog, Paths.daemonErrLog, Paths.dumpWav,
        ]
        for url in all {
            XCTAssertFalse(url.path.hasPrefix("/tmp"), url.path)
            XCTAssertFalse(url.path.hasPrefix(Paths.documents.path), url.path)
        }
    }

    func testLaunchAgentPlist() {
        XCTAssertTrue(
            Paths.launchAgentPlist(label: "com.digimata.parrot").path
                .hasSuffix("/Library/LaunchAgents/com.digimata.parrot.plist")
        )
    }
}
