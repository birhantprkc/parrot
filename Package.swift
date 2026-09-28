// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "parrot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        // WhisperKit, renamed argmax-oss-swift. 1.1.0 is the first release with
        // argmax-oss-swift#514: before it, any transcription with promptTokens
        // came back empty, which the dictionary's example sentence relies on.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        // In-app updates (#50). A binary framework: scripts/build-app.sh
        // embeds it in Parrot.app/Contents/Frameworks and signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        // All behaviour: capture, hotkey, transcription, pipeline, settings, UI.
        .target(
            name: "ParrotCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        // Thin entry point: ArgumentParser commands that call into ParrotCore.
        .executableTarget(
            name: "parrot",
            dependencies: [
                "ParrotCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Unit tests against ParrotCore.
        .testTarget(
            name: "ParrotTests",
            dependencies: ["ParrotCore"]
        ),
    ]
)
