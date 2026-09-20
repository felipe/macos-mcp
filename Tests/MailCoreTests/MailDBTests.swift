import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CMailSQLite
#endif
@testable import MailCore

final class MailDBTests: XCTestCase {
    private let fileManager = FileManager.default

    func testSearchFiltersMetadataAndListsMailboxes() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let db = try MailDBConnection(mailRoot: fixture.versionRoot)

        XCTAssertEqual(try db.search(MailSearchQuery(query: "Invoice")).map(\.rowid), [1])
        XCTAssertEqual(try db.search(MailSearchQuery(sender: "alice@example.com")).map(\.rowid), [1])
        XCTAssertEqual(try db.search(MailSearchQuery(recipient: "finance@example.com")).map(\.rowid), [1])
        XCTAssertEqual(try db.search(MailSearchQuery(subject: "meeting")).map(\.rowid), [2])
        XCTAssertEqual(try db.search(MailSearchQuery(mailbox: "imap://test-account/Archive")).map(\.rowid), [2])
        XCTAssertEqual(try db.search(MailSearchQuery(since: 150, limit: 1)).map(\.rowid), [2])
        XCTAssertEqual(try db.search(MailSearchQuery(query: "_", limit: 100)).count, 0, "LIKE metacharacters must be bound as literals")
        XCTAssertEqual(try db.mailboxes(), [
            MailMailbox(rowid: 2, url: "imap://test-account/Archive"),
            MailMailbox(rowid: 1, url: "imap://test-account/INBOX")
        ])
    }

    func testMessageIDRejectsDuplicateHeaders() throws {
        let fixture = try makeFixture(duplicateMessageID: true)
        defer { try? fileManager.removeItem(at: fixture.root) }
        let db = try MailDBConnection(mailRoot: fixture.versionRoot)

        XCTAssertEqual(try db.message(messageID: "<one@example.test>").rowid, 1)
        XCTAssertThrowsError(try db.message(messageID: "<duplicate@example.test>")) { error in
            XCTAssertEqual(error as? MailDBError, .ambiguousMessage)
        }
        XCTAssertThrowsError(try db.message(rowid: 999))
    }

    func testMessageFileUsesRowIDAndFailsClosedForCopies() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let first = fixture.versionRoot.appendingPathComponent("test-account/INBOX.mbox/Data/0/0/1/Messages/1.emlx")
        let copy = fixture.versionRoot.appendingPathComponent("test-account/Archive.mbox/Data/0/0/1/Messages/1.emlx")
        try writeEMLX(copy, messageID: "<not-the-index-message@example.test>")

        let db = try MailDBConnection(mailRoot: fixture.versionRoot)
        XCTAssertEqual(try db.messageFile(rowid: 1).path, first.path)

        var binaryBody = Data("attachment\r\nMessage-ID: <misleading-body@example.test>\r\n".utf8)
        binaryBody.append(0xFF)
        try writeEMLX(first, messageID: "<one@example.test>", body: binaryBody)
        XCTAssertEqual(try db.messageFile(rowid: 1).path, first.path, "body bytes must not affect header identity")

        try writeEMLX(copy, messageID: "<one@example.test>")
        XCTAssertEqual(try db.messageFile(rowid: 1).path, first.path, "a rowid in another mailbox must not be accepted")

        let duplicateInsideMailbox = fixture.versionRoot.appendingPathComponent("test-account/INBOX.mbox/Data/1/0/1/Messages/1.emlx")
        try writeEMLX(duplicateInsideMailbox, messageID: "<one@example.test>")
        XCTAssertThrowsError(try db.messageFile(rowid: 1)) { error in
            XCTAssertEqual(error as? MailDBError, .ambiguousMessageFile)
        }
    }

    func testRejectsUnsupportedSchemaAndOpensReadonlyFixture() throws {
        let root = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let version = root.appendingPathComponent("V12")
        let data = version.appendingPathComponent("MailData")
        try fileManager.createDirectory(at: data, withIntermediateDirectories: true)
        try execute("CREATE TABLE messages (ROWID INTEGER PRIMARY KEY)", database: data.appendingPathComponent("Envelope Index"))
        XCTAssertThrowsError(try MailDBConnection(mailRoot: version)) { error in
            XCTAssertEqual(error as? MailDBError, .unsupportedSchema)
        }

        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fixture.database.path)
        let db = try MailDBConnection(mailRoot: fixture.versionRoot)
        XCTAssertEqual(try db.message(rowid: 1).subject, "Invoice % review")
    }

    private struct Fixture {
        let root: URL
        let versionRoot: URL
        let database: URL
    }

    private func makeFixture(duplicateMessageID: Bool = false) throws -> Fixture {
        let root = try temporaryDirectory()
        let version = root.appendingPathComponent("V12")
        let data = version.appendingPathComponent("MailData")
        try fileManager.createDirectory(at: data, withIntermediateDirectories: true)
        let database = data.appendingPathComponent("Envelope Index")
        let secondMessageID = duplicateMessageID ? "<duplicate@example.test>" : "<two@example.test>"
        try execute("""
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY, message_id INTEGER, global_message_id INTEGER,
          document_id TEXT, sender INTEGER, subject INTEGER, date_sent INTEGER, date_received INTEGER,
          mailbox INTEGER, read INTEGER, flagged INTEGER, deleted INTEGER);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY, address TEXT, comment TEXT);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY, subject TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY, url TEXT);
        CREATE TABLE recipients (ROWID INTEGER PRIMARY KEY, message INTEGER, address INTEGER, type INTEGER, position INTEGER);
        CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY, message_id INTEGER, message_id_header TEXT);
        INSERT INTO addresses VALUES (1, 'alice@example.com', 'Alice'), (2, 'finance@example.com', 'Finance'), (3, 'bob@example.com', 'Bob');
        INSERT INTO subjects VALUES (1, 'Invoice % review'), (2, 'Weekly meeting');
        INSERT INTO mailboxes VALUES (1, 'imap://test-account/INBOX'), (2, 'imap://test-account/Archive');
        INSERT INTO message_global_data VALUES (10, 101, '<one@example.test>'), (20, 202, '\(secondMessageID)');
        INSERT INTO messages VALUES (1, 101, 10, 'doc-one', 1, 1, 90, 100, 1, 0, 1, 0);
        INSERT INTO messages VALUES (2, 202, 20, 'doc-two', 3, 2, 190, 200, 2, 1, 0, 0);
        INSERT INTO recipients VALUES (1, 1, 2, 0, 0), (2, 2, 1, 0, 0);
        """, database: database)
        if duplicateMessageID {
            try execute("INSERT INTO message_global_data VALUES (30, 303, '<duplicate@example.test>'); INSERT INTO messages VALUES (3, 303, 30, 'doc-three', 3, 2, 210, 220, 2, 1, 0, 0);", database: database)
        }
        try writeEMLX(version.appendingPathComponent("test-account/INBOX.mbox/Data/0/0/1/Messages/1.emlx"), messageID: "<one@example.test>")
        return Fixture(root: root, versionRoot: version, database: database)
    }

    private func temporaryDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent("mail-db-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeEMLX(_ url: URL, messageID: String, body: Data = Data("Body".utf8)) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var payload = Data("Message-ID: \(messageID)\r\nSubject: fixture\r\n\r\n".utf8)
        payload.append(body)
        var emlx = Data("\(payload.count)\n".utf8)
        emlx.append(payload)
        try emlx.write(to: url)
    }

    private func execute(_ sql: String, database: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            throw MailDBError.databaseOpenFailed
        }
        defer { sqlite3_close(handle) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw MailDBError.queryFailed
        }
    }
}
