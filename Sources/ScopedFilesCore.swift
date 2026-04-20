import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

struct ScopedFilesError: Error {
    let message: String
    let details: [String: Any]

    init(_ message: String, details: [String: Any] = [:]) {
        self.message = message
        self.details = details
    }

    func jsonObject() -> [String: Any] {
        var object = details
        object["error"] = message
        return object
    }
}

struct ScopedReadResult {
    let pathName: String
    let path: String
    let absolutePath: String
    let content: String

    func jsonObject() -> [String: Any] {
        [
            "path_name": pathName,
            "path": path,
            "absolute_path": absolutePath,
            "content": content,
        ]
    }
}

struct ScopedWriteRequest {
    let pathName: String
    let path: String
    let content: String
    let mode: String
    let sectionAnchor: String?
    let sectionHeading: String?
    let operationId: String?
    let actor: String?
    let metadata: Any?
}

struct ScopedWriteResult {
    let pathName: String
    let writtenPath: String
    let absolutePath: String
    let sha256: String
    let timestamp: String

    func jsonObject() -> [String: Any] {
        [
            "path_name": pathName,
            "written_path": writtenPath,
            "absolute_path": absolutePath,
            "sha256": sha256,
            "timestamp": timestamp,
        ]
    }
}

enum ScopedWriteMode: String {
    case upsert = "upsert"
    case appendSection = "append-section"
    case supersede = "supersede"
}

func serializeJSONObject(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let json = String(data: data, encoding: .utf8) else {
        return "{\"error\":\"Serialization failed\"}"
    }
    return json
}

func loadAllowedPaths(from environment: [String: String]) -> [String: String] {
    guard let raw = environment["ALLOWED_PATHS_JSON"], let data = raw.data(using: .utf8) else {
        return [:]
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }

    var paths: [String: String] = [:]
    for (name, value) in object {
        guard let path = value as? String else { continue }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            paths[trimmedName] = path
        }
    }
    return paths
}

/// Resolve a relative path against a root and verify it doesn't escape.
/// Existing path components have symlinks resolved so symlinks inside the
/// allowed root can be followed without allowing escapes outside the root.
func resolveScopedPath(root: String, relative: String) -> String? {
    guard !relative.isEmpty, !relative.hasPrefix("/") else { return nil }

    let fm = FileManager.default
    let expandedRoot = (root as NSString).expandingTildeInPath
    let resolvedRoot = URL(fileURLWithPath: expandedRoot).resolvingSymlinksInPath().standardizedFileURL.path
    let components = (relative as NSString).pathComponents.filter {
        !$0.isEmpty && $0 != "/" && $0 != "."
    }

    if components.contains("..") { return nil }

    var currentPath = resolvedRoot
    for component in components {
        let nextPath = (currentPath as NSString).appendingPathComponent(component)
        let resolvedNext: String
        if fm.fileExists(atPath: nextPath) {
            resolvedNext = URL(fileURLWithPath: nextPath).resolvingSymlinksInPath().standardizedFileURL.path
        } else {
            resolvedNext = URL(fileURLWithPath: nextPath).standardizedFileURL.path
        }

        guard resolvedNext == resolvedRoot || resolvedNext.hasPrefix(resolvedRoot + "/") else {
            return nil
        }
        currentPath = resolvedNext
    }

    return currentPath
}

private struct ManagedMarkdownSectionMatch {
    let range: NSRange
    let title: String
    let block: String
}

private func trimBoundaryNewlines(_ string: String) -> String {
    var trimmed = string
    while trimmed.hasPrefix("\n") || trimmed.hasPrefix("\r") { trimmed.removeFirst() }
    while trimmed.hasSuffix("\n") || trimmed.hasSuffix("\r") { trimmed.removeLast() }
    return trimmed
}

private func humanizeSectionAnchor(_ anchor: String) -> String {
    let words = anchor
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
    guard !words.isEmpty else { return anchor }
    return words.map { word in
        let lower = word.lowercased()
        return String(lower.prefix(1)).uppercased() + String(lower.dropFirst())
    }.joined(separator: " ")
}

private func slugifyHeading(_ heading: String) -> String {
    heading
        .lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: "-")
}

