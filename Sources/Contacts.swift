import Foundation
import SQLite3

// MARK: - Contacts Search (read-only, AddressBook SQLite)
//
// Searches the AddressBook databases directly (name, phone, email) and
// returns matches with their handles. Reads are covered by the Full Disk
// Access grant — no Contacts.framework TCC prompt is ever triggered. Each
// database is opened read-only with immutable=1 so the live store is never
// locked.
//
// Query approach based on boop-agent (MIT, Chris Raroque):
// https://github.com/raroque/boop-agent

private let contactsQueryRowCap = 50

// MARK: - Database Discovery

/// AddressBook keeps one database at the root plus one per account under
/// Sources/<uuid>/. All of them are searched.
private func findAddressBookDBs() -> [String] {
    let fm = FileManager.default
    let root = NSString("~/Library/Application Support/AddressBook").expandingTildeInPath
    var dbs: [String] = []

    func appendDBs(in directory: String) {
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries where entry.hasPrefix("AddressBook-v") && entry.hasSuffix(".abcddb") {
            dbs.append((directory as NSString).appendingPathComponent(entry))
        }
    }

    appendDBs(in: root)
    let sourcesDir = (root as NSString).appendingPathComponent("Sources")
    if let sources = try? fm.contentsOfDirectory(atPath: sourcesDir) {
        for source in sources.sorted() {
            appendDBs(in: (sourcesDir as NSString).appendingPathComponent(source))
        }
    }
    return dbs
}

// MARK: - SQLite Helpers

private func openReadOnly(_ path: String) -> OpaquePointer? {
    // immutable=1 promises SQLite the file cannot change, so it takes no
    // locks at all — the Contacts app is never blocked by our reads.
    let uri = "file:\(URL(fileURLWithPath: path).absoluteURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro&immutable=1"
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
    guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, db != nil else {
        if db != nil { sqlite3_close(db) }
        return nil
    }
    return db
}

private func queryRows(_ db: OpaquePointer, sql: String, textBindings: [String] = []) -> [[String: Any]]? {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
        return nil
    }
    defer { sqlite3_finalize(stmt) }

    for (index, value) in textBindings.enumerated() {
        sqlite3_bind_text(stmt, Int32(index + 1), (value as NSString).utf8String, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    var rows: [[String: Any]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        var row: [String: Any] = [:]
        for i in 0..<sqlite3_column_count(stmt) {
            let name = String(cString: sqlite3_column_name(stmt, i))
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER:
                row[name] = NSNumber(value: sqlite3_column_int64(stmt, i))
            case SQLITE_TEXT:
                row[name] = String(cString: sqlite3_column_text(stmt, i))
            default:
                break
            }
        }
        rows.append(row)
    }
    return rows
}

private func escapeLike(_ input: String) -> String {
    return input
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
}

// MARK: - Search

