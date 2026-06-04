// swift-tools-version:5.9
import PackageDescription

// VoxBarber – natív macOS hangszerkesztő alkalmazás SPM konfigurációja.
let package = Package(
    name: "VoxBarber",
    platforms: [.macOS(.v13)],
    dependencies: [
        // SFBAudioEngine: WAV, MP3, AAC, FLAC és OGG dekódolás/enkódolás
        .package(url: "https://github.com/sbooth/SFBAudioEngine", from: "0.10.0")
    ],
    targets: [
        // Audio réteg – önálló library, tesztelhető
        .target(
            name: "VoxBarberAudio",
            dependencies: [
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine")
            ],
            path: "Sources/VoxBarberAudio"
        ),
        .executableTarget(
            name: "VoxBarber",
            dependencies: [
                "VoxBarberAudio",
                .product(name: "SFBAudioEngine", package: "SFBAudioEngine")
            ],
            path: "Sources/VoxBarber",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "VoxBarberTests",
            dependencies: ["VoxBarberAudio"],
            path: "Tests/VoxBarberTests"
        )
    ]
)
