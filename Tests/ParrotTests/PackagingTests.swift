import XCTest
@testable import ParrotCore

final class PackagingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - App role

    func testAppLaunchNeedsBundleNoArgumentsAndNoTerminal() {
        XCTAssertTrue(AppLaunch.isAppLaunch(arguments: ["parrot"], stdinIsTTY: false, inBundle: true))
        XCTAssertTrue(AppLaunch.isAppLaunch(arguments: ["parrot", "-psn_0_12345"], stdinIsTTY: false, inBundle: true))
        XCTAssertFalse(AppLaunch.isAppLaunch(arguments: ["parrot"], stdinIsTTY: true, inBundle: true))
        XCTAssertFalse(AppLaunch.isAppLaunch(arguments: ["parrot"], stdinIsTTY: false, inBundle: false))
        XCTAssertFalse(AppLaunch.isAppLaunch(arguments: ["parrot", "doctor"], stdinIsTTY: false, inBundle: true))
        XCTAssertFalse(AppLaunch.isAppLaunch(arguments: ["parrot", "--no-overlay"], stdinIsTTY: false, inBundle: true))
    }

    func testPermissionFailuresPointAtTheirPane() {
        XCTAssertEqual(AppLaunch.appMessage(for: .accessibilityMissing).2, "Privacy_Accessibility")
        XCTAssertEqual(AppLaunch.appMessage(for: .microphoneDenied).2, "Privacy_Microphone")
        XCTAssertNil(AppLaunch.appMessage(for: .noModelsRegistered).2)
        // The app's wording never sends the user to a terminal.
        for failure in [StartupFailure.accessibilityMissing, .microphoneDenied] {
            XCTAssertFalse(AppLaunch.appMessage(for: failure).1.contains("parrot setup"))
        }
    }

    // MARK: - Command line link

    func testLinkStates() throws {
        let target = dir.appendingPathComponent("Parrot.app/Contents/MacOS/parrot")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let link = dir.appendingPathComponent("parrot")

        XCTAssertEqual(CommandLineLink.state(at: link, target: target), .missing)

        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(CommandLineLink.state(at: link, target: target), .linked)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Applications/Old/Parrot.app/Contents/MacOS/parrot")
        XCTAssertEqual(
            CommandLineLink.state(at: link, target: target),
            .linkedElsewhere("/Applications/Old/Parrot.app/Contents/MacOS/parrot")
        )

        try FileManager.default.removeItem(at: link)
        FileManager.default.createFile(atPath: link.path, contents: Data("old binary".utf8))
        XCTAssertEqual(CommandLineLink.state(at: link, target: target), .plainFile)

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: false)
        XCTAssertEqual(CommandLineLink.state(at: link, target: target), .other)
    }

    func testInstallReplacesAPlainFileWithALink() throws {
        let target = dir.appendingPathComponent("target")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        let link = dir.appendingPathComponent("parrot")
        FileManager.default.createFile(atPath: link.path, contents: Data("old binary".utf8))

        try CommandLineLink.install(at: link, target: target, privileged: false)
        XCTAssertEqual(CommandLineLink.state(at: link, target: target), .linked)
    }

    func testInstallRefusesAnUnwritableDirectoryWithoutPrivilege() {
        let link = URL(fileURLWithPath: "/System/parrot-test-link")
        XCTAssertThrowsError(try CommandLineLink.install(at: link, target: dir, privileged: false)) { error in
            guard case CommandLineLink.LinkError.notWritable = error else {
                return XCTFail("expected notWritable, got \(error)")
            }
        }
    }

    func testShellQuote() {
        XCTAssertEqual(CommandLineLink.shellQuote("/Applications/Parrot.app"), "'/Applications/Parrot.app'")
        XCTAssertEqual(CommandLineLink.shellQuote("it's"), "'it'\\''s'")
    }

    // MARK: - Legacy LaunchAgent

    func testRemovesALoadedAgentAndItsPlist() {
        let plist = dir.appendingPathComponent("com.digimata.parrot.plist")
        FileManager.default.createFile(atPath: plist.path, contents: Data("<plist/>".utf8))
        var calls: [[String]] = []

        let removed = LegacyLaunchAgent.remove(plist: plist, label: "com.digimata.parrot") { args in
            calls.append(args)
            return 0
        }

        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        let service = "gui/\(getuid())/com.digimata.parrot"
        XCTAssertEqual(calls, [["print", service], ["bootout", service]])
    }

    func testRemovesAPlistThatIsNotLoaded() {
        let plist = dir.appendingPathComponent("com.digimata.parrot.plist")
        FileManager.default.createFile(atPath: plist.path, contents: Data("<plist/>".utf8))
        var calls: [[String]] = []

        let removed = LegacyLaunchAgent.remove(plist: plist, label: "com.digimata.parrot") { args in
            calls.append(args)
            return args.first == "print" ? 113 : 0
        }

        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertFalse(calls.contains { $0.first == "bootout" })
    }

    func testNothingToRemove() {
        let plist = dir.appendingPathComponent("com.digimata.parrot.plist")
        var calls: [[String]] = []

        let removed = LegacyLaunchAgent.remove(plist: plist, label: "com.digimata.parrot") { args in
            calls.append(args)
            return 113
        }

        XCTAssertFalse(removed)
        XCTAssertEqual(calls.count, 1)
    }

    // MARK: - Paths

    func testPackagingPaths() {
        XCTAssertEqual(Paths.legacyLaunchAgentPlist.lastPathComponent, "com.digimata.parrot.plist")
        XCTAssertEqual(Paths.commandLineLink.path, "/usr/local/bin/parrot")
        XCTAssertEqual(Paths.instanceLock.deletingLastPathComponent().path, Paths.appSupport.path)
    }
}
