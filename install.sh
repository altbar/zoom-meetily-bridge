#!/bin/bash
# Zoom-Meetily Bridge Installer
# Self-contained: builds and installs everything from embedded sources.
# Usage: bash install.sh
set -euo pipefail

APP_NAME="ZoomMeetilyBridge"
APP_DIR="$HOME/Applications/${APP_NAME}.app"
BINARY_DIR="$APP_DIR/Contents/MacOS"
BINARY="$BINARY_DIR/$APP_NAME"
LABEL="com.altbar.zoom-meetily-bridge"
PLIST_DST="$HOME/Library/LaunchAgents/${LABEL}.plist"
LOG_DIR="$HOME/.claude/logs"
MEETILY_APP="/Applications/meetily.app"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

step() { echo -e "\n${GREEN}[$1/5]${NC} $2"; }
warn() { echo -e "  ${YELLOW}WARNING:${NC} $1"; }
fail() { echo -e "  ${RED}ERROR:${NC} $1"; exit 1; }
info() { echo -e "  $1"; }

echo "========================================"
echo " Zoom-Meetily Bridge Installer"
echo "========================================"

# ─── Step 1: Prerequisites ───────────────────────────────────────────

step 1 "Checking prerequisites..."

if ! command -v swiftc &>/dev/null; then
    fail "swiftc not found. Install Xcode Command Line Tools: xcode-select --install"
fi
info "swiftc: $(swiftc --version 2>&1 | head -1)"

if ! command -v python3 &>/dev/null; then
    fail "python3 not found"
fi
info "python3: $(python3 --version)"

if [ -d "$MEETILY_APP" ]; then
    info "Meetily: found at $MEETILY_APP"
    HAS_MEETILY=true
else
    warn "Meetily not found at $MEETILY_APP — language patch will be skipped"
    HAS_MEETILY=false
fi

# ─── Step 2: Build ZoomMeetilyBridge.app ─────────────────────────────

step 2 "Building ${APP_NAME}.app..."

# Stop existing agent if running
if launchctl list 2>/dev/null | grep -q "$LABEL"; then
    info "Stopping existing agent..."
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    sleep 1
fi

# Create app bundle structure
mkdir -p "$BINARY_DIR"
mkdir -p "$LOG_DIR"

# Write Swift source to temp file
SWIFT_TMP=$(mktemp /tmp/ZoomMeetilyBridge-XXXXXXXX)
mv "$SWIFT_TMP" "${SWIFT_TMP}.swift"
SWIFT_TMP="${SWIFT_TMP}.swift"
PATCH_TMP=""
trap 'rm -f "$SWIFT_TMP" "$PATCH_TMP" 2>/dev/null' EXIT

cat > "$SWIFT_TMP" << 'SWIFT_EOF'
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
SWIFT_EOF

# Compile
info "Compiling Swift source..."
swiftc -o "$BINARY" -framework Cocoa "$SWIFT_TMP"
info "Binary: $BINARY"

# Write Info.plist
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.altbar.zoom-meetily-bridge-helper</string>
    <key>CFBundleName</key>
    <string>ZoomMeetilyBridge</string>
    <key>CFBundleExecutable</key>
    <string>ZoomMeetilyBridge</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>ZoomMeetilyBridge needs to control Meetily recording via System Events</string>
</dict>
</plist>
PLIST_EOF

info "App bundle: $APP_DIR"

# ─── Step 3: Install LaunchAgent ─────────────────────────────────────

step 3 "Installing LaunchAgent..."

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_DST" << AGENT_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BINARY}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/zoom-meetily-bridge-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/zoom-meetily-bridge-stderr.log</string>
</dict>
</plist>
AGENT_EOF

info "Plist: $PLIST_DST"

# ─── Step 4: Patch Meetily language ──────────────────────────────────

step 4 "Patching Meetily for Russian language..."

if [ "$HAS_MEETILY" = false ]; then
    warn "Skipped — Meetily not installed"
else
    PATCH_TMP=$(mktemp /tmp/patch-meetily-XXXXXXXX)
    mv "$PATCH_TMP" "${PATCH_TMP}.py"
    PATCH_TMP="${PATCH_TMP}.py"

    cat > "$PATCH_TMP" << 'PATCH_EOF'
#!/usr/bin/env python3
"""Patch Meetily to default to Russian language transcription.

Meetily stores its language preference ONLY in a Rust in-memory static
(LazyLock<Mutex<String>>) initialized to "auto-translate". It is never
persisted to disk — every restart resets to auto-detect + translate to English.

This script binary-patches the default from "auto-translate" to "ru":
1. Finds the "auto-translate" string in the binary
2. Finds the ARM64 MOV W8, #14 instruction that sets the string length
3. Patches both: first byte 'a'->'r' and length 14->2, so the Rust String becomes "ru"
4. Re-signs with ad-hoc signature preserving entitlements

Two bytes changed:
  - String content: 'a' -> 'r' ("auto-translate" becomes "ruto-translate")
  - ARM64 MOV imm: MOV W8, #14 -> MOV W8, #2 (string length 14 -> 2)
  The Rust String now reads "ru" (2 bytes).

Reverting: backup saved at /Applications/meetily_pre_patch_backup.app
"""
import struct, subprocess, sys, os, shutil, tempfile

