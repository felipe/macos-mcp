import Foundation

// FDA-granted process wrapper for launchd agents.
// Add the macos-mcp binary to System Settings > Privacy > Full Disk Access.
// It spawns the given command as a child process (inheriting FDA)
// and waits for it to exit, forwarding the exit code.

func runLaunch(args: [String]) -> Never {
    guard !args.isEmpty else {
        exitWithError("launch requires a command")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment

    do {
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus)
    } catch {
        exitWithError("launch failed: \(error.localizedDescription)")
    }
}
