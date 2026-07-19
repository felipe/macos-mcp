import Foundation

// MARK: - Access Control

/// Controls which senders and group chats the iMessage poller is allowed to
/// forward to the webhook. Loads from the `MACOS_MCP_OWNER_PHONE` env var plus
/// an optional JSON config file (`MACOS_MCP_ACCESS_FILE`, default
/// `~/.config/macos-mcp/access.json`):
///
///     {
///       "allowFrom": ["+15551234567", "+15559876543"],
///       "groups": ["chat646855985291785786"]
///     }
///
/// `groups` holds `chat_identifier` values as reported by the poller
/// (`PolledMessage.chat`), i.e. the numeric `chat<digits>` form — not the
/// legacy `service;+;guid` string.
///
/// When both sources are empty the config is considered unconfigured
/// (`isEmpty == true`); callers should leave the gate inactive in that case so
/// an operator opts into filtering explicitly rather than silently losing every
/// message.
struct AccessConfig {
    let allowFrom: Set<String>
    let allowedGroups: Set<String>
    let isEmpty: Bool

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) -> AccessConfig {
        let ownerPhone = environment["MACOS_MCP_OWNER_PHONE"] ?? ""
        let configPath = environment["MACOS_MCP_ACCESS_FILE"]
            ?? NSHomeDirectory() + "/.config/macos-mcp/access.json"

        var allowFrom = Set<String>()
        var allowedGroups = Set<String>()

        if !ownerPhone.isEmpty {
            allowFrom.insert(normalizePhone(ownerPhone))
        }

        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let phones = json["allowFrom"] as? [String] {
                for phone in phones {
                    let normalized = normalizePhone(phone)
                    if !normalized.isEmpty { allowFrom.insert(normalized) }
                }
            }
            if let groups = json["groups"] as? [String] {
                for g in groups where !g.isEmpty { allowedGroups.insert(g) }
            }
        }

        return AccessConfig(
            allowFrom: allowFrom,
            allowedGroups: allowedGroups,
            isEmpty: allowFrom.isEmpty && allowedGroups.isEmpty
        )
    }

    /// Whether an inbound message from `handle` in `chat` (a `chat_identifier`)
    /// is allowed. Group chats — whose identifier is the `chat<digits>` form —
    /// match against `allowedGroups`; everything else is treated as a direct
    /// message and matches the sender against `allowFrom`.
    ///
    /// Returns `false` for an empty (unconfigured) config, so a configured
    /// caller fails closed; the poller guards on `isEmpty` before calling to
    /// keep the unconfigured default permissive.
    func isAllowed(from handle: String, chat: String) -> Bool {
        if isEmpty { return false }
        if AccessConfig.isGroupIdentifier(chat) {
            return allowedGroups.contains(chat)
        }
        return allowFrom.contains(AccessConfig.normalizePhone(handle))
    }

    /// Outbound gate: an empty (unconfigured) config permits all recipients,
    /// mirroring the inbound poller's permissive default. Once configured,
    /// sends are limited to the same allowlist that gates inbound — group
    /// identifiers match `allowedGroups`, everything else matches the
    /// normalized handle against `allowFrom`.
    func isAllowedRecipient(_ recipient: String) -> Bool {
        if isEmpty { return true }
        if AccessConfig.isGroupIdentifier(recipient) {
            return allowedGroups.contains(recipient)
        }
        return allowFrom.contains(AccessConfig.normalizePhone(recipient))
    }

    /// A group `chat_identifier` is the literal `chat` followed by digits
    /// (e.g. `chat646855985291785786`). Requiring the numeric suffix avoids
    /// misclassifying handles such as `chat@example.com` as groups.
    static func isGroupIdentifier(_ chat: String) -> Bool {
        guard chat.hasPrefix("chat") else { return false }
        let suffix = chat.dropFirst(4)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isNumber }
    }

    /// Normalize a phone number to E.164 for consistent matching. Non-phone
    /// handles (email addresses) are lowercased and returned unchanged.
    static func normalizePhone(_ phone: String) -> String {
        let stripped = phone.filter { $0.isNumber || $0 == "+" }
        if stripped.hasPrefix("+") { return stripped }
        let digits = stripped.filter { $0.isNumber }
        if digits.count == 11 && digits.hasPrefix("1") { return "+" + digits }
        if digits.count == 10 { return "+1" + digits }
        return phone.lowercased()
    }
}