APP_PATH = "/Applications/meetily.app"
BINARY_REL = "Contents/MacOS/meetily"
BINARY_PATH = os.path.join(APP_PATH, BINARY_REL)


def find_string(data, needle=b"auto-translate"):
    """Find the single occurrence of the default language string."""
    idx = data.find(needle)
    if idx == -1:
        raise RuntimeError(f"String {needle!r} not found in binary")
    if data.find(needle, idx + 1) != -1:
        raise RuntimeError(f"Multiple occurrences of {needle!r} — unexpected binary layout")
    return idx


def get_text_segment_info(binary_path):
    """Get __TEXT segment vmaddr and fileoff from otool."""
    result = subprocess.run(["otool", "-l", binary_path], capture_output=True, text=True)
    lines = result.stdout.split("\n")
    for i, line in enumerate(lines):
        if "segname __TEXT" in line:
            vmaddr = fileoff = vmsize = filesize = None
            for j in range(max(0, i - 3), min(len(lines), i + 8)):
                l = lines[j].strip()
                if l.startswith("vmaddr"):
                    vmaddr = int(l.split()[-1], 16)
                elif l.startswith("fileoff"):
                    fileoff = int(l.split()[-1])
                elif l.startswith("vmsize"):
                    vmsize = int(l.split()[-1], 16)
                elif l.startswith("filesize"):
                    filesize = int(l.split()[-1])
            if vmaddr is not None and fileoff is not None:
                return vmaddr, fileoff, vmsize or 0, filesize or 0
    raise RuntimeError("Could not find __TEXT segment info")


def get_text_section_range(binary_path):
    """Get __text section offset and size (executable code area)."""
    result = subprocess.run(["otool", "-l", binary_path], capture_output=True, text=True)
    lines = result.stdout.split("\n")
    for i, line in enumerate(lines):
        if "sectname __text" in line:
            offset = size = addr = None
            for j in range(i, min(len(lines), i + 10)):
                l = lines[j].strip()
                if l.startswith("offset"):
                    offset = int(l.split()[-1])
                elif l.startswith("size"):
                    size = int(l.split()[-1], 16)
                elif l.startswith("addr"):
                    addr = int(l.split()[-1], 16)
            if offset is not None and size is not None:
                return offset, size, addr or 0
    raise RuntimeError("Could not find __text section info")


def find_mov_w8_14(data, string_file_offset, text_vmaddr, text_fileoff):
    """Find the MOV W8, #14 instruction near the code that references the string.

    Strategy: find ADRP+ADD instructions that compute the string's VA,
    then look for MOV W8, #14 nearby (within ~30 instructions).
    """
    string_va = text_vmaddr + (string_file_offset - text_fileoff)
    target_page = string_va & ~0xFFF
    page_offset = string_va & 0xFFF

    code_start, code_size, code_va = get_text_section_range(BINARY_PATH)
    code_end = code_start + code_size

    # MOV W8, #14 = 0x528001C8 (little-endian: C8 01 80 52)
    MOV_W8_14 = 0x528001C8

    candidates = []

    for i in range(code_start, code_end, 4):
        word = struct.unpack_from("<I", data, i)[0]
        # Check for ADRP: (word & 0x9F000000) == 0x90000000
        if (word & 0x9F000000) != 0x90000000:
            continue

        rd = word & 0x1F
        immlo = (word >> 29) & 0x3
        immhi = (word >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        if imm & 0x100000:
            imm -= 0x200000

        pc_va = code_va + (i - code_start)
        pc_page = pc_va & ~0xFFF
        result_page = (pc_page + (imm << 12)) & 0xFFFFFFFFFFFFFFFF

        if result_page != target_page:
            continue

        # Found ADRP to our page. Check next instruction for ADD with page_offset
        if i + 4 >= len(data):
            continue
        next_word = struct.unpack_from("<I", data, i + 4)[0]
        # ADD Xd, Xn, #imm12: (word & 0xFFC00000) == 0x91000000
        if (next_word & 0xFFC00000) == 0x91000000:
            add_imm = (next_word >> 10) & 0xFFF
            if add_imm == page_offset:
                # Found the exact ADRP+ADD referencing our string
                # Now search nearby for MOV W8, #14
                for k in range(-15, 30):
                    ci = i + k * 4
                    if ci < 0 or ci + 4 > len(data):
                        continue
                    cw = struct.unpack_from("<I", data, ci)[0]
                    if cw == MOV_W8_14:
                        candidates.append(ci)

    if not candidates:
        raise RuntimeError("Could not find MOV W8, #14 near auto-translate string reference")

    # Deduplicate
    candidates = sorted(set(candidates))
    return candidates


def extract_entitlements(app_path):
    """Extract entitlements to a temp plist file."""
    result = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", app_path],
        capture_output=True
    )
    if result.returncode != 0:
        plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key><true/>
    <key>com.apple.security.device.audio-output</key><true/>
    <key>com.apple.security.device.microphone</key><true/>
    <key>com.apple.security.device.screen-capture</key><true/>
