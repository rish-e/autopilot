#!/bin/bash
# preflight.sh — First-run credential gate for Autopilot
#
# Ensures primary credentials (email + password) are configured before
# the agent attempts any login or signup. Prevents the agent from using
# random/fabricated credentials on first run.
#
# Usage:
#   preflight.sh              # Check if primary credentials are set (exit 0/1)
#   preflight.sh setup        # Interactively prompt for and store credentials
#   preflight.sh status       # Show what's configured (without revealing values)
#
# Location: ~/MCPs/autopilot/bin/preflight.sh

set -euo pipefail

KEYCHAIN="$HOME/MCPs/autopilot/bin/keychain.sh"

# ─── Helper ──────────────────────────────────────────────────────────────────

has_email() {
  "$KEYCHAIN" has primary email 2>/dev/null
}

has_password() {
  "$KEYCHAIN" has primary password 2>/dev/null
}

# ─── Subcommands ─────────────────────────────────────────────────────────────

cmd_check() {
  local missing=0

  if ! has_email; then
    missing=1
  fi

  if ! has_password; then
    missing=1
  fi

  if [ "$missing" -eq 1 ]; then
    echo "Primary credentials not configured. Run: autopilot setup"
    echo "  Or run: ~/MCPs/autopilot/bin/preflight.sh setup"
    exit 1
  fi

  # Both set — exit silently
  exit 0
}

cmd_setup() {
  echo "═══════════════════════════════════════════════════════"
  echo "  Autopilot — Primary Credential Setup"
  echo "═══════════════════════════════════════════════════════"
  echo ""
  echo "These credentials are used as the default identity when"
  echo "signing up or logging into any external service."
  echo "They are stored securely in your macOS Keychain."
  echo ""

  # Email
  if has_email; then
    echo "[✓] Primary email is already set."
  else
    read -rp "Enter your primary email: " email
    if [ -z "$email" ]; then
      echo "Error: Email cannot be empty."
      exit 1
    fi
    echo "$email" | "$KEYCHAIN" set primary email
    echo "[✓] Primary email stored in Keychain."
  fi

  # Password
  if has_password; then
    echo "[✓] Primary password is already set."
  else
    read -rsp "Enter your primary password: " password
    echo ""
    if [ -z "$password" ]; then
      echo "Error: Password cannot be empty."
      exit 1
    fi
    echo "$password" | "$KEYCHAIN" set primary password
    echo "[✓] Primary password stored in Keychain."
  fi

  echo ""
  echo "Primary credentials configured. Autopilot is ready."
}

cmd_status() {
  echo "Autopilot Credential Status"
  echo "───────────────────────────"

  if has_email; then
    echo "  Primary email:    [SET]"
  else
    echo "  Primary email:    [NOT SET]"
  fi

  if has_password; then
    echo "  Primary password: [SET]"
  else
    echo "  Primary password: [NOT SET]"
  fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
  setup)
    cmd_setup
    ;;
  status)
    cmd_status
    ;;
  *)
    cmd_check
    ;;
esac
