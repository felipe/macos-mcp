import Foundation
import CoreFoundation

/// A host-controlled policy. It gates MCP calls; local CLI access is outside this boundary.
struct ToolPermissions {
    struct Rule {
        let allow: Bool
        let pathNames: Set<String>?
        let modes: Set<String>?
        let paths: [String]?
    }

    static let readOnlyTools: Set<String> = [
        "vault_read", "vault_list", "vault_search", "scoped_read",
        "check_messages", "read_conversation", "list_conversations", "max_rowid",
        "calendar_list", "calendar_upcoming", "calendar_events", "calendar_search",
        "permissions_status", "notes_search", "notes_read", "reminders_list", "contacts_search",
        "mail_search", "mail_read", "mail_list_mailboxes",
        "mail_capabilities", "mail_account_list", "mail_mailbox_list", "mail_envelope_list", "mail_envelope_search",
        "mail_message_read", "mail_attachment_list",
        "list_emails", "search_emails", "read_email", "read_email_html", "list_folders",
    ]
    let rules: [String: Rule]
    let policyPath: String
    let error: String?

    static func configuredPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        ((environment["MACOS_MCP_PERMISSIONS_FILE"] ?? NSHomeDirectory() + "/.config/macos-mcp/permissions.json") as NSString).expandingTildeInPath
    }

    static func load(knownTools: Set<String>, environment: [String: String] = ProcessInfo.processInfo.environment, defaultPath: String? = nil) -> ToolPermissions {
        let path = environment["MACOS_MCP_PERMISSIONS_FILE"] != nil ? configuredPath(environment: environment) : (defaultPath ?? configuredPath(environment: environment))
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1_048_577) ?? Data()
            return try parse(data, path: path, knownTools: knownTools)
        } catch let failure as NSError {
            // A missing default file leaves only known read-only capabilities enabled.
            // A configured-but-missing path is an operator error and denies every call.
            if environment["MACOS_MCP_PERMISSIONS_FILE"] == nil,
               failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError {
                return ToolPermissions(rules: Dictionary(uniqueKeysWithValues: readOnlyTools.intersection(knownTools).map {
                    ($0, Rule(allow: true, pathNames: nil, modes: nil, paths: nil))
                }), policyPath: path, error: nil)
            }
            return ToolPermissions(rules: [:], policyPath: path, error: "MCP permissions file is missing, unreadable, or invalid; all tools are disabled")
        }
    }

    static func parse(_ data: Data, path: String, knownTools: Set<String>) throws -> ToolPermissions {
        func invalid() -> NSError { NSError(domain: "ToolPermissions", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid MCP permissions policy"]) }
        guard data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "tools"],
              let version = object["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
              let entries = object["tools"] as? [String: Any], Set(entries.keys).isSubset(of: knownTools) else { throw invalid() }
        var rules: [String: Rule] = [:]
        for (name, value) in entries {
            guard let raw = value as? [String: Any],
                  Set(raw.keys).isSubset(of: ["allow", "path_names", "modes", "paths"]),
                  let allow = raw["allow"] as? NSNumber, CFGetTypeID(allow) == CFBooleanGetTypeID() else { throw invalid() }
            func strings(_ key: String) throws -> [String]? {
                guard let value = raw[key] else { return nil }
                guard let values = value as? [String], values.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else { throw invalid() }
                return values
            }
            let names = try strings("path_names"), modes = try strings("modes"), paths = try strings("paths")
            if names != nil && !["scoped_read", "scoped_write"].contains(name) { throw invalid() }
            if let modes, name != "scoped_write" || !Set(modes).isSubset(of: ["upsert", "append-section", "supersede"]) { throw invalid() }
            if let paths {
                guard ["scoped_read", "scoped_write", "vault_read", "vault_write", "vault_list"].contains(name),
                      paths.allSatisfy({ validRelativePath($0) }) else { throw invalid() }
            }
            rules[name] = Rule(allow: allow.boolValue, pathNames: names.map(Set.init), modes: modes.map(Set.init), paths: paths)
        }
        return ToolPermissions(rules: rules, policyPath: path, error: nil)
    }

    func allows(_ name: String) -> Bool { error == nil && rules[name]?.allow == true }

    func denial(tool: String, input: [String: Any], allowedPaths: [String: String], vaultRoot: String, auditLogPath: String? = nil) -> String? {
        var input = input
        if ["scoped_read", "scoped_write"].contains(tool) {
            for key in ["path_name", "path", "mode"] {
                if let value = input[key] as? String { input[key] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            if let mode = input["mode"] as? String { input["mode"] = mode.lowercased() }
        }
        if let error { return error }
        guard let rule = rules[tool], rule.allow else { return "MCP permission denied for \(tool)" }
        if let names = rule.pathNames {
            guard let name = input["path_name"] as? String, names.contains(name) else { return "MCP permission denied for this path_name" }
        }
        if let modes = rule.modes {
            guard let mode = input["mode"] as? String, modes.contains(mode) else { return "MCP permission denied for this write mode" }
        }
        if tool == "scoped_write", let auditLogPath {
            let expanded = (auditLogPath as NSString).expandingTildeInPath
            // Scoped writes append to the audit log and may rotate five backups.
            if ([expanded] + (1...5).map { expanded + ".\($0)" }).contains(where: protects) {
                return "MCP audit logging cannot modify the permissions file"
            }
        }
        let root: String?
        if ["scoped_read", "scoped_write"].contains(tool) { root = (input["path_name"] as? String).flatMap { allowedPaths[$0] } }
        else if ["vault_read", "vault_write", "vault_list"].contains(tool) { root = vaultRoot }
        else { root = nil }
        if let paths = rule.paths {
            guard let root, let relative = input["path"] as? String,
                  let target = Self.resolved(root: root, relative: relative),
                  paths.contains(where: { prefix in
                      guard let allowed = Self.resolved(root: root, relative: prefix) else { return false }
                      return target == allowed || target.hasPrefix(allowed + "/")
                  }) else { return "MCP permission denied for this path" }
        }
        if ["scoped_write", "vault_write"].contains(tool), let root, let path = input["path"] as? String,
           let target = Self.resolved(root: root, relative: path), protects(target) {
            return "MCP tools cannot modify their permissions file"
        }
        return nil
    }

    func protects(_ path: String) -> Bool {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let policy = URL(fileURLWithPath: policyPath).resolvingSymlinksInPath().standardizedFileURL.path
        let configured = URL(fileURLWithPath: policyPath).standardizedFileURL.path
        let originalTarget = URL(fileURLWithPath: path).standardizedFileURL.path
        if target == policy || policy.hasPrefix(target + "/") || originalTarget == configured || configured.hasPrefix(originalTarget + "/") { return true }
        let fm = FileManager.default
        if let a = try? fm.attributesOfItem(atPath: target), let b = try? fm.attributesOfItem(atPath: policy),
           let ai = a[.systemFileNumber] as? NSNumber, let bi = b[.systemFileNumber] as? NSNumber,
           let ad = a[.systemNumber] as? NSNumber, let bd = b[.systemNumber] as? NSNumber {
            return ai == bi && ad == bd
        }
        return false
    }

    private static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && !path.split(separator: "/").contains("..")
    }

    private static func resolved(root: String, relative: String) -> String? {
        guard validRelativePath(relative) else { return nil }
        let base = URL(fileURLWithPath: (root as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
        var current = base
        for component in (relative as NSString).pathComponents where component != "." && component != "/" {
            let next = URL(fileURLWithPath: current).appendingPathComponent(component)
            // Resolve existing components individually: the final file may not exist yet.
            if FileManager.default.fileExists(atPath: next.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: next.path)) != nil {
                current = next.resolvingSymlinksInPath().standardizedFileURL.path
            } else { current = next.standardizedFileURL.path }
            guard current == base || current.hasPrefix(base + "/") else { return nil }
        }
        return current
    }
}
