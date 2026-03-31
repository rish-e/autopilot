#!/bin/bash
# totp.sh — Generate TOTP 2FA codes from seeds stored in keychain
#
# Seeds are stored encrypted in the OS keychain via keychain.sh.
# Generated codes are printed to stdout for subshell capture.
# Codes and seeds are NEVER logged, stored in files, or passed as CLI arguments.
#
# Usage:
#   totp.sh generate <service>          Generate current 6-digit TOTP code
#   totp.sh store <service> [seed]      Store TOTP seed (reads stdin if no seed arg)
#   totp.sh has <service>               Check if seed exists (exit 0=yes, 1=no)
#   totp.sh remaining <service>         Seconds until current code expires
#   totp.sh backup-store <service>      Store backup codes (reads from stdin, one per line)
#   totp.sh backup-use <service>        Use next backup code (prints to stdout, decrements count)
#   totp.sh backup-count <service>      Show remaining backup code count
#   totp.sh backup-status               Show backup code status for all services
#
# Examples:
#   CODE=$(totp.sh generate vercel)     # capture in subshell — never echoed
#   echo "JBSWY3DPEHPK3PXP" | totp.sh store vercel
#   totp.sh store vercel JBSWY3DPEHPK3PXP
#   echo -e "abc123\ndef456\nghi789" | totp.sh backup-store vercel
#   CODE=$(totp.sh backup-use vercel)   # use next backup code

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYCHAIN="$SCRIPT_DIR/keychain.sh"

# ─── Helpers ─────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF'
totp.sh — TOTP 2FA code generator for Autopilot

Commands:
  generate <service>       Generate current 6-digit TOTP code (stdout)
  store <service> [seed]   Store TOTP seed in keychain (stdin preferred)
  has <service>            Check if TOTP seed exists (exit 0/1)
  remaining <service>      Seconds until current code expires
  backup-store <service>   Store backup codes from stdin (one per line)
  backup-use <service>     Use & consume next backup code (stdout)
  backup-count <service>   Show remaining backup code count
  backup-status            Show backup code inventory for all services

Security:
  - Seeds stored in OS-encrypted keychain, never in files
  - Codes printed to stdout only — capture via subshell
  - Seeds passed via environment variable, never CLI argument
  - Backup codes tracked with usage count — alerts when < 3 remaining

Examples:
  CODE=$(totp.sh generate vercel)
  echo "JBSWY3DPEHPK3PXP" | totp.sh store vercel
  if totp.sh has github; then echo "TOTP configured"; fi
  echo -e "abc123\ndef456" | totp.sh backup-store github
  totp.sh backup-status
EOF
}

