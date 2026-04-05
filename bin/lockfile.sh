#!/bin/bash
# lockfile.sh — File-based lock coordination for parallel Autopilot agents
# Prevents race conditions when multiple subagents touch shared resources.
#
# Usage:
#   lockfile.sh acquire <name> [timeout_s]   Acquire lock, block if held (default: 30s timeout)
#   lockfile.sh release <name>               Release a lock you hold
#   lockfile.sh check <name>                 Exit 0 if free, exit 1 if held
#   lockfile.sh list                         Show all active locks
#   lockfile.sh clean                        Remove stale locks (dead PIDs)
#   lockfile.sh clean-all                    Remove ALL locks (emergency reset)

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Find project root ──────────────────────────────────────────────────────

find_project_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.autopilot" ]; then
            echo "$dir"
            return 0
        fi
        if [ -d "$dir/.git" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    case "$1" in
        /|/usr|/var|/etc|/tmp|/opt|/bin|/sbin|/lib)
            echo "ERROR: No project root found from $1 — run from a project directory" >&2
            exit 1
            ;;
    esac
    echo "$1"
}

PROJECT_ROOT=$(find_project_root "$(pwd)")
LOCK_DIR="$PROJECT_ROOT/.autopilot/locks"

# ─── Helpers ─────────────────────────────────────────────────────────────────

ensure_lock_dir() {
    mkdir -p "$LOCK_DIR"
}

get_lock_path() {
    local name="$1"
    echo "$LOCK_DIR/${name}.lock"
}

validate_lock_name() {
    local name="$1"
    if [ -z "$name" ]; then
        echo -e "${RED}ERROR: Lock name is required.${NC}" >&2
        exit 1
    fi
    # Only allow alphanumeric, hyphens, underscores, and dots
    if ! echo "$name" | grep -qE '^[a-zA-Z0-9._-]+$'; then
        echo -e "${RED}ERROR: Invalid lock name '$name'. Use only alphanumeric, hyphens, underscores, dots.${NC}" >&2
        exit 1
    fi
}

is_pid_alive() {
    local pid="$1"
    if [ -z "$pid" ] || [ "$pid" = "0" ]; then
        return 1
    fi
    kill -0 "$pid" 2>/dev/null
}

read_lock_info() {
    local lock_file="$1"
    if [ ! -f "$lock_file" ]; then
        return 1
    fi
    # Lock file format: PID on line 1, timestamp on line 2, holder description on line 3
    local pid timestamp holder
    pid=$(sed -n '1p' "$lock_file" 2>/dev/null || echo "")
    timestamp=$(sed -n '2p' "$lock_file" 2>/dev/null || echo "")
    holder=$(sed -n '3p' "$lock_file" 2>/dev/null || echo "unknown")
    echo "$pid|$timestamp|$holder"
}

get_iso_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_acquire() {
    local name="$1"
    local timeout="${2:-30}"
    validate_lock_name "$name"
    ensure_lock_dir

    local lock_file
    lock_file=$(get_lock_path "$name")
    local my_pid=$$
    local elapsed=0
    local poll_interval=1

    while true; do
        # Try to detect and clean stale lock first
        if [ -f "$lock_file" ]; then
            local info
            info=$(read_lock_info "$lock_file") || true
            local existing_pid
            existing_pid=$(echo "$info" | cut -d'|' -f1)

            if [ -n "$existing_pid" ] && ! is_pid_alive "$existing_pid"; then
                # Stale lock — owner is dead. Remove it.
                rm -f "$lock_file"
                echo -e "${DIM}Cleaned stale lock '$name' (PID $existing_pid dead)${NC}" >&2
            fi
        fi

        # Attempt atomic lock acquisition using mkdir (atomic on all filesystems)
        # We use a .acquiring dir as the atomic gate, then write the lock file
        local gate="${lock_file}.acquiring"
        if mkdir "$gate" 2>/dev/null; then
            # We won the race. Write lock file and remove gate.
            {
                echo "$my_pid"
                echo "$(get_iso_timestamp)"
                echo "PID $my_pid"
            } > "$lock_file"
            rmdir "$gate"
            echo -e "${GREEN}Lock acquired:${NC} $name (PID $my_pid)"
            return 0
        fi

        # Lock is held by someone else. Remove gate if it was left by a dead process.
        if [ -d "$gate" ]; then
            # Gate dir exists but we couldn't create it — someone else is acquiring.
            # Brief wait, then check if they finished.
            sleep 0.1
            # If gate is still there after 2 seconds, it's stale (acquirer died)
            if [ -d "$gate" ] && [ "$elapsed" -gt 0 ]; then
                rmdir "$gate" 2>/dev/null || true
            fi
        fi

        # Check timeout
        if [ "$elapsed" -ge "$timeout" ]; then
            local info
            info=$(read_lock_info "$lock_file") || true
            local holder_pid
            holder_pid=$(echo "$info" | cut -d'|' -f1)
            local holder_time
            holder_time=$(echo "$info" | cut -d'|' -f2)
            echo -e "${RED}TIMEOUT: Could not acquire lock '$name' after ${timeout}s.${NC}" >&2
            echo -e "${RED}Held by PID $holder_pid since $holder_time${NC}" >&2
            exit 1
        fi

        # Wait and retry
        if [ "$elapsed" -eq 0 ]; then
            echo -e "${YELLOW}Waiting for lock '$name'...${NC}" >&2
        fi
        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done
}

