// swift-tools-version: 6.2
// Sevenfold — a macOS archive manager laid out like 7-Zip File Manager.
// Open this file in Xcode 26 or later, or run `swift run` from this folder.

import PackageDescription

let package = Package(
    name: "Sevenfold",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Sevenfold", targets: ["Sevenfold"])
    ],
    targets: [
        .executableTarget(
            name: "Sevenfold",
            path: "Sources/Sevenfold",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
