// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranscribeKit",
    defaultLocalization: "en",
    platforms: [
        .macOS("15.0"),
        .iOS("17.0")
    ],
    products: [
        .library(name: "TranscribeKit", targets: ["TranscribeKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "TranscribeKit",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift")
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