cmd_release() {
    local name="$1"
    validate_lock_name "$name"

    local lock_file
    lock_file=$(get_lock_path "$name")

    if [ ! -f "$lock_file" ]; then
        echo -e "${DIM}Lock '$name' is not held.${NC}"
        return 0
    fi

    # Verify we own the lock (or allow release by any process for recovery)
    local info
    info=$(read_lock_info "$lock_file") || true
    local lock_pid
    lock_pid=$(echo "$info" | cut -d'|' -f1)

    if [ "$lock_pid" != "$$" ]; then
        # Not our lock, but allow release with a warning (needed for recovery flows)
        echo -e "${YELLOW}WARNING: Releasing lock '$name' held by PID $lock_pid (we are PID $$).${NC}" >&2
    fi

    rm -f "$lock_file"
    echo -e "${GREEN}Lock released:${NC} $name"
}

cmd_check() {
    local name="$1"
    validate_lock_name "$name"

    local lock_file
    lock_file=$(get_lock_path "$name")

    if [ ! -f "$lock_file" ]; then
        echo -e "${GREEN}FREE${NC}: $name"
        exit 0
    fi

    # Check for stale lock
    local info
    info=$(read_lock_info "$lock_file") || true
    local lock_pid
    lock_pid=$(echo "$info" | cut -d'|' -f1)
    local lock_time
    lock_time=$(echo "$info" | cut -d'|' -f2)

    if [ -n "$lock_pid" ] && ! is_pid_alive "$lock_pid"; then
        echo -e "${YELLOW}STALE${NC}: $name (PID $lock_pid dead, acquired $lock_time)"
        exit 1
    fi

    echo -e "${RED}HELD${NC}: $name (PID $lock_pid, acquired $lock_time)"
    exit 1
}

cmd_list() {
    ensure_lock_dir

    local lock_files
    lock_files=$(find "$LOCK_DIR" -name "*.lock" -type f 2>/dev/null || true)

    if [ -z "$lock_files" ]; then
        echo -e "${DIM}No active locks.${NC}"
        return 0
    fi

    local active_count=0
    local stale_count=0

    echo -e "${BOLD}Active Locks${NC}"
    echo -e "${BOLD}$(printf '%-20s %-8s %-24s %s' 'NAME' 'PID' 'ACQUIRED' 'STATUS')${NC}"
    echo "──────────────────────────────────────────────────────────────────"

    while IFS= read -r lock_file; do
        local name
        name=$(basename "$lock_file" .lock)
        local info
        info=$(read_lock_info "$lock_file") || true
        local pid
        pid=$(echo "$info" | cut -d'|' -f1)
        local timestamp
        timestamp=$(echo "$info" | cut -d'|' -f2)

        local status
        if [ -n "$pid" ] && is_pid_alive "$pid"; then
            status="${GREEN}active${NC}"
            active_count=$((active_count + 1))
        else
            status="${YELLOW}stale${NC}"
            stale_count=$((stale_count + 1))
        fi

        printf "%-20s %-8s %-24s " "$name" "$pid" "$timestamp"
        echo -e "$status"
    done <<< "$lock_files"

    echo ""
    echo -e "  ${GREEN}Active:${NC} $active_count  ${YELLOW}Stale:${NC} $stale_count"

    if [ "$stale_count" -gt 0 ]; then
        echo -e "  ${DIM}Run 'lockfile.sh clean' to remove stale locks.${NC}"
    fi
}

