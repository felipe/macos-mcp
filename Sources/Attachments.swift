import Foundation
import SQLite3

// MARK: - Attachments Command

func runAttachments(args: [String]) {
    var rowid: Int64?
    var convertHeic = false
    var maxSize = 1024
    var outputDir = NSTemporaryDirectory()

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--rowid":
            let val = requireArgValue(args, &i, flag: "--rowid")
            rowid = Int64(val)
        case "--convert-heic":
            convertHeic = true
        case "--max-size":
            let val = requireArgValue(args, &i, flag: "--max-size")
            maxSize = Int(val) ?? 1024
        case "--output-dir":
            outputDir = requireArgValue(args, &i, flag: "--output-dir")
        default: break
        }
        i += 1
    }

    guard let rowid = rowid else {
        exitWithError("attachments requires --rowid N")
    }

    let dbPath = NSString("~/Library/Messages/chat.db").expandingTildeInPath
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
          let db = db else {
        exitWithError("Cannot open Messages database")
    }
    defer { sqlite3_close(db) }

    let sql = """
        SELECT a.ROWID, a.filename, a.mime_type, a.transfer_name
        FROM attachment a
        JOIN message_attachment_join maj ON a.ROWID = maj.attachment_id
        WHERE maj.message_id = ?
        """

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
        exitWithError("SQL prepare failed")
    }
    defer { sqlite3_finalize(stmt) }

    sqlite3_bind_int64(stmt, 1, rowid)

    var attachments: [[String: Any]] = []

    while sqlite3_step(stmt) == SQLITE_ROW {
        let attRowid = sqlite3_column_int64(stmt, 0)
        let rawFilename = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        let mimeType = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let transferName = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""

        let filename = NSString(string: rawFilename).expandingTildeInPath
        let fm = FileManager.default

        guard fm.fileExists(atPath: filename) else {
            attachments.append([
                "error": "File not found",
                "original_path": filename,
                "mime_type": mimeType,
                "transfer_name": transferName
            ])
            continue
        }

        let attrs = try? fm.attributesOfItem(atPath: filename)
        let fileSize = attrs?[.size] as? Int64 ?? 0

        var att: [String: Any] = [
            "original_path": filename,
            "mime_type": mimeType,
            "transfer_name": transferName,
            "file_size": fileSize
        ]

        let isImage = mimeType.hasPrefix("image/")
        let isHeic = mimeType == "image/heic" || filename.lowercased().hasSuffix(".heic")

        if isImage {
            att["type"] = "image"

            // Get dimensions via sips
            let (sipsOut, _, sipsExit) = runProcess("/usr/bin/sips", arguments: ["-g", "pixelWidth", "-g", "pixelHeight", filename])
            if sipsExit == 0 {
                var width = 0, height = 0
                for line in sipsOut.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("pixelWidth:") {
                        width = Int(trimmed.replacingOccurrences(of: "pixelWidth:", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                    } else if trimmed.hasPrefix("pixelHeight:") {
                        height = Int(trimmed.replacingOccurrences(of: "pixelHeight:", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }
                if width > 0 && height > 0 {
                    att["dimensions"] = "\(width)x\(height)"
                }
            }

            // Convert HEIC to JPEG if requested
            if convertHeic && isHeic {
                let outPath = "\(outputDir)/attachment_\(attRowid).jpg"
                let (_, _, convertExit) = runProcess("/usr/bin/sips", arguments: [
                    "-s", "format", "jpeg",
                    "-Z", "\(maxSize)",
                    filename,
                    "--out", outPath
                ])
                if convertExit == 0 {
                    att["converted_path"] = outPath
                }
            }
        } else {
            att["type"] = "file"
        }

        attachments.append(att)
    }

    printJSON(["attachments": attachments])
}
