import Foundation

// MARK: - iCloud Sync
//
// Copies files from iCloud Drive to a local cache directory.
// Useful for launchd agents that need iCloud data but shouldn't
// require Full Disk Access themselves.
//
// Usage:
//   macos-mcp icloud sync --source <subfolder> --cache <dir> --files <f1,f2,...> [-- command args...]

private let iCloudBase = "Library/Mobile Documents/com~apple~CloudDocs"

private func resolveHome() -> String {
    if let home = ProcessInfo.processInfo.environment["HOME"] { return home }
    return NSHomeDirectory()
}

private func ensureParents(_ path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
}

func runICloud(subcommand: String, args: [String]) {
    switch subcommand {
    case "sync":
        runICloudSync(args: args)
    default:
        exitWithError("Unknown icloud subcommand: \(subcommand). Available: sync")
    }
}

private func runICloudSync(args: [String]) {
    var source: String?
    var cache: String?
    var filesArg: String?
    var execArgs: [String] = []

    var i = 0
    while i < args.count {
        if args[i] == "--" {
            execArgs = Array(args[(i + 1)...])
            break
        }
        switch args[i] {
        case "--source": source = requireArgValue(args, &i, flag: "--source")
        case "--cache":  cache  = requireArgValue(args, &i, flag: "--cache")
        case "--files":  filesArg = requireArgValue(args, &i, flag: "--files")
        default: break
        }
        i += 1
    }

    guard let source = source, let cache = cache, let filesArg = filesArg else {
        exitWithError("icloud sync requires --source <subfolder> --cache <dir> --files <comma-separated>")
    }

    let home = resolveHome()
    let files = filesArg.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    if files.isEmpty {
        exitWithError("icloud sync requires a non-empty --files list")
    }
    let sourceBase = "\(home)/\(iCloudBase)/\(source)"
    let fm = FileManager.default

    // Ensure cache root exists
    try? fm.createDirectory(atPath: cache, withIntermediateDirectories: true)

    var synced = 0
    var failed: [String] = []

    for file in files {
        let src = "\(sourceBase)/\(file)"
        let dst = "\(cache)/\(file)"

        ensureParents(dst)
        try? fm.removeItem(atPath: dst)

        do {
            try fm.copyItem(atPath: src, toPath: dst)
            synced += 1
        } catch {
            fputs("icloud-sync: \(file) — \(error.localizedDescription)\n", stderr)
            failed.append(file)
        }
    }

    fputs("icloud-sync: \(synced) synced, \(failed.count) failed\n", stderr)

    // If command provided after --, exec into it (skip JSON — execv replaces the process)
    if !execArgs.isEmpty {
        if !failed.isEmpty {
            fputs("icloud-sync: aborting exec due to sync failures\n", stderr)
            exit(1)
        }
        let argv = ["/bin/bash"] + execArgs
        let cArgs = argv.map { strdup($0) } + [nil]
        execv("/bin/bash", cArgs)
        exitWithError("icloud sync exec failed: \(String(cString: strerror(errno)))")
    }

    // Standalone mode — print JSON result
    var result: [String: Any] = [
        "synced": NSNumber(value: synced),
        "failed": NSNumber(value: failed.count),
        "total": NSNumber(value: files.count)
    ]
    if !failed.isEmpty {
        result["failedFiles"] = failed
    }
    printJSON(result)

    exit(failed.isEmpty ? 0 : 1)
}
