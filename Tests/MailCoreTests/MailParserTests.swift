import Foundation
import XCTest
@testable import MailCore

final class MailParserTests: XCTestCase {
    func testDecodesFoldedEncodedHeadersAndQuotedPrintablePlainText() throws {
        let raw = """
        From: =?UTF-8?Q?Jos=C3=A9?= <jose@example.com>
        Subject: =?UTF-8?B?SGVsbG8=?=
         =?UTF-8?B?IFdvcmxk?=
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Caf=C3=A9=0Asecond line
        """
        let message = try MailParser.parse(emlx(raw))
        XCTAssertEqual(message.headers["from"], "José <jose@example.com>")
        XCTAssertEqual(message.headers["subject"], "Hello World")
        XCTAssertEqual(message.body, "Café\nsecond line")
        XCTAssertNil(message.html)
        XCTAssertTrue(message.attachments.isEmpty)
    }

    func testNestedMultipartPrefersPlainTextAndReportsDecodedAttachmentMetadata() throws {
        let raw = """
        Subject: report
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary="inner"

        --inner
        Content-Type: text/html; charset=utf-8

        <p>HTML fallback</p>
        --inner
        Content-Type: text/plain; charset=utf-8

        Plain body
        --inner--
        --outer
        Content-Type: application/pdf; name="report; Sep.pdf"
        Content-Disposition: attachment; filename="=?UTF-8?Q?report=5FSept.pdf?="
        Content-Transfer-Encoding: base64

        AQIDBA==
        --outer--
        """
        let message = try MailParser.parse(emlx(raw), includeHTML: true)
        XCTAssertEqual(message.body, "Plain body")
        XCTAssertEqual(message.html, "<p>HTML fallback</p>")
        XCTAssertEqual(message.attachments, [MailAttachment(filename: "report_Sept.pdf", contentType: "application/pdf", size: 4)])
    }

    func testUsesHtmlAsTextFallbackWhenPlainPartIsAbsent() throws {
        let raw = """
        Content-Type: text/html; charset=windows-1252

        <h1>Price &amp; quality</h1>
        """
        let message = try MailParser.parse(emlx(raw))
        XCTAssertEqual(message.body, "Price & quality")
        XCTAssertNil(message.html)
    }

    func testAcceptsAppleMailPaddedEmlxBytePrefix() throws {
        let payload = Data("Subject: padded\n\nBody".utf8)
        let message = try MailParser.parse(Data("\(payload.count)      \n".utf8) + payload)
        XCTAssertEqual(message.headers["subject"], "padded")
        XCTAssertEqual(message.body, "Body")
    }

    func testPreservesRawUTF8BytesInsideMultipartBodies() throws {
        let raw = """
        Content-Type: multipart/alternative; boundary=part

        --part
        Content-Type: text/plain; charset=utf-8

        café
        --part--
        """
        let message = try MailParser.parse(emlx(raw))
        XCTAssertEqual(message.body, "café")
    }

    func testRejectsInvalidOrTruncatedEmlxPrefix() {
        XCTAssertThrowsError(try MailParser.parse(Data("not-a-length\nSubject: x".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("byte prefix"))
        }
        XCTAssertThrowsError(try MailParser.parse(Data("200\nSubject: x\n\nshort".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("exceeds available"))
        }
        XCTAssertThrowsError(try MailParser.parse(Data("\(MailParser.maximumMessageBytes + 1)\n".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("exceeds"))
        }
    }

    func testRejectsMultipartWithNoMatchingBoundary() {
        let raw = """
        Content-Type: multipart/mixed; boundary=missing

        This is not a MIME part.
        """
        XCTAssertThrowsError(try MailParser.parse(emlx(raw))) { error in
            XCTAssertTrue(error.localizedDescription.contains("no parts"))
        }
    }

    func testRejectsExcessiveMultipartNesting() {
        var raw = "Content-Type: multipart/mixed; boundary=b0\n\n"
        for index in 0...32 {
            raw += "--b\(index)\n"
            if index == 32 {
                raw += "Content-Type: text/plain\n\nleaf"
            } else {
                raw += "Content-Type: multipart/mixed; boundary=b\(index + 1)\n\n"
            }
        }
        for index in stride(from: 32, through: 0, by: -1) { raw += "\n--b\(index)--" }
        XCTAssertThrowsError(try MailParser.parse(emlx(raw))) { error in
            XCTAssertTrue(error.localizedDescription.contains("nesting exceeds"))
        }
    }

    private func emlx(_ rfc822: String) -> Data {
        let payload = Data(rfc822.utf8)
        return Data("\(payload.count)\n".utf8) + payload + Data("\n<plist/>".utf8)
    }
}
