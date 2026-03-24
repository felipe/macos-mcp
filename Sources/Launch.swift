import Foundation

// FDA-granted process wrapper for launchd agents.
// Add the macos-mcp binary to System Settings > Privacy > Full Disk Access.
// It spawns the given command as a child process (inheriting FDA)
// and waits for it to exit, forwarding the exit code.

func runLaunch(args: [String]) -> Never {
    guard !args.isEmpty else {
        exitWithError("launch requires a command")
    }

    // Use execv to replace this process with bash.
    // The child inherits our PID so launchd signals reach it directly,
    // preventing orphaned processes on daemon restart.
    let argv = ["/bin/bash"] + args
    let cArgs = argv.map { strdup($0) } + [nil]
    execv("/bin/bash", cArgs)

    // execv only returns on failure
    exitWithError("launch exec failed: \(String(cString: strerror(errno)))")
}
