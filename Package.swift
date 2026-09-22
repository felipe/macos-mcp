// swift-tools-version: 5.9
import PackageDescription

let mailSources = ["MailDB.swift", "MailParser.swift", "MailActions.swift", "MailInterface.swift", "MailContract.swift", "HimalayaAdapter.swift"]
let executableSources = ["Attachments.swift", "Calendar.swift", "ICloud.swift", "Launch.swift", "Mail.swift",
                         "Messages.swift", "Send.swift", "Serve.swift", "Shared.swift", "main.swift",
                         "Automation.swift", "Contacts.swift", "Notes.swift", "Permissions.swift", "Reminders.swift"]

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
        .target(name: "ToolPermissions", path: "Sources",
                exclude: executableSources + mailSources + ["ScopedFilesCore.swift", "AccessControl.swift", "CMailSQLite"], sources: ["ToolPermissions.swift"]),
        .testTarget(name: "ToolPermissionsTests", dependencies: ["ToolPermissions"], path: "Tests/ToolPermissionsTests"),
        .systemLibrary(name: "CMailSQLite", path: "Sources/CMailSQLite", pkgConfig: "sqlite3"),
        .target(name: "MailCore", dependencies: ["CMailSQLite"], path: "Sources",
                exclude: executableSources + ["ScopedFilesCore.swift", "AccessControl.swift", "ToolPermissions.swift", "CMailSQLite"], sources: mailSources),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore", "CMailSQLite"], path: "Tests/MailCoreTests"),
        .target(
            name: "ScopedFilesCore",
            path: "Sources",
            exclude: executableSources + mailSources + ["AccessControl.swift", "ToolPermissions.swift", "CMailSQLite"],
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
            exclude: executableSources + mailSources + ["ScopedFilesCore.swift", "ToolPermissions.swift", "CMailSQLite"],
            sources: ["AccessControl.swift"]
        ),
        .testTarget(
            name: "AccessControlTests",
            dependencies: ["AccessControl"],
            path: "Tests/AccessControlTests"
        ),
    ]
)
