#!/bin/bash
# sandbox-allowlist.sh — Append-only domain manager for Claude Code sandbox network allowlist
# Called by self-expansion after creating a new service registry.
# Usage:
#   sandbox-allowlist.sh add <domain>       # Add domain (idempotent)
#   sandbox-allowlist.sh list               # Print all allowed domains
#   sandbox-allowlist.sh has <domain>       # Exit 0 if present, 1 if not

set -euo pipefail

AUTOPILOT_DIR="${AUTOPILOT_DIR:-$HOME/MCPs/autopilot}"
SETTINGS_FILE="$AUTOPILOT_DIR/.claude/settings.json"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "$SETTINGS_FILE" ]] || die "Settings file not found: $SETTINGS_FILE"
command -v jq &>/dev/null || die "jq is required"

validate_domain() {
    local d="$1"
    # Allow optional leading wildcard (*.) then standard hostname segments
    [[ "$d" =~ ^(\*\.)?[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]] \
        || [[ "$d" == "localhost" ]] \
        || [[ "$d" == "127.0.0.1" ]]
}

cmd_has() {
    local domain="$1"
    jq -r '.sandbox.network.allowedDomains[]?' "$SETTINGS_FILE" | grep -qxF "$domain"
}

cmd_list() {
    jq -r '.sandbox.network.allowedDomains[]?' "$SETTINGS_FILE" | sort
}

cmd_add() {
    local domain="$1"
    validate_domain "$domain" || die "Invalid domain format: '$domain'"
    if cmd_has "$domain"; then
        echo "[allowlist] $domain already present (no change)"
        return 0
    fi
    local tmp
    tmp=$(mktemp)
    jq --arg d "$domain" '.sandbox.network.allowedDomains += [$d]' "$SETTINGS_FILE" > "$tmp" \
        && mv "$tmp" "$SETTINGS_FILE" \
        || { rm -f "$tmp"; die "Failed to update $SETTINGS_FILE"; }
    echo "[allowlist] Added $domain to sandbox network allowlist"
}

cmd="${1:-}" ; shift || true
case "$cmd" in
    add)  [[ -n "${1:-}" ]] || die "Usage: sandbox-allowlist.sh add <domain>"; cmd_add "$1" ;;
    list) cmd_list ;;
    has)  [[ -n "${1:-}" ]] || die "Usage: sandbox-allowlist.sh has <domain>"; cmd_has "$1" ;;
    *)    die "Unknown command: '$cmd'. Use: add | list | has" ;;
esac