private func findManagedMarkdownSection(in content: String, anchor: String) -> ManagedMarkdownSectionMatch? {
    let nsContent = content as NSString
    let regex = try! NSRegularExpression(pattern: #"(?m)^##[ \t]+(.+?)\s*$"#)
    let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
    let normalizedAnchor = anchor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let marker = "<!-- macos-mcp:section_anchor=\(normalizedAnchor) -->"

    for (index, match) in matches.enumerated() {
        let start = match.range.location
        let end = index + 1 < matches.count ? matches[index + 1].range.location : nsContent.length
        let range = NSRange(location: start, length: end - start)
        let block = nsContent.substring(with: range)
        let title = nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)

        if block.contains(marker) || slugifyHeading(title) == normalizedAnchor {
            return ManagedMarkdownSectionMatch(range: range, title: title, block: block)
        }
    }

    return nil
}

private func findMarkdownSectionByTitle(in content: String, title: String) -> ManagedMarkdownSectionMatch? {
    let nsContent = content as NSString
    let regex = try! NSRegularExpression(pattern: #"(?m)^##[ \t]+(.+?)\s*$"#)
    let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    for (index, match) in matches.enumerated() {
        let start = match.range.location
        let end = index + 1 < matches.count ? matches[index + 1].range.location : nsContent.length
        let range = NSRange(location: start, length: end - start)
        let headingTitle = nsContent.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        if headingTitle.lowercased() == normalizedTitle {
            return ManagedMarkdownSectionMatch(range: range, title: headingTitle, block: nsContent.substring(with: range))
        }
    }

    return nil
}

private func isManagedMarkdownMetaComment(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<!-- macos-mcp:")
}

private func managedMarkdownSectionBody(_ block: String) -> String {
    var lines = block.components(separatedBy: .newlines)

    if let first = lines.first,
       first.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("## ") {
        lines.removeFirst()
    }

    while let first = lines.first,
          first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        lines.removeFirst()
    }

    while let first = lines.first, isManagedMarkdownMetaComment(first) {
        lines.removeFirst()
        while let next = lines.first,
              next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeFirst()
        }
    }

    return trimBoundaryNewlines(lines.joined(separator: "\n"))
}

private func sanitizeManagedMarkdownCommentValue(_ value: String) -> String {
    value.replacingOccurrences(of: "--", with: "—").replacingOccurrences(of: ">", with: "›")
}

private func renderManagedMarkdownSection(anchor: String, heading: String, body: String) -> String {
    let normalizedAnchor = anchor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedBody = trimBoundaryNewlines(body)
    var lines = ["## \(heading)", "<!-- macos-mcp:section_anchor=\(normalizedAnchor) -->"]

    if !normalizedBody.isEmpty {
        lines.append("")
        lines.append(normalizedBody)
    }

    return lines.joined(separator: "\n") + "\n"
}

private func renderSupersededEntry(
    title: String,
    anchor: String,
    body: String,
    operationId: String?,
    actor: String?,
    timestamp: String
) -> String {
    let normalizedAnchor = anchor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedBody = trimBoundaryNewlines(body)
    var lines = [
        "### \(title)",
        "<!-- macos-mcp:superseded_from=\(normalizedAnchor) -->",
        "<!-- macos-mcp:superseded_at=\(sanitizeManagedMarkdownCommentValue(timestamp)) -->",
    ]

    if let operationId = operationId, !operationId.isEmpty {
        lines.append("<!-- macos-mcp:operation_id=\(sanitizeManagedMarkdownCommentValue(operationId)) -->")
    }
    if let actor = actor, !actor.isEmpty {
        lines.append("<!-- macos-mcp:actor=\(sanitizeManagedMarkdownCommentValue(actor)) -->")
    }
    if !normalizedBody.isEmpty {
        lines.append("")
        lines.append(normalizedBody)
    }

    return lines.joined(separator: "\n") + "\n"
}

private func appendMarkdownBlock(_ existing: String, block: String) -> String {
    let trimmedExisting = existing.trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
    if trimmedExisting.isEmpty { return block }
    return trimmedExisting + "\n\n" + block
}

private func upsertSupersededSection(content: String, entry: String) -> String {
    if let superseded = findMarkdownSectionByTitle(in: content, title: "Superseded") {
        let updatedBlock = appendMarkdownBlock(superseded.block, block: entry)
        return (content as NSString).replacingCharacters(in: superseded.range, with: updatedBlock)
    }

    let newSupersededSection = "## Superseded\n\n" + entry
    return appendMarkdownBlock(content, block: newSupersededSection)
}

private func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
    (value >> amount) | (value << (32 - amount))
}