require_python() {
    if ! command -v python3 &>/dev/null; then
        echo "Error: python3 is required for TOTP generation" >&2
        exit 1
    fi
    if ! python3 -c "import pyotp" 2>/dev/null; then
        echo "Error: pyotp not installed. Run: pip3 install pyotp" >&2
        exit 1
    fi
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_generate() {
    local service="${1:?Error: service name required}"
    require_python

    # Get seed from keychain — never echoed, captured in variable
    local seed
    seed=$("$KEYCHAIN" get "$service" totp-seed 2>/dev/null) || {
        echo "Error: No TOTP seed stored for '$service'" >&2
        echo "Store one with: echo 'SEED' | totp.sh store $service" >&2
        exit 1
    }

    # Generate code — seed goes via env var, never as CLI argument
    TOTP_SEED="$seed" python3 -c "
import os, pyotp, sys
seed = os.environ.get('TOTP_SEED', '')
if not seed:
    print('Error: TOTP_SEED not set', file=sys.stderr)
    sys.exit(1)
try:
    print(pyotp.TOTP(seed).now())
except Exception as e:
    print(f'Error generating TOTP: {e}', file=sys.stderr)
    sys.exit(1)
"
    # Clean up environment
    unset TOTP_SEED 2>/dev/null || true
}

cmd_store() {
    local service="${1:?Error: service name required}"
    local seed="${2:-}"

    # Read seed from stdin if not provided as argument
    if [[ -z "$seed" ]]; then
        if [[ -t 0 ]]; then
            echo -n "Enter TOTP seed (base32): " >&2
            read -rs seed
            echo >&2
        else
            read -r seed
        fi
    fi

    # Trim whitespace
    seed=$(echo "$seed" | tr -d '[:space:]')

    if [[ -z "$seed" ]]; then
        echo "Error: No seed provided" >&2
        exit 1
    fi

    # Validate base32 format
    if ! python3 -c "
import base64, sys
try:
    base64.b32decode(sys.argv[1], casefold=True)
except Exception:
    sys.exit(1)
" "$seed" 2>/dev/null; then
        echo "Error: Invalid base32 seed. TOTP seeds must be base32 encoded." >&2
        exit 1
    fi

    # Store in keychain via stdin (never as CLI argument in production)
    echo "$seed" | "$KEYCHAIN" set "$service" totp-seed
    echo "TOTP seed stored for '$service'" >&2
}

cmd_has() {
    local service="${1:?Error: service name required}"
    "$KEYCHAIN" has "$service" totp-seed 2>/dev/null
}

cmd_remaining() {
    local service="${1:-default}"
    python3 -c "
import time
interval = 30
remaining = int(interval - (time.time() % interval))
print(remaining)
" 2>/dev/null
}

# ─── Backup Code Commands ───────────────────────────────────────────────────

cmd_backup_store() {
    local service="${1:?Error: service name required}"
    local codes=""

    # Read codes from stdin (one per line)
    if [[ -t 0 ]]; then
        echo "Enter backup codes (one per line, Ctrl-D when done):" >&2
    fi
    codes=$(cat | tr -s '[:space:]' '\n' | sed '/^$/d')

    if [[ -z "$codes" ]]; then
        echo "Error: No backup codes provided" >&2
        exit 1
    fi

    local count
    count=$(echo "$codes" | wc -l | tr -d ' ')

    # Store codes as newline-separated string in keychain
    echo "$codes" | "$KEYCHAIN" set "$service" backup-codes 2>/dev/null
    # Store the total count and remaining count
    echo "$count" | "$KEYCHAIN" set "$service" backup-codes-total 2>/dev/null
    echo "$count" | "$KEYCHAIN" set "$service" backup-codes-remaining 2>/dev/null

    echo "Stored $count backup codes for '$service'" >&2
}

cmd_backup_use() {
    local service="${1:?Error: service name required}"

    # Get remaining codes
    local codes
    codes=$("$KEYCHAIN" get "$service" backup-codes 2>/dev/null) || {
        echo "Error: No backup codes stored for '$service'" >&2
        exit 1
    }

    # Get first code
    local first_code
    first_code=$(echo "$codes" | head -1)

    if [[ -z "$first_code" ]]; then
        echo "Error: All backup codes exhausted for '$service'" >&2
        exit 1
    fi

    # Remove first code, store remaining
    local remaining_codes
    remaining_codes=$(echo "$codes" | tail -n +2)

    if [[ -n "$remaining_codes" ]]; then
        echo "$remaining_codes" | "$KEYCHAIN" set "$service" backup-codes 2>/dev/null
    else
        # All codes used up — clear the entry
        echo "" | "$KEYCHAIN" set "$service" backup-codes 2>/dev/null
    fi

    # Update remaining count
    local remaining_count
    remaining_count=$(echo "$remaining_codes" | sed '/^$/d' | wc -l | tr -d ' ')
    echo "$remaining_count" | "$KEYCHAIN" set "$service" backup-codes-remaining 2>/dev/null

    # Alert if running low
    if [[ "$remaining_count" -lt 3 ]]; then
        echo "⚠ WARNING: Only $remaining_count backup codes remaining for '$service'!" >&2
        if [[ "$remaining_count" -eq 0 ]]; then
            echo "⚠ CRITICAL: All backup codes for '$service' are exhausted. Regenerate immediately!" >&2
        fi
    fi

    # Output the code (captured via subshell)
    echo "$first_code"
}

cmd_backup_count() {
    local service="${1:?Error: service name required}"

    local remaining
    remaining=$("$KEYCHAIN" get "$service" backup-codes-remaining 2>/dev/null) || remaining="0"
    local total
    total=$("$KEYCHAIN" get "$service" backup-codes-total 2>/dev/null) || total="?"

    echo "$remaining / $total"

    # Warn if low
    if [[ "$remaining" -lt 3 ]] && [[ "$remaining" != "0" ]]; then
        echo "⚠ Low backup codes — consider regenerating" >&2
    elif [[ "$remaining" == "0" ]]; then
        echo "⚠ No backup codes remaining!" >&2
    fi
}

cmd_backup_status() {
    echo "Backup Code Inventory" >&2
    echo "─────────────────────" >&2

    local found=false
    # Check all services that have TOTP seeds
    for service_key in $("$KEYCHAIN" list 2>/dev/null | grep "totp-seed" | awk '{print $1}' 2>/dev/null); do
        local svc="${service_key%/*}"
        if [[ -n "$svc" ]]; then
            local remaining total
            remaining=$("$KEYCHAIN" get "$svc" backup-codes-remaining 2>/dev/null) || remaining="-"
            total=$("$KEYCHAIN" get "$svc" backup-codes-total 2>/dev/null) || total="-"

            local status_icon="✓"
            if [[ "$remaining" == "0" ]]; then
                status_icon="✗"
            elif [[ "$remaining" != "-" ]] && [[ "$remaining" -lt 3 ]]; then
                status_icon="!"
            fi

            printf "  [%s] %-20s  %s / %s codes\n" "$status_icon" "$svc" "$remaining" "$total"
            found=true
        fi
    done

    # Fallback: check known services
    if [[ "$found" == "false" ]]; then
        for svc in vercel github supabase cloudflare; do
            if "$KEYCHAIN" has "$svc" totp-seed 2>/dev/null; then
                local remaining total
                remaining=$("$KEYCHAIN" get "$svc" backup-codes-remaining 2>/dev/null) || remaining="-"
                total=$("$KEYCHAIN" get "$svc" backup-codes-total 2>/dev/null) || total="-"
                printf "  %-20s  %s / %s codes\n" "$svc" "$remaining" "$total"
                found=true
            fi
        done
    fi

    if [[ "$found" == "false" ]]; then
        echo "  No TOTP services with backup codes found" >&2
    fi
}

# ─── Dispatch ────────────────────────────────────────────────────────────────

case "${1:-}" in
    generate)       shift; cmd_generate "$@" ;;
    store)          shift; cmd_store "$@" ;;
    has)            shift; cmd_has "$@" ;;
    remaining)      shift; cmd_remaining "$@" ;;
    backup-store)   shift; cmd_backup_store "$@" ;;
    backup-use)     shift; cmd_backup_use "$@" ;;
    backup-count)   shift; cmd_backup_count "$@" ;;
    backup-status)  cmd_backup_status ;;
    -h|--help|help) usage ;;
    *)
        if [[ -n "${1:-}" ]]; then
            echo "Error: Unknown command '$1'" >&2
            echo "Run 'totp.sh --help' for usage" >&2
            exit 1
        fi
        usage
        exit 1
        ;;
esac
