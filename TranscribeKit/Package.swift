// swift-tools-version: 6.2
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
        // 1.1.1: a cancelled model download no longer looks complete, and
        // Hugging Face tokens are no longer read from disk unasked
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
        // Parakeet-family CoreML runtime (Pianissimo, Parakeet v3). `traits: []`
        // opts out of FluidAudio's TTS, diarization and text-normalization
        // subsystems — only the ASR pipeline is used here. Pre-1.0 package, so
        // minor versions can break API: stay within 0.18.x.
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            .upToNextMinor(from: "0.18.3"),
            traits: []
        )
    ],
    targets: [
        .target(
            name: "TranscribeKit",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            resources: [
                .process("Resources")
            ]
        )
    ],
    // The manifest needs tools 6.2 for package traits; the sources stay in
    // Swift 5 language mode like the app targets.
    swiftLanguageModes: [.v5]
)