</dict>
</plist>"""
    else:
        plist = result.stdout
        if isinstance(plist, bytes):
            xml_start = plist.find(b"<?xml")
            if xml_start == -1:
                xml_start = plist.find(b"<plist")
            if xml_start > 0:
                plist = plist[xml_start:]
            plist = plist.decode("utf-8", errors="replace")

    tmp = tempfile.NamedTemporaryFile(suffix=".plist", delete=False, mode="w")
    tmp.write(plist)
    tmp.close()
    return tmp.name


def main():
    print("=" * 60)
    print("Meetily Language Patch: auto-translate -> ru")
    print("=" * 60)

    if not os.path.exists(BINARY_PATH):
        print(f"ERROR: Meetily not found at {APP_PATH}")
        sys.exit(1)

    # Check if already patched
    with open(BINARY_PATH, "rb") as f:
        data = bytearray(f.read())

    if data.find(b"auto-translate") == -1:
        idx = data.find(b"ruto-translate")
        if idx != -1:
            print("Already patched! (found 'ruto-translate' in binary)")
            sys.exit(0)
        print("ERROR: Neither 'auto-translate' nor 'ruto-translate' found")
        sys.exit(1)

    print(f"[1/6] Binary found: {BINARY_PATH} ({len(data):,} bytes)")

    # Find string
    str_offset = find_string(data)
    print(f"[2/6] Found 'auto-translate' at offset 0x{str_offset:08x}")

    # Find MOV instruction
    text_vmaddr, text_fileoff, _, _ = get_text_segment_info(BINARY_PATH)
    mov_offsets = find_mov_w8_14(data, str_offset, text_vmaddr, text_fileoff)
    print(f"[3/6] Found MOV W8, #14 at offset(s): {', '.join(f'0x{o:08x}' for o in mov_offsets)}")

    # Kill running meetily
    print("[4/6] Stopping Meetily if running...")
    subprocess.run(["pkill", "-f", "meetily"], capture_output=True)
    import time; time.sleep(1)

    # Create backup
    backup_path = APP_PATH.rstrip("/") + "_pre_patch_backup.app"
    if not os.path.exists(backup_path):
        print(f"      Creating backup at {backup_path}")
        shutil.copytree(APP_PATH, backup_path)
    else:
        print(f"      Backup already exists at {backup_path}")

    # Apply patches
    print("[5/6] Applying patches...")

    # Patch 1: Change 'a' to 'r' in string
    assert data[str_offset] == ord('a'), f"Expected 'a' at offset, got {chr(data[str_offset])}"
    data[str_offset] = ord('r')
    print(f"      String: 'auto-translate' -> 'ruto-translate' (len will be 2, so reads as 'ru')")

    # Patch 2: Change MOV W8, #14 -> MOV W8, #2
    for mo in mov_offsets:
        struct.pack_into("<I", data, mo, 0x52800048)
        print(f"      MOV W8, #14 -> MOV W8, #2 at 0x{mo:08x}")

    with open(BINARY_PATH, "wb") as f:
        f.write(data)

    # Re-sign
    print("[6/6] Re-signing with ad-hoc signature...")
    ent_path = extract_entitlements(APP_PATH)
    subprocess.run(["codesign", "--remove-signature", APP_PATH], capture_output=True)
    result = subprocess.run(
        ["codesign", "--force", "--deep", "--sign", "-",
         "--entitlements", ent_path, APP_PATH],
        capture_output=True, text=True
    )
    os.unlink(ent_path)

    if result.returncode != 0:
        print(f"WARNING: Code signing failed: {result.stderr}")
    else:
        print("      Signed successfully")

    # Verify
    with open(BINARY_PATH, "rb") as f:
        verify = f.read()
    if b"auto-translate" not in verify and b"ruto-translate" in verify:
        print("\n" + "=" * 60)
        print("SUCCESS! Meetily will now default to Russian transcription.")
        print("No auto-translation. Setting persists across restarts.")
        print("=" * 60)
    else:
        print("\nWARNING: Verification failed — check manually")


if __name__ == "__main__":
    main()
PATCH_EOF

    python3 "$PATCH_TMP"
fi

# ─── Step 5: Final setup ────────────────────────────────────────────

step 5 "Setup complete!"

# Load LaunchAgent
launchctl load "$PLIST_DST"
info "LaunchAgent loaded: $LABEL"

# Verify
sleep 1
if launchctl list 2>/dev/null | grep -q "$LABEL"; then
    info "Agent is running"
else
    warn "Agent may not have started — check logs at $LOG_DIR/"
fi

echo ""
echo "========================================"
echo -e " ${YELLOW}ACTION REQUIRED: Add to Accessibility${NC}"
echo "========================================"
echo ""
echo "  System Settings -> Privacy & Security -> Accessibility"
echo "  Click + -> select: $APP_DIR"
echo ""

# Open System Settings to Accessibility pane
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true

echo "Logs:  tail -f $LOG_DIR/zoom-meetily-bridge.log"
echo ""