private func searchDatabase(_ db: OpaquePointer, query: String, pattern: String) -> [[String: Any]]? {
    // 1. Records whose name fields match.
    let nameSQL = """
        SELECT Z_PK AS id, ZFIRSTNAME AS firstName, ZLASTNAME AS lastName,
               ZNICKNAME AS nickname, ZORGANIZATION AS organization
        FROM ZABCDRECORD
        WHERE COALESCE(ZFIRSTNAME, '') LIKE ?1 ESCAPE '\\'
           OR COALESCE(ZLASTNAME, '') LIKE ?1 ESCAPE '\\'
           OR COALESCE(ZNICKNAME, '') LIKE ?1 ESCAPE '\\'
           OR COALESCE(ZORGANIZATION, '') LIKE ?1 ESCAPE '\\'
           OR TRIM(COALESCE(ZFIRSTNAME, '') || ' ' || COALESCE(ZLASTNAME, '')) LIKE ?1 ESCAPE '\\'
        LIMIT \(contactsQueryRowCap)
        """
    guard var candidates = queryRows(db, sql: nameSQL, textBindings: [pattern]) else { return nil }

    // 2. Records whose phone or email match, pulled in by owner id.
    let phoneOwnerSQL = """
        SELECT DISTINCT ZOWNER AS owner FROM ZABCDPHONENUMBER
        WHERE COALESCE(ZFULLNUMBER, '') LIKE ?1 ESCAPE '\\'
        LIMIT \(contactsQueryRowCap)
        """
    let emailOwnerSQL = """
        SELECT DISTINCT ZOWNER AS owner FROM ZABCDEMAILADDRESS
        WHERE COALESCE(ZADDRESSNORMALIZED, ZADDRESS, '') LIKE ?1 ESCAPE '\\'
        LIMIT \(contactsQueryRowCap)
        """
    var handleOwnerIds: Set<Int64> = []
    for sql in [phoneOwnerSQL, emailOwnerSQL] {
        for row in queryRows(db, sql: sql, textBindings: [pattern]) ?? [] {
            if let owner = row["owner"] as? NSNumber { handleOwnerIds.insert(owner.int64Value) }
        }
    }
    let knownIds = Set(candidates.compactMap { ($0["id"] as? NSNumber)?.int64Value })
    let missingIds = handleOwnerIds.subtracting(knownIds)
    if !missingIds.isEmpty {
        let idList = missingIds.map(String.init).joined(separator: ", ")
        let byIdSQL = """
            SELECT Z_PK AS id, ZFIRSTNAME AS firstName, ZLASTNAME AS lastName,
                   ZNICKNAME AS nickname, ZORGANIZATION AS organization
            FROM ZABCDRECORD WHERE Z_PK IN (\(idList))
            """
        candidates.append(contentsOf: queryRows(db, sql: byIdSQL) ?? [])
    }

    // 3. Handles for every matched record.
    var results: [[String: Any]] = []
    for candidate in candidates {
        guard let id = (candidate["id"] as? NSNumber)?.int64Value else { continue }

        var phones: [String] = []
        let phonesSQL = "SELECT ZFULLNUMBER AS value FROM ZABCDPHONENUMBER WHERE ZOWNER = \(id) AND COALESCE(ZFULLNUMBER, '') <> ''"
        for row in queryRows(db, sql: phonesSQL) ?? [] {
            if let value = row["value"] as? String { phones.append(value) }
        }

        var emails: [String] = []
        let emailsSQL = "SELECT COALESCE(ZADDRESSNORMALIZED, ZADDRESS) AS value FROM ZABCDEMAILADDRESS WHERE ZOWNER = \(id) AND COALESCE(ZADDRESSNORMALIZED, ZADDRESS, '') <> ''"
        for row in queryRows(db, sql: emailsSQL) ?? [] {
            if let value = row["value"] as? String { emails.append(value) }
        }

        let first = candidate["firstName"] as? String ?? ""
        let last = candidate["lastName"] as? String ?? ""
        let nickname = candidate["nickname"] as? String ?? ""
        let organization = candidate["organization"] as? String ?? ""
        var name = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
        if name.isEmpty { name = nickname }
        if name.isEmpty { name = organization }
        if name.isEmpty && phones.isEmpty && emails.isEmpty { continue }

        var entry: [String: Any] = [
            "name": name,
            "phones": phones,
            "emails": emails,
        ]
        if !organization.isEmpty { entry["organization"] = organization }
        if !nickname.isEmpty { entry["nickname"] = nickname }
        results.append(entry)
    }
    return results
}

// MARK: - Tool

func contactsSearch(query: String, limit: Int?) -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2 else {
        return serializeJSONObject(["error": "contacts_search requires a query of at least 2 characters"])
    }
    let maxResults = clampedLimit(limit, fallback: 10)

    let dbPaths = findAddressBookDBs()
    guard !dbPaths.isEmpty else {
        return serializeJSONObject(["error": "No AddressBook database found under ~/Library/Application Support/AddressBook. If the directory exists, Full Disk Access may not be granted."])
    }

    let pattern = "%\(escapeLike(trimmed))%"
    var results: [[String: Any]] = []
    var openedAny = false
    var seen: Set<String> = []

    for path in dbPaths {
        guard let db = openReadOnly(path) else { continue }
        defer { sqlite3_close(db) }
        openedAny = true

        for entry in searchDatabase(db, query: trimmed, pattern: pattern) ?? [] {
            // De-duplicate identical contacts that appear in multiple databases.
            let name = entry["name"] as? String ?? ""
            let phones = (entry["phones"] as? [String] ?? []).joined(separator: ",")
            let emails = (entry["emails"] as? [String] ?? []).joined(separator: ",")
            let key = "\(name)|\(phones)|\(emails)"
            if seen.contains(key) { continue }
            seen.insert(key)
            results.append(entry)
            if results.count >= maxResults { break }
        }
        if results.count >= maxResults { break }
    }

    guard openedAny else {
        return serializeJSONObject(["error": "Contacts database could not be opened. Full Disk Access may not be granted to macos-mcp."])
    }
    return serializeJSONObject(["query": trimmed, "results": results])
}
