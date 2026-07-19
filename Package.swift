// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "macos-mcp-logic-tests",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ScopedFilesCore", targets: ["ScopedFilesCore"]),
        .library(name: "AccessControl", targets: ["AccessControl"]),
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
        .target(
            name: "AccessControl",
            path: "Sources",
            sources: ["AccessControl.swift"]
        ),
        .testTarget(
            name: "AccessControlTests",
            dependencies: ["AccessControl"],
            path: "Tests/AccessControlTests"
        ),
    ]
)
