// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "WakeBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "WakeBar", targets: ["WakeBar"])
    ],
    targets: [
        .executableTarget(
            name: "WakeBar",
            path: "Sources/WakeBar"
        ),
        .testTarget(
            name: "WakeBarTests",
            dependencies: ["WakeBar"],
            path: "Tests/WakeBarTests"
        )
    ]
)
