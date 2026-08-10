// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "asc-upload",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/MortenGregersen/Bagbutik.git", from: "24.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "asc-upload",
            dependencies: [
                .product(name: "BagbutikAppStore", package: "Bagbutik"),
            ]
        ),
    ]
)