func sha256Hex(_ data: Data) -> String {
    #if canImport(CryptoKit)
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
    #elseif canImport(CommonCrypto)
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { bytes in
        _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
    #else
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    var h: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    var message = Array(data)
    let bitLength = UInt64(message.count) * 8
    message.append(0x80)
    while (message.count % 64) != 56 {
        message.append(0)
    }
    message.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))

    for chunkStart in stride(from: 0, to: message.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)

        for i in 0..<16 {
            let j = chunkStart + (i * 4)
            w[i] = (UInt32(message[j]) << 24)
                | (UInt32(message[j + 1]) << 16)
                | (UInt32(message[j + 2]) << 8)
                | UInt32(message[j + 3])
        }

        for i in 16..<64 {
            let s0 = rotateRight(w[i - 15], by: 7) ^ rotateRight(w[i - 15], by: 18) ^ (w[i - 15] >> 3)
            let s1 = rotateRight(w[i - 2], by: 17) ^ rotateRight(w[i - 2], by: 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]

        for i in 0..<64 {
            let s1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
            let ch = (e & f) ^ ((~e) & g)
            let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj

            hh = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }

        h[0] = h[0] &+ a
        h[1] = h[1] &+ b
        h[2] = h[2] &+ c
        h[3] = h[3] &+ d
        h[4] = h[4] &+ e
        h[5] = h[5] &+ f
        h[6] = h[6] &+ g
        h[7] = h[7] &+ hh
    }

    return h.map { String(format: "%08x", $0) }.joined()
    #endif
}

private func rotateFileIfNeeded(at path: String, maxBytes: UInt64 = 5_000_000, keep: Int = 5) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return }
    let attrs = try fm.attributesOfItem(atPath: path)
    let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    guard size >= maxBytes else { return }

    if keep <= 0 {
        try fm.removeItem(atPath: path)
        return
    }

    for i in stride(from: keep - 1, through: 1, by: -1) {
        let src = "\(path).\(i)"
        let dst = "\(path).\(i + 1)"
        if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
        if fm.fileExists(atPath: src) { try fm.moveItem(atPath: src, toPath: dst) }
    }

    let first = "\(path).1"
    if fm.fileExists(atPath: first) { try? fm.removeItem(atPath: first) }
    try fm.moveItem(atPath: path, toPath: first)
}

final class ScopedFilesService {
    let allowedPaths: [String: String]
    let auditLogPath: String
    private let now: () -> Date
    private let isoFormatter = ISO8601DateFormatter()

    init(allowedPaths: [String: String], auditLogPath: String, now: @escaping () -> Date = Date.init) {
        self.allowedPaths = allowedPaths
        self.auditLogPath = auditLogPath
        self.now = now
    }

    func read(pathName: String, path: String) throws -> ScopedReadResult {
        let normalizedPathName = pathName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPathName.isEmpty else {
            throw ScopedFilesError("path_name is required")
        }

        guard let allowedRoot = allowedPaths[normalizedPathName] else {
            throw ScopedFilesError(
                "Unknown path_name: \(normalizedPathName)",
                details: ["available_path_names": allowedPaths.keys.sorted()]
            )
        }

        let relativePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relativePath.isEmpty else {
            throw ScopedFilesError("path is required")
        }
        guard let fullPath = resolveScopedPath(root: allowedRoot, relative: relativePath) else {
            throw ScopedFilesError("Invalid path")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ScopedFilesError("File not found: \(relativePath)")
        }
        guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
            throw ScopedFilesError("Could not read file as UTF-8: \(relativePath)")
        }

