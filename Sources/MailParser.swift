import Foundation

/// The decoded, locally cached portions of an RFC 822 message.
public struct MailParsedMessage: Sendable {
    public let headers: [String: String]
    public let body: String
    public let html: String?
    public let attachments: [MailAttachment]

    public init(headers: [String: String], body: String, html: String?, attachments: [MailAttachment]) {
        self.headers = headers
        self.body = body
        self.html = html
        self.attachments = attachments
    }
}

public struct MailAttachment: Sendable, Equatable {
    public let filename: String?
    public let contentType: String
    public let size: Int

    public init(filename: String?, contentType: String, size: Int) {
        self.filename = filename
        self.contentType = contentType
        self.size = size
    }
}

public enum MailParserError: LocalizedError {
    case malformed(String)
    case oversized(Int)

    public var errorDescription: String? {
        switch self {
        case .malformed(let detail): return "Malformed mail message: \(detail)"
        case .oversized(let bytes): return "Mail message exceeds the \(bytes)-byte parsing limit"
        }
    }
}

public enum MailParser {
    /// Caps input before decoding, so a corrupt `.emlx` length cannot make a caller parse arbitrary data.
    public static let maximumMessageBytes = 50 * 1024 * 1024
    private static let maximumMultipartDepth = 32
    private static let maximumMIMEParts = 10_000

    public static func parse(_ data: Data, includeHTML: Bool = false) throws -> MailParsedMessage {
        let message = try emlxPayload(from: data)
        let root = try parsePart(message)
        var leaves: [Leaf] = []
        var partCount = 0
        try collectLeaves(root, depth: 0, partCount: &partCount, into: &leaves)

        let plain = leaves.first(where: { $0.contentType.lowercased() == "text/plain" && !$0.attachment })?.text
        let htmlLeaf = leaves.first(where: { $0.contentType.lowercased() == "text/html" && !$0.attachment })
        let body = plain ?? htmlLeaf.map { stripHTML($0.text) } ?? ""
        let attachments = leaves.compactMap { leaf -> MailAttachment? in
            guard leaf.attachment else { return nil }
            return MailAttachment(filename: leaf.filename, contentType: leaf.contentType, size: leaf.bytes.count)
        }
        return MailParsedMessage(headers: root.headers, body: body, html: includeHTML ? htmlLeaf?.text : nil, attachments: attachments)
    }

