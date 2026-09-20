import XCTest
@testable import MailCore

final class MailInterfaceTests: XCTestCase {
    func testRecipientArraysAndLiteralBodyStaySeparateArguments() throws {
        let args = try mailCLIArguments(tool: "mail_send", input: ["to": ["a@example.test", "b@example.test"], "subject": "Hi", "body": "--account\nquoted \"text\""])
        XCTAssertEqual(args.filter { $0 == "--to" }.count, 2)
        XCTAssertTrue(args.contains("--account\nquoted \"text\""))
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_send", input: ["to": "a@example.test", "subject": "Hi", "body": "Hi"]))
    }
    func testIdentifiersAreExclusive() throws {
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_read", input: [:]))
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_read", input: ["rowid": 1, "message_id": "x"]))
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_read", input: ["rowid": true]))
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_read", input: ["rowid": 1.5]))
        XCTAssertEqual(try mailCLIArguments(tool: "mail_read", input: ["rowid": 1]), ["mail", "read", "--rowid", "1"])
    }
    func testBooleansDoNotCoerceNumbersOrStrings() throws {
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_flag", input: ["rowid": 1, "read": "false"]))
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_flag", input: ["rowid": 1, "read": 0]))
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_flag", input: ["rowid": 1]))
        XCTAssertEqual(try mailCLIArguments(tool: "mail_flag", input: ["rowid": 1, "read": false]), ["mail", "flag", "--read", "false", "--rowid", "1"])
    }
    func testBoundsUnknownKeysAndNUL() throws {
        for limit in [0, -1, 201] { XCTAssertThrowsError(try mailCLIArguments(tool: "mail_search", input: ["limit": limit])) }
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_search", input: ["typo": "x"]))
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_search", input: ["query": "a\0b"]))
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_send", input: ["to": ["a@example.test\nb@example.test"], "subject": "s", "body": "b"]))
    }
    func testEmptyRecipientsAndUnscopedMessageIDAreRejected() {
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_send", input: ["to": [String](), "subject": "Hi", "body": "Hi"]))
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_read", input: ["message_id": " "]))
        XCTAssertThrowsError(try mailCLIArguments(tool: "mail_reply", input: ["message_id": "<x@example.test>", "body": "Hi"]))
        XCTAssertNoThrow(try mailCLIArguments(tool: "mail_reply", input: ["message_id": "<x@example.test>", "mailbox": "INBOX", "body": "Hi"]))
    }
    func testEveryToolSchemaIsSerializableAndDistinct() throws {
        XCTAssertEqual(mailToolDefinitions.count, 9)
        XCTAssertEqual(Set(mailToolSpecs.map(\.name)).count, 9)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: mailToolDefinitions))
        XCTAssertEqual(try mailCLIArguments(tool: "mail_list_mailboxes", input: [:]), ["mail", "mailboxes"])
    }
}
