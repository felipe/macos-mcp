import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Who may reach `serve`, on which addresses.
///
/// Loopback listeners serve local callers without a token, as they always have.
/// Any other address (a tailnet IP, a LAN IP, 0.0.0.0) is opt-in: it has to be
/// named with `--host`, and `serve` refuses to start unless a bearer token is
/// configured. The token comes from a file or the environment, never argv,
/// because argv is readable by every process on the Mac.
struct ServeAccess {
    static let minimumTokenLength = 32

    enum TokenError: Error, CustomStringConvertible {
        case unreadable(String)
        case exposed(String)
        case hasACL(String)
        case tooShort(Int)

        var description: String {
            switch self {
            case .unreadable(let path): return "Token file \(path) could not be read"
            case .exposed(let path): return "Token file \(path) is readable by other users; chmod 600 it"
            case .hasACL(let path): return "Token file \(path) has an ACL that can grant other users access; chmod -N it"
            case .tooShort(let length): return "Token is \(length) characters; use at least \(ServeAccess.minimumTokenLength) (openssl rand -hex 32)"
            }
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "localhost" || h == "::1" || h.hasPrefix("127.")
    }

    /// Token from `--mcp-token-file`, then MACOS_MCP_TOKEN_FILE, then MACOS_MCP_TOKEN.
    /// Returns nil when none is configured.
    static func loadToken(tokenFile: String?, environment: [String: String]) throws -> String? {
        if let path = tokenFile ?? environment["MACOS_MCP_TOKEN_FILE"] {
            let expanded = (path as NSString).expandingTildeInPath
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: expanded),
                  let data = FileManager.default.contents(atPath: expanded),
                  let text = String(data: data, encoding: .utf8) else {
                throw TokenError.unreadable(expanded)
            }
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            if mode & 0o077 != 0 { throw TokenError.exposed(expanded) }
            if hasExtendedACL(expanded) { throw TokenError.hasACL(expanded) }
            return try validated(text)
        }
        if let value = environment["MACOS_MCP_TOKEN"] {
            return try validated(value)
        }
        return nil
    }

    /// macOS ACLs can grant read access that the mode bits do not show.
    static func hasExtendedACL(_ path: String) -> Bool {
        #if canImport(Darwin)
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
        #else
        return false
        #endif
    }

    static func validated(_ raw: String) throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= minimumTokenLength else { throw TokenError.tooShort(token.count) }
        return token
    }

    /// Non-nil = reason `serve` must not start with these hosts.
    static func startupError(hosts: [String], token: String?) -> String? {
        let remote = hosts.filter { !isLoopback($0) }
        guard !remote.isEmpty, token == nil else { return nil }
        return "Refusing to listen on \(remote.joined(separator: ", ")) without a token. "
            + "Set --mcp-token-file, MACOS_MCP_TOKEN_FILE or MACOS_MCP_TOKEN, or bind loopback only."
    }

    /// Constant-time check of an `Authorization: Bearer <token>` header.
    static func authorized(header: String?, token: String) -> Bool {
        let presented = Array((header ?? "").utf8)
        let expected = Array("Bearer \(token)".utf8)
        guard presented.count == expected.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<expected.count { difference |= presented[i] ^ expected[i] }
        return difference == 0
    }
}
