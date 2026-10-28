// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Bekitzur",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "bekitzur", targets: ["bekitzur"]),
        .executable(name: "BekitzurApp", targets: ["BekitzurApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // whisper.cpp and llama.cpp each bundle their own ggml; keep them in separate modules so their headers never meet.
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip",
            checksum: "e57f8c48933000acabc13bb913fbe82805d483a2deff692cc6738836bd92393b"
        ),
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11669/llama-b11669-xcframework.zip",
            checksum: "937891f26734c29c80817cdf8bf59b139c84a9c6fb36a4ad6ce31cceea608e7c"
        ),
        .target(name: "BekitzurDomain"),
        .target(name: "BekitzurAudio"),
        .target(name: "BekitzurTranscription", dependencies: ["BekitzurDomain", "whisper"]),
        .target(name: "BekitzurSpeakers", dependencies: ["BekitzurDomain", .product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "BekitzurNotes", dependencies: ["BekitzurDomain", "llama"]),
        .target(name: "BekitzurVocabulary", dependencies: ["BekitzurDomain", "BekitzurNotes"]),
        .target(
            name: "BekitzurPipeline",
            dependencies: ["BekitzurDomain", "BekitzurAudio", "BekitzurTranscription", "BekitzurSpeakers", "BekitzurNotes", "BekitzurVocabulary"]
        ),
        .target(name: "BekitzurCapture"),
        .target(name: "BekitzurLibrary", dependencies: ["BekitzurDomain"]),
        .target(name: "BekitzurUpdates"),
        .executableTarget(
            name: "bekitzur",
            dependencies: [
                "BekitzurDomain",
                "BekitzurAudio",
                "BekitzurTranscription",
                "BekitzurSpeakers",
                "BekitzurNotes",
                "BekitzurPipeline",
                "BekitzurVocabulary",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "BekitzurApp",
            dependencies: ["BekitzurDomain", "BekitzurSpeakers", "BekitzurPipeline", "BekitzurCapture", "BekitzurLibrary", "BekitzurVocabulary", "BekitzurUpdates"]
        ),
        .testTarget(
            name: "BekitzurTests",
            dependencies: [
                "BekitzurDomain", "BekitzurAudio", "BekitzurNotes", "BekitzurPipeline", "BekitzurCapture", "BekitzurLibrary", "BekitzurVocabulary",
                "BekitzurUpdates",
            ]
        ),
    ]
)
