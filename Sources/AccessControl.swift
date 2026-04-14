import Foundation

// MARK: - Access Control

/// Controls which senders and group chats can trigger channel notifications.
/// Loads from MACOS_MCP_OWNER_PHONE env var + optional JSON config file.
///
/// Config file format (~/.config/macos-mcp/access.json):
/// {
///   "allowFrom": ["+15551234567", "+15559876543"],
///   "groups": ["iMessage;+;chat123456"]
/// }
struct AccessConfig {
    let allowFrom: Set<String>
    let allowedGroups: Set<String>
    let isEmpty: Bool

    static func load() -> AccessConfig {
        let ownerPhone = ProcessInfo.processInfo.environment["MACOS_MCP_OWNER_PHONE"] ?? ""
        let configPath = ProcessInfo.processInfo.environment["MACOS_MCP_ACCESS_FILE"]
            ?? NSHomeDirectory() + "/.config/macos-mcp/access.json"

        var allowFrom = Set<String>()
        var allowedGroups = Set<String>()

        if !ownerPhone.isEmpty {
            allowFrom.insert(normalizePhone(ownerPhone))
        }

        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let phones = json["allowFrom"] as? [String] {
                for phone in phones {
                    let normalized = normalizePhone(phone)
                    if !normalized.isEmpty { allowFrom.insert(normalized) }
                }
            }
            if let groups = json["groups"] as? [String] {
                for g in groups where !g.isEmpty {
                    allowedGroups.insert(g)
                }
            }
        }

        return AccessConfig(
            allowFrom: allowFrom,
            allowedGroups: allowedGroups,
            isEmpty: allowFrom.isEmpty && allowedGroups.isEmpty
        )
    }

    /// Check whether a message should be delivered based on sender and chat.
    func isAllowed(from handle: String, chatGuid: String) -> Bool {
        if isEmpty { return false }

        // Group chats use ";+;" in their GUID (DMs use ";-;")
        if chatGuid.contains(";+;") {
            return allowedGroups.contains(chatGuid)
        }

        // DM: check sender against allowlist
        return allowFrom.contains(AccessConfig.normalizePhone(handle))
    }

    /// Normalize a phone number to E.164 format for consistent matching.
    static func normalizePhone(_ phone: String) -> String {
        let stripped = phone.filter { $0.isNumber || $0 == "+" }
        if stripped.hasPrefix("+") { return stripped }
        let digits = stripped.filter { $0.isNumber }
        if digits.count == 11 && digits.hasPrefix("1") { return "+" + digits }
        if digits.count == 10 { return "+1" + digits }
        // Email handles or other identifiers
        return phone.lowercased()
    }
}

// MARK: - Echo Suppression

/// Tracks recently sent messages to suppress self-chat echoes.
/// When Claude sends a message, its text is recorded. If a matching inbound
/// message appears within 15 seconds, it's treated as an echo and suppressed.
/// Thread-safe via NSLock.
class EchoTracker {
    private var recentSends: [(text: String, timestamp: Date)] = []
    private let ttl: TimeInterval = 15
    private let lock = NSLock()

    func trackSend(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        recentSends.append((text: normalize(text), timestamp: Date()))
        purge()
    }

    func isEcho(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        purge()
        let normalized = normalize(text)
        if let idx = recentSends.firstIndex(where: { $0.text == normalized }) {
            recentSends.remove(at: idx)
            return true
        }
        return false
    }

    private func normalize(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Collapse whitespace
        while t.contains("  ") {
            t = t.replacingOccurrences(of: "  ", with: " ")
        }
        // Cap for matching
        if t.count > 120 { t = String(t.prefix(120)) }
        return t.lowercased()
    }

    private func purge() {
        let cutoff = Date().addingTimeInterval(-ttl)
        recentSends.removeAll { $0.timestamp < cutoff }
    }
}
