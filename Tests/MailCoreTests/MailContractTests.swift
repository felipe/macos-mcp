import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#else
import CMailSQLite
#endif
@testable import MailCore

final class MailContractTests: XCTestCase {
    private var root: URL!
    private var actions: [(String, [String: String])] = []
    private var contract: MailContract!
    private let environment = ["MACOS_MAIL_ACCOUNTS_JSON": "{\"work\":{\"id\":\"a\",\"email\":\"me@example.test\"}}"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("MailData"), withIntermediateDirectories: true)
        try sql("""
        CREATE TABLE messages (ROWID INTEGER PRIMARY KEY,message_id INTEGER,global_message_id INTEGER,document_id TEXT,sender INTEGER,subject INTEGER,date_received INTEGER,date_sent INTEGER,mailbox INTEGER,read INTEGER,flagged INTEGER,deleted INTEGER);
        CREATE TABLE subjects (ROWID INTEGER PRIMARY KEY,subject TEXT);
        CREATE TABLE addresses (ROWID INTEGER PRIMARY KEY,address TEXT,comment TEXT);
        CREATE TABLE mailboxes (ROWID INTEGER PRIMARY KEY,url TEXT);
        CREATE TABLE recipients (message INTEGER,address INTEGER,type INTEGER,position INTEGER);
        CREATE TABLE message_global_data (ROWID INTEGER PRIMARY KEY,message_id_header TEXT);
        INSERT INTO subjects VALUES(1,'Invoice review');
        INSERT INTO addresses VALUES(1,'alice@example.test','Alice'),(2,'team@example.test','Team');
        INSERT INTO mailboxes VALUES(1,'imap://a/INBOX'),(2,'imap://a/Archive'),(3,'imap://b/INBOX');
        INSERT INTO messages VALUES(1,1,1,'1',1,1,100,100,1,0,1,0),(2,2,2,'2',1,1,100,100,1,1,0,0),(3,3,3,'3',1,1,100,100,3,0,0,0);
        INSERT INTO message_global_data VALUES(1,'<1@example.test>'),(2,'<2@example.test>'),(3,'<3@example.test>');
        INSERT INTO recipients VALUES(1,2,0,0);
        """)
        for id in 1...3 {
            let account = id == 3 ? "b" : "a"
            let path = root.appendingPathComponent("\(account)/INBOX.mbox/Messages/\(id).emlx")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let raw = "Message-ID: <\(id)@example.test>\r\nFrom: alice@example.test\r\nContent-Type: text/plain\r\n\r\nBody \(id)"
            try Data("\(raw.utf8.count)\n\(raw)".utf8).write(to: path)
        }
        contract = MailContract(database: { try MailDBConnection(mailRoot: self.root) }, environment: environment, perform: { action, args in
            self.actions.append((action, args)); return ["status": action == "draft" ? "draft_saved" : "queued"]
        })
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root); contract = nil }
    private func sql(_ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent("MailData/Envelope Index").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MailDBError.queryFailed }
    }
    private func call(_ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] { try contract.execute(tool: name, input: args) }
    private func firstID() throws -> String {
        let result = try call("mail_envelope_list", ["account": "work"])
        return (result["envelopes"] as! [[String: Any]])[0]["id"] as! String
    }

    func testAccountScopePaginationAndEnvelopeReadRoundTrip() throws {
        XCTAssertThrowsError(try call("mail_envelope_list"))
        XCTAssertThrowsError(try call("mail_envelope_list", ["account": "missing"]))
        let first = try call("mail_envelope_list", ["account": "work", "page_size": 1])
        let second = try call("mail_envelope_list", ["account": "a", "page_size": 1, "page": 2])
        XCTAssertEqual(first["has_more"] as? Bool, true)
        XCTAssertEqual(second["has_more"] as? Bool, false)
        let id = (first["envelopes"] as! [[String: Any]])[0]["id"] as! String
        XCTAssertTrue(id.hasPrefix("am1."))
        XCTAssertEqual(id, try firstID(), "Unchanged indexed identity must produce the same token")
        XCTAssertEqual(try call("mail_message_read", ["account": "work", "id": id])["body"] as? String, "Body 2")
        XCTAssertEqual(try call("read_email", ["account": "a", "id": id])["text"] as? String, "Body 2")
        XCTAssertThrowsError(try call("mail_message_read", ["account": "b", "id": id]))
        XCTAssertThrowsError(try call("mail_message_read", ["account": "a", "mailbox": "Archive", "id": id]))
        XCTAssertThrowsError(try call("mail_message_read", ["account": "a", "id": "2"]))
        XCTAssertTrue(actions.isEmpty)
    }
    func testStaleReferencesFailWithoutMutations() throws {
        let id = try firstID()
        try sql("UPDATE messages SET mailbox=2 WHERE ROWID=2")
        XCTAssertThrowsError(try call("flag_email", ["account": "work", "id": id, "flags": ["Seen"], "action": "add"]))
        XCTAssertTrue(actions.isEmpty)
    }
    func testChangedRFCIdentityAndMissingCacheFailClosed() throws {
        let id = try firstID()
        try sql("UPDATE message_global_data SET message_id_header='<replacement@example.test>' WHERE ROWID=2")
        XCTAssertThrowsError(try call("mail_message_read", ["account": "a", "id": id]))
        try sql("UPDATE message_global_data SET message_id_header='<2@example.test>' WHERE ROWID=2")
        try FileManager.default.removeItem(at: root.appendingPathComponent("a/INBOX.mbox/Messages/2.emlx"))
        XCTAssertThrowsError(try call("mail_message_read", ["account": "a", "id": id]))
        XCTAssertThrowsError(try call("mail_message_forward", ["account": "a", "id": id, "to": ["you@example.test"], "body": "Forward", "confirm": true]))
        XCTAssertTrue(actions.isEmpty)
    }
    func testAliasesProduceCompatibleTextAndMetadataFiltering() throws {
        let result = try call("search_emails", ["account": "work", "query": "from alice and subject Invoice\\ review and flag Flagged order by date desc"])
        let text = result["text"] as! String
        XCTAssertTrue(text.hasPrefix("Found 1 emails matching"))
        XCTAssertTrue(text.contains("| alice@example.test | Invoice review [Flagged]"))
        XCTAssertEqual(try call("list_folders", ["account": "work"])["text"] as? String, "- Archive\n- INBOX")
        for query in ["body secret", "from alice or to bob", "not flag Seen", "from alice to bob", "flag Draft", "subject x and subject y", "after 2026-01-01", "subject x order by subject asc", "subject x and", "subject 'unterminated"] {
            XCTAssertThrowsError(try call("search_emails", ["account": "work", "query": query]), query)
        }
    }
    func testPreviewConfirmedSendAndDraftHaveDistinctSideEffects() throws {
        var args: [String: Any] = ["account": "work", "to": "you@example.test", "subject": "Hi", "body": "Hi"]
        XCTAssertTrue((try call("compose_email", args)["text"] as! String).contains("not sent"))
        XCTAssertTrue(actions.isEmpty)
        args["confirm"] = true
        XCTAssertTrue((try call("compose_email", args)["text"] as! String).contains("queued"))
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions[0].0, "send")
        XCTAssertEqual(actions[0].1["account"], "me@example.test")
        _ = try call("mail_message_draft", ["account": "work", "subject": "Hi", "body": "draft"])
        XCTAssertEqual(actions.last?.0, "draft")
        let id = try firstID()
        _ = try call("mail_message_reply", ["account": "work", "id": id, "body": "Thanks"])
        XCTAssertEqual(actions.count, 2)
        _ = try call("mail_message_reply", ["account": "work", "id": id, "body": "Thanks", "confirm": true])
        XCTAssertEqual(actions.last?.0, "reply")
        XCTAssertEqual(actions.last?.1["message_id"], "<2@example.test>")
        _ = try call("mail_message_forward", ["account": "work", "id": id, "to": ["you@example.test"], "body": "Forward"])
        XCTAssertEqual(actions.count, 3)
        _ = try call("mail_message_forward", ["account": "work", "id": id, "to": ["you@example.test"], "body": "Forward", "confirm": true])
        XCTAssertEqual(actions.last?.0, "forward")
        XCTAssertEqual(actions.count, 4)
    }
    func testFlagsMovesAndUnsupportedFlagsAreAtomic() throws {
        let id = try firstID()
        XCTAssertThrowsError(try call("flag_email", ["account": "work", "id": id, "flags": ["Seen", "Draft"], "action": "add"]))
        XCTAssertTrue(actions.isEmpty)
        _ = try call("flag_email", ["account": "work", "id": id, "flags": ["Seen", "Flagged"], "action": "remove"])
        XCTAssertEqual(actions.last?.1["read"], "false")
        XCTAssertEqual(actions.last?.1["flagged"], "false")
        XCTAssertEqual(actions.last?.1["account"], "me@example.test")
        _ = try call("move_email", ["account": "work", "id": id, "target_folder": "imap://a/Archive"])
        XCTAssertEqual(actions.last?.1["target_mailbox"], "Archive")
        XCTAssertThrowsError(try call("move_email", ["account": "work", "id": id, "target_folder": "imap://b/INBOX"]))
        XCTAssertEqual(actions.count, 2)
    }
    func testStrictInputAndCapabilityContract() throws {
        for args: [String: Any] in [["page": true], ["page": 1.5], ["page_size": 201], ["page": 1000001], ["typo": "x"]] {
            XCTAssertThrowsError(try mailContractCLIArguments(tool: "list_emails", input: args))
        }
        XCTAssertThrowsError(try mailContractCLIArguments(tool: "compose_email", input: ["to": "x", "subject": "y", "body": "z", "confirm": "true"]))
        let caps = try call("mail_capabilities")
        XCTAssertEqual(caps["version"] as? Int, 1)
        XCTAssertEqual((caps["compatibility"] as? [String: Any])?["version"] as? String, "2.1.2")
        XCTAssertEqual(Set(mailContractSpecs.map(\.name)).count, mailContractSpecs.count)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: mailContractDefinitions))
    }
}
