import Foundation

// mac-launcher: FDA-granted process wrapper for launchd agents
// Add this binary to System Settings > Privacy > Full Disk Access
// It spawns the given command as a child process (inheriting FDA)
// and waits for it to exit, forwarding the exit code.
//
// Build: swiftc -O -o mac-launcher launcher.swift

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: mac-launcher <command> [args...]\n", stderr)
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/bash")
process.arguments = args
process.environment = ProcessInfo.processInfo.environment

do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    fputs("mac-launcher: \(error.localizedDescription)\n", stderr)
    exit(1)
}
