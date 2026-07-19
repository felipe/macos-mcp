import CoreServices
import EventKit
import Foundation

// MARK: - Permissions Status
//
// Reports every permission domain the server depends on without triggering
// prompts, Apple Events, or anything that can hang. Every probe here is
// synchronous and local: a read-only open(2), an EventKit status lookup, an
// AEDeterminePermissionToAutomateTarget call with askUserIfNeeded=false, and
// a directory listing.

private let wildcardEventSpec: FourCharCode = 0x2A2A_2A2A  // '****'

/// Probe Full Disk Access by opening chat.db read-only. Opening the file is
/// the exact operation the Messages tools need, so the probe cannot drift
/// from reality.
private func fullDiskAccessStatus() -> String {
    let chatDBPath = NSString("~/Library/Messages/chat.db").expandingTildeInPath
    let fd = Darwin.open(chatDBPath, O_RDONLY)
    if fd >= 0 {
        Darwin.close(fd)
        return "ok"
    }
    return errno == ENOENT ? "chat.db not found" : "denied"
}

/// Ask the Apple Events subsystem whether we may automate `bundleId`,
/// explicitly without prompting (askUserIfNeeded=false). Never sends a real
/// Apple Event and never pops a consent dialog. The call can still block for
/// tens of seconds while appleeventsd waits on a launching target, so it runs
/// on a background thread bounded by a 3s deadline.
private func automationStatus(bundleId: String) -> String {
    var probed = "unknown"
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        defer { sem.signal() }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let descPointer = target.aeDesc else { return }
        var address = descPointer.pointee
        let status = AEDeterminePermissionToAutomateTarget(&address, wildcardEventSpec, wildcardEventSpec, false)
        switch status {
        case 0:  // noErr
            probed = "granted"
        case -600:  // procNotFound — target app is not running, so TCC cannot answer
            probed = "appNotRunning"
        case -1743:  // errAEEventNotPermitted
            probed = "denied"
        case -1744:  // errAEEventWouldRequireUserConsent
            probed = "notDetermined"
        default:
            probed = "unknown (OSStatus \(status))"
        }
    }
    if sem.wait(timeout: .now() + 3) == .timedOut {
        return "unknown (probe timed out after 3s)"
    }
    return probed
}

private func vaultStatus(root: String) -> [String: Any] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else {
        return ["status": "missing", "path": root]
    }
    guard isDirectory.boolValue else {
        return ["status": "not a directory", "path": root]
    }
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else {
        return ["status": "not listable", "path": root]
    }
    return ["status": "ok", "path": root, "entries": entries.count]
}

func permissionsStatusJSON(vaultRoot: String) -> String {
    let report: [String: Any] = [
        "full_disk_access": fullDiskAccessStatus(),
        "calendar": calendarAuthorizationStatusName(),
        "automation_notes": automationStatus(bundleId: "com.apple.Notes"),
        "automation_reminders": automationStatus(bundleId: "com.apple.reminders"),
        "vault": vaultStatus(root: vaultRoot),
    ]
    return serializeJSONObject(report)
}