        return ScopedReadResult(
            pathName: normalizedPathName,
            path: relativePath,
            absolutePath: fullPath,
            content: content
        )
    }

    func write(_ request: ScopedWriteRequest) throws -> ScopedWriteResult {
        let normalizedPathName = request.pathName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPathName.isEmpty else {
            throw ScopedFilesError("path_name is required")
        }

        guard let allowedRoot = allowedPaths[normalizedPathName] else {
            throw ScopedFilesError(
                "Unknown path_name: \(normalizedPathName)",
                details: ["available_path_names": allowedPaths.keys.sorted()]
            )
        }

        let relativePath = request.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relativePath.isEmpty else {
            throw ScopedFilesError("path is required")
        }
        guard let fullPath = resolveScopedPath(root: allowedRoot, relative: relativePath) else {
            throw ScopedFilesError("Invalid path")
        }

        guard let mode = ScopedWriteMode(rawValue: request.mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw ScopedFilesError("Invalid mode: \(request.mode). Use upsert, append-section, or supersede.")
        }

        let normalizedAnchor = request.sectionAnchor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHeading = request.sectionHeading?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOperationId = request.operationId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedActor = request.actor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = isoFormatter.string(from: now())
        let existingContent = try? String(contentsOfFile: fullPath, encoding: .utf8)

        let finalContent: String
        let resolvedHeading: String?

        switch mode {
        case .upsert:
            finalContent = request.content
            resolvedHeading = nil

        case .appendSection:
            guard let anchor = normalizedAnchor, !anchor.isEmpty else {
                throw ScopedFilesError("section_anchor is required for append-section")
            }
            if let existingContent = existingContent,
               findManagedMarkdownSection(in: existingContent, anchor: anchor) != nil {
                throw ScopedFilesError("Section already exists: \(anchor)")
            }

            let heading = (normalizedHeading?.isEmpty == false ? normalizedHeading! : humanizeSectionAnchor(anchor))
            finalContent = appendMarkdownBlock(
                existingContent ?? "",
                block: renderManagedMarkdownSection(anchor: anchor, heading: heading, body: request.content)
            )
            resolvedHeading = heading

        case .supersede:
            guard let anchor = normalizedAnchor, !anchor.isEmpty else {
                throw ScopedFilesError("section_anchor is required for supersede")
            }
            guard let existingContent = existingContent else {
                throw ScopedFilesError("File not found: \(relativePath)")
            }
            guard let section = findManagedMarkdownSection(in: existingContent, anchor: anchor) else {
                throw ScopedFilesError("Section not found: \(anchor)")
            }

            let heading = !section.title.isEmpty
                ? section.title
                : (normalizedHeading?.isEmpty == false ? normalizedHeading! : humanizeSectionAnchor(anchor))
            let updatedContent = (existingContent as NSString).replacingCharacters(
                in: section.range,
                with: renderManagedMarkdownSection(anchor: anchor, heading: heading, body: request.content)
            )
            let supersededEntry = renderSupersededEntry(
                title: heading,
                anchor: anchor,
                body: managedMarkdownSectionBody(section.block),
                operationId: normalizedOperationId,
                actor: normalizedActor,
                timestamp: timestamp
            )
            finalContent = upsertSupersededSection(content: updatedContent, entry: supersededEntry)
            resolvedHeading = heading
        }

        let dir = (fullPath as NSString).deletingLastPathComponent
        let fm = FileManager.default

        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try finalContent.write(toFile: fullPath, atomically: true, encoding: .utf8)
        } catch {
            throw ScopedFilesError("Write failed: \(error.localizedDescription)")
        }

        let data = finalContent.data(using: .utf8) ?? Data()
        let sha = sha256Hex(data)

        var auditEntry: [String: Any] = [
            "ts": timestamp,
            "action": "scoped_write",
            "path_name": normalizedPathName,
            "path": relativePath,
            "absolute_path": fullPath,
            "mode": mode.rawValue,
            "sha256": sha,
            "bytes": data.count,
        ]
        if let anchor = normalizedAnchor, !anchor.isEmpty { auditEntry["section_anchor"] = anchor }
        if let heading = resolvedHeading, !heading.isEmpty { auditEntry["section_heading"] = heading }
        if let operationId = normalizedOperationId, !operationId.isEmpty { auditEntry["operation_id"] = operationId }
        if let actor = normalizedActor, !actor.isEmpty { auditEntry["actor"] = actor }
        if let metadata = request.metadata,
           JSONSerialization.isValidJSONObject(["metadata": metadata]) {
            auditEntry["metadata"] = metadata
        }

        do {
            try appendAuditLog(auditEntry)
        } catch {
            throw ScopedFilesError(
                "Audit logging failed after write: \(error.localizedDescription)",
                details: [
                    "path_name": normalizedPathName,
                    "written_path": relativePath,
                    "sha256": sha,
                    "absolute_path": fullPath,
                    "timestamp": timestamp,
                ]
            )
        }

        return ScopedWriteResult(
            pathName: normalizedPathName,
            writtenPath: relativePath,
            absolutePath: fullPath,
            sha256: sha,
            timestamp: timestamp
        )
    }

    private func appendAuditLog(_ entry: [String: Any]) throws {
        let path = (auditLogPath as NSString).expandingTildeInPath
        let dir = (path as NSString).deletingLastPathComponent
        let fm = FileManager.default

        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try rotateFileIfNeeded(at: path)

        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }

        let line = serializeJSONObject(entry) + "\n"
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
    }
}
