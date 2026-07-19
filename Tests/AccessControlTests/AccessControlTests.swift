import Foundation
import XCTest
@testable import AccessControl

final class AccessControlTests: XCTestCase {
    private let fm = FileManager.default

    private func writeAccessFile(_ json: String) throws -> String {
        let path = fm.temporaryDirectory
            .appendingPathComponent("macos-mcp-access-\(UUID().uuidString).json").path
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    // MARK: - load()

    func testEmptyWhenNothingConfigured() {
        let config = AccessConfig.load(environment: ["MACOS_MCP_ACCESS_FILE": "/nonexistent/path.json"])
        XCTAssertTrue(config.isEmpty)
        // An unconfigured config denies everything; the poller guards on isEmpty
        // so the unconfigured runtime default stays permissive.
        XCTAssertFalse(config.isAllowed(from: "+15551234567", chat: "+15551234567"))
    }

    func testOwnerPhoneSeedsAllowlist() {
        let config = AccessConfig.load(environment: [
            "MACOS_MCP_OWNER_PHONE": "(555) 123-4567",
            "MACOS_MCP_ACCESS_FILE": "/nonexistent/path.json",
        ])
        XCTAssertFalse(config.isEmpty)
        XCTAssertTrue(config.isAllowed(from: "+15551234567", chat: "+15551234567"))
        XCTAssertFalse(config.isAllowed(from: "+15559999999", chat: "+15559999999"))
    }

    func testConfigFileParsesPhonesAndGroups() throws {
        let path = try writeAccessFile("""
        {"allowFrom": ["+15551234567", "5559876543"], "groups": ["chat646855985291785786"]}
        """)
        let config = AccessConfig.load(environment: ["MACOS_MCP_ACCESS_FILE": path])
        XCTAssertEqual(config.allowFrom, ["+15551234567", "+15559876543"])
        XCTAssertEqual(config.allowedGroups, ["chat646855985291785786"])
    }

    func testOwnerPhoneAndFileMerge() throws {
        let path = try writeAccessFile(#"{"allowFrom": ["+15559876543"]}"#)
        let config = AccessConfig.load(environment: [
            "MACOS_MCP_OWNER_PHONE": "+15551234567",
            "MACOS_MCP_ACCESS_FILE": path,
        ])
        XCTAssertEqual(config.allowFrom, ["+15551234567", "+15559876543"])
    }

    // MARK: - isAllowed()

    func testDirectMessageAllowlist() throws {
        let path = try writeAccessFile(#"{"allowFrom": ["+15551234567"]}"#)
        let config = AccessConfig.load(environment: ["MACOS_MCP_ACCESS_FILE": path])
        XCTAssertTrue(config.isAllowed(from: "+15551234567", chat: "+15551234567"))
        XCTAssertFalse(config.isAllowed(from: "+15550000000", chat: "+15550000000"))
    }

    func testGroupAllowlistGatesOnChatIdentifier() throws {
        let path = try writeAccessFile("""
        {"allowFrom": ["+15551234567"], "groups": ["chat646855985291785786"]}
        """)
        let config = AccessConfig.load(environment: ["MACOS_MCP_ACCESS_FILE": path])
        // Allowed group passes even from a sender not on the DM allowlist.
        XCTAssertTrue(config.isAllowed(from: "+15550000000", chat: "chat646855985291785786"))
        // Unknown group is blocked.
        XCTAssertFalse(config.isAllowed(from: "+15551234567", chat: "chat999999999999999999"))
    }

    func testEmailHandleIsNotTreatedAsGroup() throws {
        let path = try writeAccessFile(#"{"allowFrom": ["friend@example.com"]}"#)
        let config = AccessConfig.load(environment: ["MACOS_MCP_ACCESS_FILE": path])
        // chat_identifier starting with "chat" but non-numeric must be a DM.
        XCTAssertTrue(config.isAllowed(from: "friend@example.com", chat: "chat@example.com"))
    }

    // MARK: - normalizePhone()

    func testNormalizePhone() {
        XCTAssertEqual(AccessConfig.normalizePhone("(555) 123-4567"), "+15551234567")
        XCTAssertEqual(AccessConfig.normalizePhone("5551234567"), "+15551234567")
        XCTAssertEqual(AccessConfig.normalizePhone("15551234567"), "+15551234567")
        XCTAssertEqual(AccessConfig.normalizePhone("+445551234567"), "+445551234567")
        XCTAssertEqual(AccessConfig.normalizePhone("Friend@Example.com"), "friend@example.com")
    }

    func testIsGroupIdentifier() {
        XCTAssertTrue(AccessConfig.isGroupIdentifier("chat646855985291785786"))
        XCTAssertFalse(AccessConfig.isGroupIdentifier("chat"))
        XCTAssertFalse(AccessConfig.isGroupIdentifier("chat@example.com"))
        XCTAssertFalse(AccessConfig.isGroupIdentifier("+15551234567"))
    }
}
