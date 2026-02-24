import Cocoa
import Foundation

// ZoomMeetilyBridge: auto-start/stop Meetily recording when Zoom meeting starts/ends.
// Polls every 5 seconds. Uses NSAppleScript for UI automation.

let POLL_INTERVAL: TimeInterval = 5
let MEETING_START_DELAY: TimeInterval = 3

// MARK: - Logging

let logDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/logs")
let logFile = logDir.appendingPathComponent("zoom-meetily-bridge.log")

func ensureLogDir() {
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
}

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    let line = "\(timestamp) \(message)\n"

    // Print to stderr (for LaunchAgent stderr log)
    FileHandle.standardError.write(Data(line.utf8))

    // Append to log file
    if let handle = try? FileHandle(forWritingTo: logFile) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logFile.path, contents: Data(line.utf8))
    }
}

// MARK: - AppleScript helpers

func runAppleScript(_ source: String) -> (success: Bool, output: String) {
    let script = NSAppleScript(source: source)!
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error = error {
        let msg = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
        return (false, msg)
    }
    return (true, result.stringValue ?? "")
}

func isProcessRunning(_ name: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-x", name]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    try? task.run()
    task.waitUntilExit()
    return task.terminationStatus == 0
}

func isInMeeting() -> Bool {
    let (ok, output) = runAppleScript("""
    tell application "System Events"
        if not (exists process "zoom.us") then
            return "no_zoom"
        end if
        tell process "zoom.us"
            set meetingFound to false
            repeat with w in windows
                try
                    set winName to name of w
                    if winName is not "Zoom Workplace" and winName is not "" and winName is not missing value then
                        set meetingFound to true
                        exit repeat
                    end if
                end try
            end repeat
            if meetingFound then
                return "in_meeting"
            else
                return "no_meeting"
            end if
        end tell
    end tell
    """)
    if !ok {
        log("[WARNING] zoom-meeting check failed: \(output)")
        return false
    }
    return output == "in_meeting"
}

func clickMeetilyStart() -> Bool {
    let (ok, output) = runAppleScript("""
    tell application "System Events"
        tell process "meetily"
            set statusItem to menu bar item 1 of menu bar 2
            click statusItem
            delay 0.3
            try
                click menu item "Start Recording" of menu 1 of statusItem
                return "clicked"
            on error
                key code 53
                return "not_found"
            end try
        end tell
    end tell
    """)
    return ok && output == "clicked"
}

func clickMeetilyStop() -> Bool {
    let (ok, output) = runAppleScript("""
    tell application "System Events"
        tell process "meetily"
            set statusItem to menu bar item 1 of menu bar 2
            click statusItem
            delay 0.3
            try
                click menu item "\u{23F9} Stop Recording" of menu 1 of statusItem
                return "clicked"
            on error
                key code 53
                return "not_found"
            end try
        end tell
    end tell
    """)
    return ok && output == "clicked"
}

func isMeetilyRecording() -> Bool {
    let (ok, output) = runAppleScript("""
    tell application "System Events"
        tell process "meetily"
            set statusItem to menu bar item 1 of menu bar 2
            click statusItem
            delay 0.3
            set foundStop to false
            repeat with mi in menu items of menu 1 of statusItem
                try
                    set n to name of mi
                    if n starts with "\u{23F9}" then
                        set foundStop to true
                        exit repeat
                    end if
                end try
            end repeat
            key code 53
            if foundStop then
                return "recording"
            else
                return "idle"
            end if
        end tell
    end tell
    """)
    return ok && output == "recording"
}

// MARK: - Main loop

ensureLogDir()
log("[INFO] zoom-meetily-bridge started (poll=\(Int(POLL_INTERVAL))s)")

var recording = false

while true {
    let inMeeting = isInMeeting()
    let meetilyRunning = isProcessRunning("meetily")

    if inMeeting && !recording {
        if !meetilyRunning {
            log("[WARNING] Zoom meeting active but Meetily not running — skipping")
        } else {
            log("[INFO] Zoom meeting detected, waiting \(Int(MEETING_START_DELAY))s...")
            Thread.sleep(forTimeInterval: MEETING_START_DELAY)
            if isInMeeting() {
                if clickMeetilyStart() {
                    recording = true
                    log("[INFO] Recording STARTED")
                } else if isMeetilyRecording() {
                    recording = true
                    log("[INFO] Already recording, synced state")
                } else {
                    log("[WARNING] Failed to start recording")
                }
            } else {
                log("[INFO] Meeting ended during delay — cancelled start")
            }
        }
    } else if !inMeeting && recording {
        if !meetilyRunning {
            log("[WARNING] Meetily not running — reset recording state")
            recording = false
        } else {
            if clickMeetilyStop() {
                log("[INFO] Recording STOPPED")
            } else {
                log("[WARNING] Failed to stop recording")
            }
            recording = false
        }
    }

    Thread.sleep(forTimeInterval: POLL_INTERVAL)
}
