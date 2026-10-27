// swift-tools-version: 6.2
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "VibeZip",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "VibeZipCore", targets: ["VibeZipCore"]),
        .executable(name: "VibeZip", targets: ["VibeZip"])
    ],
    targets: [
        .target(name: "CVibeZip", publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-I", root + "/../CPP"])],
            linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux])), .linkedLibrary("iconv", .when(platforms: [.macOS]))]),
        .target(name: "VibeZipCore", dependencies: ["CVibeZip"], resources: [.process("Resources")]),
        .executableTarget(name: "VibeZip", dependencies: ["VibeZipCore"],
            linkerSettings: [.linkedFramework("AppKit", .when(platforms: [.macOS]))]),
        .testTarget(name: "VibeZipCoreTests", dependencies: ["VibeZipCore"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
