#!/bin/bash
# osascript.sh — Safe AppleScript runner for Autopilot (macOS only)
#
# Wraps osascript with macOS check, whitelist enforcement,
# timeout support, and structured error handling.
#
# Usage:
#   osascript.sh run <script-name> [arg1 arg2 ...]   # name without .applescript ext
#   osascript.sh info                                 # OS and permission status
#
# Exit codes:
#   0  — success
#   1  — script error (stderr has details)
#   2  — permission denied (-1743 / not authorized)
#   3  — timeout
#   4  — not macOS
#   5  — bad usage

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOPILOT_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPTS_DIR="$AUTOPILOT_DIR/applescripts"
LOG_FILE=""
TIMEOUT_SECS=30

# ─── macOS check ─────────────────────────────────────────────────────────────

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: osascript.sh requires macOS. GUI automation is not available on this platform." >&2
    echo "PLATFORM_UNSUPPORTED" >&2
    exit 4
fi

# ─── Helpers ─────────────────────────────────────────────────────────────────

log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%H:%M:%S')
    echo "[$ts] [osascript] [$level] $msg" >&2
    if [ -n "$LOG_FILE" ] && [ -d "$(dirname "$LOG_FILE")" ]; then
        echo "[$ts] [osascript] [$level] $msg" >> "$LOG_FILE"
    fi
}

parse_error() {
    local stderr_output="$1"
    # Detect common AppleScript errors and return a structured message
    if echo "$stderr_output" | grep -q "execution error:.*-1743\|Not authorized to send Apple events"; then
        echo "PERMISSION_DENIED: Automation permission not granted. Go to System Settings → Privacy & Security → Automation and allow Terminal (or Claude Code) to control the target app."
        return 2
    fi
    if echo "$stderr_output" | grep -q "execution error:.*-1728\|Can't get"; then
        echo "NOT_FOUND: AppleScript could not find the target element. App may not be running or the UI element doesn't exist."
        return 1
    fi
    if echo "$stderr_output" | grep -q "execution error:.*-25211\|Accessibility access"; then
        echo "ACCESSIBILITY_DENIED: Accessibility permission not granted. Go to System Settings → Privacy & Security → Accessibility and allow Terminal (or Claude Code)."
        return 2
    fi
    if echo "$stderr_output" | grep -q "execution error:.*-609\|Connection is invalid"; then
        echo "APP_NOT_RUNNING: The target application is not running."
        return 1
    fi
    if echo "$stderr_output" | grep -q "do shell script"; then
        echo "BLOCKED: 'do shell script' is not allowed in autopilot AppleScripts."
        return 1
    fi
    # Generic error
    echo "SCRIPT_ERROR: $stderr_output"
    return 1
}

# ─── Commands ─────────────────────────────────────────────────────────────────

