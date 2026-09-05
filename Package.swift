// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Overseer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Overseer", targets: ["Overseer"]),
    ],
    targets: [
        .executableTarget(
            name: "Overseer",
            path: "Sources/Overseer"
        ),
    ]
)
