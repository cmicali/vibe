// swift-tools-version:5.9
//
// WaveformCore: a waveform summary of an audio stream, the reads every display
// draws from, the raster that draws them, and its archive. C++17 over
// Accelerate and Compression, with no app types.

import PackageDescription

let package = Package(
    name: "WaveformCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "WaveformCore", targets: ["WaveformCore"]),
    ],
    targets: [
        .target(
            name: "WaveformCore",
            path: "Sources/WaveformCore",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedLibrary("compression"),
            ]
        ),
        .testTarget(
            name: "WaveformCoreTests",
            dependencies: ["WaveformCore"],
            path: "Tests/WaveformCoreTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
