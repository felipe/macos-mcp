import Foundation
import XCTest
@testable import ServeAccess

final class ServeAccessTests: XCTestCase {
    private let fm = FileManager.default
    private let goodToken = String(repeating: "a1", count: 32)

    private func writeTokenFile(_ contents: String, mode: Int) throws -> String {
        let path = fm.temporaryDirectory
            .appendingPathComponent("macos-mcp-token-\(UUID().uuidString)").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        return path
    }

    // MARK: - isLoopback

    func testLoopbackHosts() {
        for host in ["127.0.0.1", "127.0.0.2", "localhost", "LOCALHOST", "::1"] {
            XCTAssertTrue(ServeAccess.isLoopback(host), host)
        }
        for host in ["0.0.0.0", "::", "100.115.203.83", "192.168.1.217", "minerva"] {
            XCTAssertFalse(ServeAccess.isLoopback(host), host)
        }
    }

    // MARK: - startupError

    func testLoopbackOnlyNeedsNoToken() {
        XCTAssertNil(ServeAccess.startupError(hosts: ["127.0.0.1"], token: nil))
    }

    func testRemoteHostWithoutTokenIsRefused() {
        let refusal = ServeAccess.startupError(hosts: ["127.0.0.1", "100.115.203.83"], token: nil)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal!.contains("100.115.203.83"))
        XCTAssertFalse(refusal!.contains("127.0.0.1"))
    }

    func testAllInterfacesWithoutTokenIsRefused() {
        XCTAssertNotNil(ServeAccess.startupError(hosts: ["0.0.0.0"], token: nil))
    }

    func testRemoteHostWithTokenStarts() {
        XCTAssertNil(ServeAccess.startupError(hosts: ["127.0.0.1", "100.115.203.83"], token: goodToken))
    }

    // MARK: - loadToken

    func testNoTokenConfigured() throws {
        XCTAssertNil(try ServeAccess.loadToken(tokenFile: nil, environment: [:]))
    }

    func testTokenFileIsTrimmed() throws {
        let path = try writeTokenFile(goodToken + "\n", mode: 0o600)
        XCTAssertEqual(try ServeAccess.loadToken(tokenFile: path, environment: [:]), goodToken)
    }

    func testTokenFileFromEnvironment() throws {
        let path = try writeTokenFile(goodToken, mode: 0o600)
        XCTAssertEqual(try ServeAccess.loadToken(tokenFile: nil, environment: ["MACOS_MCP_TOKEN_FILE": path]), goodToken)
    }

    func testFlagWinsOverEnvironment() throws {
        let path = try writeTokenFile(goodToken, mode: 0o600)
        let token = try ServeAccess.loadToken(tokenFile: path, environment: ["MACOS_MCP_TOKEN": String(repeating: "z", count: 40)])
        XCTAssertEqual(token, goodToken)
    }

    func testTokenFromEnvironmentValue() throws {
        XCTAssertEqual(try ServeAccess.loadToken(tokenFile: nil, environment: ["MACOS_MCP_TOKEN": goodToken]), goodToken)
    }

    func testGroupReadableTokenFileIsRejected() throws {
        let path = try writeTokenFile(goodToken, mode: 0o640)
        XCTAssertThrowsError(try ServeAccess.loadToken(tokenFile: path, environment: [:]))
    }

    #if os(macOS)
    func testTokenFileWithACLIsRejected() throws {
        let path = try writeTokenFile(goodToken, mode: 0o600)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow read", path]
        try chmod.run()
        chmod.waitUntilExit()
        XCTAssertEqual(chmod.terminationStatus, 0)
        XCTAssertThrowsError(try ServeAccess.loadToken(tokenFile: path, environment: [:]))
    }
    #endif

    func testMissingTokenFileIsRejected() {
        XCTAssertThrowsError(try ServeAccess.loadToken(tokenFile: "/nonexistent/token", environment: [:]))
    }

    func testShortTokenIsRejected() {
        XCTAssertThrowsError(try ServeAccess.loadToken(tokenFile: nil, environment: ["MACOS_MCP_TOKEN": "short"]))
    }

    // MARK: - authorized

    func testBearerHeader() {
        XCTAssertTrue(ServeAccess.authorized(header: "Bearer \(goodToken)", token: goodToken))
        XCTAssertFalse(ServeAccess.authorized(header: nil, token: goodToken))
        XCTAssertFalse(ServeAccess.authorized(header: "", token: goodToken))
        XCTAssertFalse(ServeAccess.authorized(header: goodToken, token: goodToken))
        XCTAssertFalse(ServeAccess.authorized(header: "Bearer \(goodToken)x", token: goodToken))
        XCTAssertFalse(ServeAccess.authorized(header: "Bearer " + String(repeating: "b2", count: 32), token: goodToken))
    }
}