cmd_clean() {
    ensure_lock_dir

    local lock_files
    lock_files=$(find "$LOCK_DIR" -name "*.lock" -type f 2>/dev/null || true)

    if [ -z "$lock_files" ]; then
        echo -e "${DIM}No locks to clean.${NC}"
        return 0
    fi

    local cleaned=0
    local kept=0

    while IFS= read -r lock_file; do
        local name
        name=$(basename "$lock_file" .lock)
        local info
        info=$(read_lock_info "$lock_file") || true
        local pid
        pid=$(echo "$info" | cut -d'|' -f1)

        if [ -z "$pid" ] || ! is_pid_alive "$pid"; then
            rm -f "$lock_file"
            echo -e "  ${YELLOW}Removed stale lock:${NC} $name (PID ${pid:-unknown})"
            cleaned=$((cleaned + 1))
        else
            kept=$((kept + 1))
        fi
    done <<< "$lock_files"

    # Also clean up any stale .acquiring directories
    local gates
    gates=$(find "$LOCK_DIR" -name "*.acquiring" -type d 2>/dev/null || true)
    if [ -n "$gates" ]; then
        while IFS= read -r gate; do
            rmdir "$gate" 2>/dev/null || true
        done <<< "$gates"
    fi

    echo -e "${GREEN}Cleaned:${NC} $cleaned stale  ${DIM}Kept:${NC} $kept active"
}

cmd_clean_all() {
    ensure_lock_dir

    local count
    count=$(find "$LOCK_DIR" -name "*.lock" -type f 2>/dev/null | wc -l | tr -d ' ')

    if [ "$count" -eq 0 ]; then
        echo -e "${DIM}No locks to remove.${NC}"
        return 0
    fi

    find "$LOCK_DIR" -name "*.lock" -type f -delete 2>/dev/null || true
    find "$LOCK_DIR" -name "*.acquiring" -type d -exec rmdir {} + 2>/dev/null || true

    echo -e "${YELLOW}Removed ALL locks:${NC} $count cleared"
    echo -e "${DIM}Use this only for emergency recovery.${NC}"
}

cmd_help() {
    echo -e "${BOLD}lockfile.sh${NC} — Lock coordination for parallel Autopilot agents"
    echo ""
    echo "Usage:"
    echo "  lockfile.sh acquire <name> [timeout_s]   Acquire lock (default: 30s timeout)"
    echo "  lockfile.sh release <name>               Release a lock"
    echo "  lockfile.sh check <name>                 Check if lock is free (exit 0) or held (exit 1)"
    echo "  lockfile.sh list                         Show all active locks"
    echo "  lockfile.sh clean                        Remove stale locks (dead PIDs)"
    echo "  lockfile.sh clean-all                    Remove ALL locks (emergency)"
    echo ""
    echo "Lock files stored at: $LOCK_DIR/<name>.lock"
    echo ""
    echo "Common lock names:"
    echo "  env-file          .env / .env.local modifications"
    echo "  package-json      package.json or npm install"
    echo "  vercel-config     vercel.json or vercel link"
    echo "  supabase-config   supabase/config.toml or supabase init"
    echo "  git-operations    git commit, push, branch"
    echo "  browser-session   Playwright browser automation"
    echo "  keychain-write    Keychain credential writes"
}

# ─── Main ────────────────────────────────────────────────────────────────────

COMMAND="${1:-help}"

case "$COMMAND" in
    acquire)    cmd_acquire "${2:-}" "${3:-30}" ;;
    release)    cmd_release "${2:-}" ;;
    check)      cmd_check "${2:-}" ;;
    list)       cmd_list ;;
    clean)      cmd_clean ;;
    clean-all)  cmd_clean_all ;;
    help|--help|-h) cmd_help ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        cmd_help
        exit 1
        ;;
esac
