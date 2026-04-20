import Foundation
import XCTest
@testable import ScopedFilesCore

final class ScopedFilesCoreTests: XCTestCase {
    private let fm = FileManager.default

    private func makeTempDir() throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("macos-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fixedService(root: URL, auditLog: URL) -> ScopedFilesService {
        ScopedFilesService(
            allowedPaths: ["test": root.path],
            auditLogPath: auditLog.path,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    func testLoadAllowedPathsParsesJSON() {
        let paths = loadAllowedPaths(from: [
            "ALLOWED_PATHS_JSON": "{\"notes\":\"/tmp/notes\",\"ops\":\"/tmp/ops\"}"
        ])

        XCTAssertEqual(paths["notes"], "/tmp/notes")
        XCTAssertEqual(paths["ops"], "/tmp/ops")
    }

    func testResolveScopedPathAllowsInternalSymlinkAndRejectsEscapes() throws {
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }

        let realDir = root.appendingPathComponent("real", isDirectory: true)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("inside-link").path, withDestinationPath: realDir.path)

        let outside = try makeTempDir()
        defer { try? fm.removeItem(at: outside) }
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("escape-link").path, withDestinationPath: outside.path)

        let allowed = resolveScopedPath(root: root.path, relative: "inside-link/file.txt")
        let rejected = resolveScopedPath(root: root.path, relative: "escape-link/file.txt")
        let traversal = resolveScopedPath(root: root.path, relative: "../nope.txt")

        XCTAssertEqual(allowed, realDir.appendingPathComponent("file.txt").path)
        XCTAssertNil(rejected)
        XCTAssertNil(traversal)
    }

    func testScopedWriteUpsertAndReadRoundTrip() throws {
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let auditLog = root.appendingPathComponent("audit.log")
        let service = fixedService(root: root, auditLog: auditLog)

        let writeResult = try service.write(ScopedWriteRequest(
            pathName: "test",
            path: "notes/hello.md",
            content: "Hello world\n",
            mode: "upsert",
            sectionAnchor: nil,
            sectionHeading: nil,
            operationId: "op-1",
            actor: "tester",
            metadata: ["source": "unit-test"]
        ))

        let readResult = try service.read(pathName: "test", path: "notes/hello.md")
        let onDisk = try String(contentsOf: root.appendingPathComponent("notes/hello.md"), encoding: .utf8)
        let auditText = try String(contentsOf: auditLog, encoding: .utf8)

        XCTAssertEqual(readResult.content, "Hello world\n")
        XCTAssertEqual(onDisk, "Hello world\n")
        XCTAssertEqual(writeResult.pathName, "test")
        XCTAssertEqual(writeResult.writtenPath, "notes/hello.md")
        XCTAssertFalse(writeResult.sha256.isEmpty)
        XCTAssertTrue(auditText.contains("\"action\":\"scoped_write\""))
        XCTAssertTrue(auditText.contains("\"path_name\":\"test\""))
        XCTAssertTrue(auditText.contains("\"operation_id\":\"op-1\""))
    }

    func testAppendSectionAddsManagedSection() throws {
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let service = fixedService(root: root, auditLog: root.appendingPathComponent("audit.log"))

        _ = try service.write(ScopedWriteRequest(
            pathName: "test",
            path: "notes/page.md",
            content: "# Title\n",
            mode: "upsert",
            sectionAnchor: nil,
            sectionHeading: nil,
            operationId: nil,
            actor: nil,
            metadata: nil
        ))

        _ = try service.write(ScopedWriteRequest(
            pathName: "test",
            path: "notes/page.md",
            content: "Fresh body",
            mode: "append-section",
            sectionAnchor: "deploy-target",
            sectionHeading: "Deploy Target",
            operationId: nil,
            actor: nil,
            metadata: nil
        ))

        let content = try String(contentsOf: root.appendingPathComponent("notes/page.md"), encoding: .utf8)
        XCTAssertTrue(content.contains("## Deploy Target"))
        XCTAssertTrue(content.contains("<!-- macos-mcp:section_anchor=deploy-target -->"))
        XCTAssertTrue(content.contains("Fresh body"))
    }

    func testSupersedeReplacesSectionAndArchivesOldBody() throws {
        let root = try makeTempDir()
        defer { try? fm.removeItem(at: root) }
        let service = fixedService(root: root, auditLog: root.appendingPathComponent("audit.log"))

        let initial = """
        # Title

        ## Deploy Target
        <!-- macos-mcp:section_anchor=deploy-target -->

        Old body
        """

        _ = try service.write(ScopedWriteRequest(
            pathName: "test",
            path: "notes/page.md",
            content: initial,
            mode: "upsert",
            sectionAnchor: nil,
            sectionHeading: nil,
            operationId: nil,
            actor: nil,
            metadata: nil
        ))

        _ = try service.write(ScopedWriteRequest(
            pathName: "test",
            path: "notes/page.md",
            content: "New body",
            mode: "supersede",
            sectionAnchor: "deploy-target",
            sectionHeading: nil,
            operationId: "op-2",
            actor: "tester",
            metadata: nil
        ))

        let content = try String(contentsOf: root.appendingPathComponent("notes/page.md"), encoding: .utf8)

        XCTAssertTrue(content.contains("## Deploy Target"))
        XCTAssertTrue(content.contains("New body"))
        XCTAssertTrue(content.contains("## Superseded"))
        XCTAssertTrue(content.contains("### Deploy Target"))
        XCTAssertTrue(content.contains("Old body"))
        XCTAssertTrue(content.contains("<!-- macos-mcp:operation_id=op-2 -->"))
        XCTAssertTrue(content.contains("<!-- macos-mcp:actor=tester -->"))
    }
}
