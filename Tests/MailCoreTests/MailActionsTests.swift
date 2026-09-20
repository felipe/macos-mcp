import XCTest
@testable import MailCore

final class MailActionsTests: XCTestCase {
    private let scoped = ["message_id": "<id@example.test>", "mailbox": "Inbox", "account": "me@example.test"]

    func testScriptEscapesInjectionAndPreservesNewlines() throws {
        let script = try MailActions.buildScript(action: "send", arguments: [
            "to": "person@example.test",
            "subject": "x\" & send newMessage & \"y",
            "body": "first\nsecond"
        ])
        XCTAssertTrue(script.contains("x\\\" & send newMessage & \\\"y"))
        XCTAssertTrue(script.contains("\"first\" & return & \"second\""))
        XCTAssertFalse(script.contains("subject:\"x\" & send newMessage & \"y\""))
    }

    func testRecipientListsAndAttachmentsAreInjectedAsLiterals() throws {
        let script = try MailActions.buildScript(action: "draft", arguments: [
            "to": "a@example.test\nb@example.test",
            "cc": "c@example.test",
            "subject": "subject",
            "body": "body",
            "attachments": "/tmp/a.pdf\n/tmp/b.pdf"
        ])
        XCTAssertEqual(script.components(separatedBy: "make new to recipient").count - 1, 2)
        XCTAssertTrue(script.contains("make new cc recipient"))
        XCTAssertTrue(script.contains("POSIX file \"/tmp/a.pdf\""))
    }

    func testMessageActionsRequireRFCMessageIDAndMailboxScope() {
        XCTAssertThrowsError(try MailActions.buildScript(action: "reply", arguments: ["mailbox": "Inbox"])) { error in
            XCTAssertEqual(error as? MailActions.Error, .missingArgument("message_id"))
        }
        XCTAssertThrowsError(try MailActions.buildScript(action: "move", arguments: ["message_id": "<a@b>", "target_mailbox": "Archive"])) { error in
            XCTAssertEqual(error as? MailActions.Error, .missingMessageScope)
        }
    }

    func testMessageLookupUsesMessageIDAndRejectsAmbiguity() throws {
        let script = try MailActions.buildScript(action: "flag", arguments: scoped.merging(["flagged": "true"]) { _, new in new })
        XCTAssertTrue(script.contains("message id is normalizedMessageID or message id is originalMessageID"))
        XCTAssertTrue(script.contains("set originalMessageID to \"<id@example.test>\""))
        XCTAssertTrue(script.contains("set normalizedMessageID to \"id@example.test\""))
        XCTAssertTrue(script.contains("message_id is ambiguous"))
        XCTAssertFalse(script.contains("whose id is \"<id@example.test>\""))
    }

    func testMessageIDWithoutBracketsAlsoBuildsBothSafeLookupVariants() throws {
        let script = try MailActions.buildScript(action: "flag", arguments: [
            "message_id": "id@example.test", "mailbox": "Inbox", "flagged": "true"
        ])
        XCTAssertTrue(script.contains("set originalMessageID to \"<id@example.test>\""))
        XCTAssertTrue(script.contains("set normalizedMessageID to \"id@example.test\""))
        XCTAssertThrowsError(try MailActions.buildScript(action: "flag", arguments: [
            "message_id": "<id@example.test>\nBcc: injected", "mailbox": "Inbox", "flagged": "true"
        ]))
    }

    func testSendReportsQueuedRatherThanDelivered() throws {
        let result = try MailActions.perform("send", arguments: ["to": "person@example.test", "subject": "Hi", "body": "Hello"], runner: { _, _ in .init(stdout: "queued") })
        XCTAssertEqual(result["status"] as? String, "queued")
        XCTAssertEqual(result["delivered"] as? Bool, false)
    }

    func testTimeoutReturnsUnknownResultWithoutRetry() {
        var calls = 0
        XCTAssertThrowsError(try MailActions.perform("forward", arguments: scoped.merging(["to": "person@example.test"]) { _, new in new }, runner: { _, _ in
            calls += 1
            return .init(stderr: "timed out", exitCode: 1, timedOut: true)
        })) { error in
            guard case MailActions.Error.unknownResult = error else { return XCTFail("expected unknown result, got \(error)") }
        }
        XCTAssertEqual(calls, 1)
    }

    func testUnexpectedSendResultIsUnknownAndNeverReportedQueued() {
        XCTAssertThrowsError(try MailActions.perform("send", arguments: ["to": "person@example.test", "subject": "Hi", "body": "Hello"], runner: { _, _ in
            .init(stdout: "false")
        })) { error in
            guard case MailActions.Error.unknownResult = error else { return XCTFail("expected unknown result, got \(error)") }
        }
    }

    func testMalformedSuccessTokenIsUnknown() {
        XCTAssertThrowsError(try MailActions.perform("draft", arguments: ["subject": "Hi", "body": "Hello"], runner: { _, _ in
            .init(stdout: "draft_saved extra")
        })) { error in
            guard case MailActions.Error.unknownResult = error else { return XCTFail("expected unknown result, got \(error)") }
        }
    }

    func testAccountIDAndSenderEmailUseDistinctSafeSelectors() throws {
        let sourceScript = try MailActions.buildScript(action: "flag", arguments: [
            "message_id": "<id@example.test>", "mailbox": "Inbox/Projects", "account_id": "opaque-account-id", "flagged": "true"
        ])
        XCTAssertTrue(sourceScript.contains("every account whose id is \"opaque-account-id\""))
        XCTAssertTrue(sourceScript.contains("provide explicit account email instead"))
        XCTAssertTrue(sourceScript.contains("every mailbox of currentMailbox whose name is \"Projects\""))

        let sendScript = try MailActions.buildScript(action: "send", arguments: [
            "to": "person@example.test", "subject": "Hi", "body": "Hello", "account": "me@example.test"
        ])
        XCTAssertTrue(sendScript.contains("email addresses contains \"me@example.test\""))
        XCTAssertTrue(sendScript.contains("set sender of newMessage to \"me@example.test\""))
    }

    func testMoveDefaultsDestinationToSourceAccountID() throws {
        let script = try MailActions.buildScript(action: "move", arguments: [
            "message_id": "<id@example.test>", "mailbox": "Inbox", "account_id": "opaque-account-id", "target_mailbox": "Archive"
        ])
        XCTAssertEqual(script.components(separatedBy: "every account whose id is \"opaque-account-id\"").count - 1, 2)
    }

    func testInvalidActionAndBooleanAreRejected() {
        XCTAssertThrowsError(try MailActions.buildScript(action: "delete", arguments: [:]))
        XCTAssertThrowsError(try MailActions.buildScript(action: "flag", arguments: scoped.merging(["flagged": "perhaps"]) { _, new in new }))
        XCTAssertThrowsError(try MailActions.buildScript(action: "reply", arguments: scoped.merging(["reply_all": "perhaps"]) { _, new in new }))
    }
}