    private static func emlxPayload(from input: Data) throws -> Data {
        guard input.count <= maximumMessageBytes + 128 else { throw MailParserError.oversized(maximumMessageBytes) }
        guard let lineEnd = input.firstIndex(of: 10), lineEnd <= 64 else {
            throw MailParserError.malformed("missing bounded .emlx byte prefix")
        }
        var line = Data(input.prefix(upTo: lineEnd))
        if line.last == 13 { line.removeLast() }
        guard let rawCount = String(data: line, encoding: .ascii) else {
            throw MailParserError.malformed("invalid .emlx byte prefix")
        }
        let text = rawCount.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber }), let count = Int(text) else {
            throw MailParserError.malformed("invalid .emlx byte prefix")
        }
        guard count <= maximumMessageBytes else { throw MailParserError.oversized(maximumMessageBytes) }
        let start = input.index(after: lineEnd)
        guard input.distance(from: start, to: input.endIndex) >= count else {
            throw MailParserError.malformed("byte prefix exceeds available data")
        }
        return input.subdata(in: start..<(start + count))
    }

    private struct Part {
        let headers: [String: String]
        let body: Data
    }
    private struct Leaf {
        let contentType: String
        let text: String
        let bytes: Data
        let attachment: Bool
        let filename: String?
    }

    private static func parsePart(_ data: Data) throws -> Part {
        let separator: Range<Data.Index>?
        if let range = data.range(of: Data("\r\n\r\n".utf8)) { separator = range }
        else { separator = data.range(of: Data("\n\n".utf8)) }
        guard let separator else { throw MailParserError.malformed("headers are not terminated") }
        let headerData = data.subdata(in: data.startIndex..<separator.lowerBound)
        // Most contemporary messages use UTF-8 headers, but RFC 822 permits
        // arbitrary 8-bit data. ISO-8859-1 provides a lossless fallback.
        let headerText = String(data: headerData, encoding: .utf8) ?? latin1String(headerData)
        let body = data.subdata(in: separator.upperBound..<data.endIndex)
        return Part(headers: headers(from: headerText), body: body)
    }

    private static func collectLeaves(_ part: Part, depth: Int, partCount: inout Int, into leaves: inout [Leaf]) throws {
        guard depth <= maximumMultipartDepth else { throw MailParserError.malformed("MIME nesting exceeds the limit") }
        partCount += 1
        guard partCount <= maximumMIMEParts else { throw MailParserError.malformed("MIME part count exceeds the limit") }
        let typeValue = header("Content-Type", in: part.headers) ?? "text/plain"
        let type = mediaType(typeValue)
        if type.hasPrefix("multipart/"), let boundary = parameter("boundary", in: typeValue), !boundary.isEmpty {
            let children = multipartBodies(part.body, boundary: boundary)
            guard !children.isEmpty else { throw MailParserError.malformed("multipart body has no parts for its boundary") }
            for child in children { try collectLeaves(parsePart(child), depth: depth + 1, partCount: &partCount, into: &leaves) }
            return
        }
        let disposition = header("Content-Disposition", in: part.headers) ?? ""
        let name = parameter("filename", in: disposition) ?? parameter("name", in: typeValue)
        let attachment = disposition.lowercased().hasPrefix("attachment") || name != nil
        let decoded = decodeTransfer(part.body, header("Content-Transfer-Encoding", in: part.headers))
        let charset = parameter("charset", in: typeValue)
        let text = decodeText(decoded, charset: charset)
        leaves.append(Leaf(contentType: type, text: text, bytes: decoded, attachment: attachment, filename: name.map(decodeHeader)))
    }

    private static func headers(from raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(line)
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let key = current {
                result[key, default: ""] += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).lowercased()
                current = key
                result[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return result.mapValues(decodeHeader)
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func mediaType(_ value: String) -> String {
        value.split(separator: ";", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? "text/plain"
    }

    private static func parameter(_ name: String, in value: String) -> String? {
        // This deliberately handles quoted semicolons, which occur often in filenames.
        let pieces = splitParameters(value)
        for piece in pieces.dropFirst() {
            guard let equal = piece.firstIndex(of: "=") else { continue }
            let key = piece[..<equal].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == name.lowercased() else { continue }
            var result = String(piece[piece.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
            if result.hasPrefix("\"") && result.hasSuffix("\"") && result.count >= 2 { result.removeFirst(); result.removeLast() }
            return result
        }
        return nil
    }

    private static func splitParameters(_ value: String) -> [String] {
        var values: [String] = []; var current = ""; var quoted = false
        for char in value {
            if char == "\"" { quoted.toggle() }
            if char == ";" && !quoted { values.append(current); current = "" } else { current.append(char) }
        }
        values.append(current); return values
    }

    private static func multipartBodies(_ data: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        let closingDelimiter = Data("--\(boundary)--".utf8)
        var bodies: [Data] = []; var current = Data(); var active = false
        for rawLine in data.split(separator: 10, omittingEmptySubsequences: false) {
            let line = rawLine.last == 13 ? rawLine.dropLast() : rawLine
            if Data(line) == delimiter || Data(line) == closingDelimiter {
                if active {
                    // The line break immediately before a MIME boundary belongs
                    // to the delimiter, rather than the encapsulated body.
                    if current.last == 10 { current.removeLast() }
                    if current.last == 13 { current.removeLast() }
                    bodies.append(current)
                }
                current = Data(); active = Data(line) == delimiter
            } else if active {
                current.append(contentsOf: rawLine)
                current.append(10)
            }
        }
        return bodies
    }

    private static func decodeTransfer(_ data: Data, _ encoding: String?) -> Data {
        switch encoding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "base64": return Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable": return decodeQuotedPrintable(data)
        default: return data
        }
    }

    private static func latin1String(_ data: Data) -> String {
        String(String.UnicodeScalarView(data.map { UnicodeScalar(UInt32($0))! }))
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data); var output: [UInt8] = []; var index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte { case 48...57: return byte - 48; case 65...70: return byte - 55; case 97...102: return byte - 87; default: return nil }
        }
        while index < bytes.count {
            if bytes[index] == 61 {
                if index + 1 < bytes.count && bytes[index + 1] == 10 { index += 2; continue }
                if index + 2 < bytes.count && bytes[index + 1] == 13 && bytes[index + 2] == 10 { index += 3; continue }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) { output.append(high * 16 + low); index += 3; continue }
            }
            output.append(bytes[index]); index += 1
        }
        return Data(output)
    }

    private static func decodeText(_ data: Data, charset: String?) -> String {
        let normalized = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        let encoding: String.Encoding?
        switch normalized {
        case nil, "utf-8", "utf8": encoding = .utf8
        case "us-ascii", "ascii": encoding = .ascii
        case "iso-8859-1", "latin1", "latin-1": return latin1String(data)
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "utf-16": encoding = .utf16
        case "utf-16le": encoding = .utf16LittleEndian
        case "utf-16be": encoding = .utf16BigEndian
        default: encoding = nil
        }
        return encoding.flatMap { String(data: data, encoding: $0) } ?? String(data: data, encoding: .utf8) ?? latin1String(data)
    }

    private static func decodeHeader(_ value: String) -> String {
        // RFC 2047 encoded words; malformed words remain readable as their source text.
        let pattern = "=\\?([^?[:space:]]+)\\?([bBqQ])\\?([^?]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let normalized = value.replacingOccurrences(of: "\\?=\\s+=\\?", with: "?==?", options: .regularExpression)
        let range = NSRange(normalized.startIndex..., in: normalized)
        var result = normalized
        for match in regex.matches(in: normalized, range: range).reversed() {
            guard let charsetRange = Range(match.range(at: 1), in: normalized), let modeRange = Range(match.range(at: 2), in: normalized), let contentRange = Range(match.range(at: 3), in: normalized), let fullRange = Range(match.range, in: normalized) else { continue }
            let content = String(normalized[contentRange]); let bytes: Data
            if normalized[modeRange].lowercased() == "b" { bytes = Data(base64Encoded: content) ?? Data(content.utf8) }
            else { bytes = decodeQuotedPrintable(Data(content.replacingOccurrences(of: "_", with: " ").utf8)) }
            result.replaceSubrange(fullRange, with: decodeText(bytes, charset: String(normalized[charsetRange])))
        }
        return result
    }

    private static func stripHTML(_ value: String) -> String {
        let withoutTags = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return withoutTags.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