cmd_info() {
    echo "=== osascript.sh info ==="
    echo "macOS version: $(sw_vers -productVersion)"
    echo "AppleScript available: $(command -v osascript &>/dev/null && echo yes || echo no)"
    echo "Scripts directory: $SCRIPTS_DIR"
    echo ""
    echo "Available scripts:"
    if [ -d "$SCRIPTS_DIR" ]; then
        for f in "$SCRIPTS_DIR"/*.applescript; do
            [ -f "$f" ] && echo "  $(basename "$f" .applescript)"
        done
    else
        echo "  (none — $SCRIPTS_DIR does not exist)"
    fi
    echo ""

    # Check accessibility permission (will fail gracefully if not granted)
    local ax_status
    ax_status=$(osascript -e 'tell application "System Events" to return name of first application process whose frontmost is true' 2>&1) || true
    if echo "$ax_status" | grep -q "execution error\|not authorized\|Accessibility"; then
        echo "Accessibility permission: DENIED — grant in System Settings → Privacy & Security → Accessibility"
    else
        echo "Accessibility permission: OK"
    fi
}

cmd_run() {
    local script_name="${1:-}"
    if [ -z "$script_name" ]; then
        echo "Usage: osascript.sh run <script-name> [args...]" >&2
        exit 5
    fi
    shift

    # Strip .applescript extension if provided
    script_name="${script_name%.applescript}"

    local script_path="$SCRIPTS_DIR/${script_name}.applescript"

    # Whitelist: reject names containing path separators or traversal sequences
    if [[ "$script_name" == *"/"* ]] || [[ "$script_name" == *".."* ]]; then
        log "ERROR" "Blocked path traversal attempt: $script_name"
        echo "BLOCKED: Script name must be a simple filename with no path separators. Use: osascript.sh run <name>" >&2
        exit 5
    fi

    if [ ! -f "$script_path" ]; then
        log "ERROR" "Script not found: $script_path"
        echo "NOT_FOUND: Script '$script_name' does not exist in $SCRIPTS_DIR" >&2
        echo "Run 'osascript.sh info' to see available scripts." >&2
        exit 1
    fi

    log "INFO" "Running: $script_name $*"

    # Run with timeout
    local stderr_file
    stderr_file=$(mktemp /tmp/osascript-stderr.XXXXXX)
    local stdout_file
    stdout_file=$(mktemp /tmp/osascript-stdout.XXXXXX)

    local exit_code=0
    if command -v timeout &>/dev/null; then
        timeout "$TIMEOUT_SECS" osascript "$script_path" "$@" >"$stdout_file" 2>"$stderr_file" || exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log "ERROR" "Script timed out after ${TIMEOUT_SECS}s: $script_name"
            echo "TIMEOUT: Script '$script_name' exceeded ${TIMEOUT_SECS}s timeout" >&2
            rm -f "$stderr_file" "$stdout_file"
            exit 3
        fi
    else
        # macOS: no GNU timeout — use background process + wait
        osascript "$script_path" "$@" >"$stdout_file" 2>"$stderr_file" &
        local pid=$!
        local elapsed=0
        while kill -0 "$pid" 2>/dev/null; do
            sleep 1
            elapsed=$((elapsed + 1))
            if [ $elapsed -ge "$TIMEOUT_SECS" ]; then
                kill "$pid" 2>/dev/null || true
                log "ERROR" "Script timed out after ${TIMEOUT_SECS}s: $script_name"
                echo "TIMEOUT: Script '$script_name' exceeded ${TIMEOUT_SECS}s timeout" >&2
                rm -f "$stderr_file" "$stdout_file"
                exit 3
            fi
        done
        wait "$pid" || exit_code=$?
    fi

    local stdout_content
    stdout_content=$(cat "$stdout_file")
    local stderr_content
    stderr_content=$(cat "$stderr_file")

    rm -f "$stderr_file" "$stdout_file"

    if [ $exit_code -ne 0 ] || [ -n "$stderr_content" ]; then
        local parsed_error
        # Capture exit code from parse_error without || true swallowing it
        parsed_error=$(parse_error "$stderr_content")
        local parse_exit=$?
        log "ERROR" "$parsed_error"
        echo "$parsed_error" >&2
        # Print stdout anyway (may have partial output)
        [ -n "$stdout_content" ] && echo "$stdout_content"
        exit $parse_exit
    fi

    log "INFO" "Success: $script_name"
    echo "$stdout_content"
    exit 0
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

SUBCOMMAND="${1:-help}"
shift 2>/dev/null || true

case "$SUBCOMMAND" in
    run)   cmd_run "$@" ;;
    info)  cmd_info ;;
    help|--help|-h)
        echo "Usage: osascript.sh <command> [args]"
        echo ""
        echo "Commands:"
        echo "  run <name> [args...]   Run an AppleScript from ~/MCPs/autopilot/applescripts/"
        echo "  info                   Show OS info, permission status, and available scripts"
        echo ""
        echo "Exit codes: 0=ok, 1=script error, 2=permission denied, 3=timeout, 4=not macOS, 5=bad usage"
        ;;
    *)
        echo "Unknown command: $SUBCOMMAND. Use 'osascript.sh help'." >&2
        exit 5
        ;;
esac
