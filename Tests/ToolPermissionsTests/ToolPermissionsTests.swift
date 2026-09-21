import Foundation
import XCTest
@testable import ToolPermissions

final class ToolPermissionsTests: XCTestCase {
    let known: Set<String> = ["scoped_read", "scoped_write", "vault_read", "vault_write", "vault_list", "mail_read", "mail_send", "download_file", "new_tool"]
    func policy(_ tools: [String: Any], path: String = "/tmp/config/permissions.json") throws -> ToolPermissions {
        try ToolPermissions.parse(JSONSerialization.data(withJSONObject: ["version": 1, "tools": tools]), path: path, knownTools: known)
    }
    func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testMissingDefaultAllowsOnlyKnownReadsAndExplicitMissingFailsClosed() throws {
        let missing = try temp().appendingPathComponent("missing.json").path
        let defaults = ToolPermissions.load(knownTools: known, environment: [:], defaultPath: missing)
        XCTAssertTrue(defaults.allows("mail_read"))
        for name in ["mail_send", "vault_write", "download_file", "new_tool"] { XCTAssertFalse(defaults.allows(name)) }
        let explicit = ToolPermissions.load(knownTools: known, environment: ["MACOS_MCP_PERMISSIONS_FILE": missing])
        XCTAssertNotNil(explicit.error)
        XCTAssertFalse(explicit.allows("mail_read"))
    }
    func testOmittedAndDeniedToolsCannotBeCalled() throws {
        let p = try policy(["mail_read": ["allow": true], "mail_send": ["allow": false]])
        XCTAssertTrue(p.allows("mail_read"))
        for name in ["mail_send", "scoped_write", "new_tool"] {
            XCTAssertFalse(p.allows(name))
            XCTAssertNotNil(p.denial(tool: name, input: [:], allowedPaths: [:], vaultRoot: "/tmp/vault"))
        }
    }
    func testRejectsUnknownFieldsTypesToolsAndMisplacedConstraints() throws {
        for tools: [String: Any] in [
            ["typo": ["allow": true]], ["mail_read": ["allow": "true"]], ["mail_read": ["allow": 1]],
            ["mail_read": ["allow": true, "paths": ["notes"]]], ["scoped_write": ["allow": true, "modes": ["append"]]],
            ["vault_write": ["allow": true, "paths": ["../escape"]]], ["scoped_write": ["allow": true, "extra": true]],
        ] { XCTAssertThrowsError(try policy(tools)) }
        XCTAssertThrowsError(try ToolPermissions.parse(Data("{\"version\":true,\"tools\":{}}".utf8), path: "/tmp/p", knownTools: known))
        XCTAssertThrowsError(try ToolPermissions.parse(Data("{\"version\":1,\"tools\":{},\"default\":\"allow\"}".utf8), path: "/tmp/p", knownTools: known))
    }
    func testPathNamesModesAndPhysicalSubtreeRestrictions() throws {
        let root = try temp()
        let p = try policy(["scoped_write": ["allow": true, "path_names": ["notes"], "modes": ["append-section"], "paths": ["approved"]]])
        let roots = ["notes": root.path, "other": root.path]
        let valid: [String: Any] = ["path_name": " notes ", "mode": " APPEND-SECTION ", "path": " approved/new.md "]
        XCTAssertNil(p.denial(tool: "scoped_write", input: valid, allowedPaths: roots, vaultRoot: root.path))
        for change in [["path_name": "other"], ["mode": "upsert"], ["path": "approved-other/x"], ["path": "approved/../outside"], ["path": "/absolute"]] {
            XCTAssertNotNil(p.denial(tool: "scoped_write", input: valid.merging(change) { _, new in new }, allowedPaths: roots, vaultRoot: root.path))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("approved"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("outside"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("approved/link"), withDestinationURL: root.appendingPathComponent("outside"))
        XCTAssertNotNil(p.denial(tool: "scoped_write", input: valid.merging(["path": "approved/link/file.md"]) { _, new in new }, allowedPaths: roots, vaultRoot: root.path))
    }
    func testPolicyCannotBeWrittenThroughWhitespaceSymlinkOrHardlink() throws {
        let root = try temp(), file = root.appendingPathComponent("permissions.json")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: file)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("hardlink"))
        let p = try policy(["scoped_write": ["allow": true], "vault_write": ["allow": true]], path: file.path)
        for path in ["permissions.json", " permissions.json ", "alias", "hardlink"] {
            XCTAssertNotNil(p.denial(tool: "scoped_write", input: ["path_name": " notes ", "path": path, "mode": "upsert"], allowedPaths: ["notes": root.path], vaultRoot: root.path))
        }
        XCTAssertNotNil(p.denial(tool: "vault_write", input: ["path": "alias"], allowedPaths: [:], vaultRoot: root.path))
        XCTAssertTrue(p.protects(root.path), "download replacement must not delete the policy's parent directory")
    }
    func testReloadRevokesPermissionsAndMalformedFileNeverUsesOldPolicy() throws {
        let file = try temp().appendingPathComponent("policy.json")
        let env = ["MACOS_MCP_PERMISSIONS_FILE": file.path]
        try Data("{\"version\":1,\"tools\":{\"mail_send\":{\"allow\":true}}}".utf8).write(to: file)
        XCTAssertTrue(ToolPermissions.load(knownTools: known, environment: env).allows("mail_send"))
        try Data("{\"version\":1,\"tools\":{}}".utf8).write(to: file)
        XCTAssertFalse(ToolPermissions.load(knownTools: known, environment: env).allows("mail_send"))
        try Data("broken".utf8).write(to: file)
        XCTAssertNotNil(ToolPermissions.load(knownTools: known, environment: env).error)
        XCTAssertFalse(ToolPermissions.load(knownTools: known, environment: env).allows("mail_read"))
    }
    func testAuditLogAndRotationCannotModifyPolicy() throws {
        let root = try temp(), file = root.appendingPathComponent("audit.log.1")
        try Data("{}".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: file)
        let p = try policy(["scoped_write": ["allow": true]], path: file.path)
        for audit in [file.path, root.appendingPathComponent("audit.log").path, root.appendingPathComponent("alias").path] {
            XCTAssertNotNil(p.denial(tool: "scoped_write", input: ["path_name": "notes", "path": "safe.md", "mode": "upsert"], allowedPaths: ["notes": root.path], vaultRoot: root.path, auditLogPath: audit))
        }
    }

}
