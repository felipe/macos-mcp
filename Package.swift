// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macos-mcp-logic-tests",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ScopedFilesCore", targets: ["ScopedFilesCore"]),
    ],
    targets: [
        .target(
            name: "ScopedFilesCore",
            path: "Sources",
            sources: ["ScopedFilesCore.swift"]
        ),
        .testTarget(
            name: "ScopedFilesCoreTests",
            dependencies: ["ScopedFilesCore"],
            path: "Tests/ScopedFilesCoreTests"
        ),
    ]
)
