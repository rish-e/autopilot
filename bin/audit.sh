#!/bin/bash
# audit.sh — Structured audit log for Claude Code Autopilot
#
# JSONL-based append-only audit log with SHA-256 hash chain for tamper detection.
# Each entry is a single JSON line with a hash linking to the previous entry.
#
# Usage:
#   audit.sh log <action> [options]     Append an audit entry
#   audit.sh show [N]                   Show last N entries (default: 20)
#   audit.sh search <term>              Search across all entries
#   audit.sh accounts                   Show credential/account activity
#   audit.sh failures                   Show failed actions
#   audit.sh summary                    Per-session summary
#   audit.sh verify                     Verify hash chain integrity
#   audit.sh export [format]            Export as markdown or CSV
#   --path <dir>                        Specify project path manually

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Parse flags ─────────────────────────────────────────────────────────────

PROJECT_PATH=""
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            PROJECT_PATH="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

set -- "${ARGS[@]+"${ARGS[@]}"}"

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
    return 1
}

resolve_log_file() {
    if [ -n "$PROJECT_PATH" ]; then
        ROOT="$PROJECT_PATH"
    elif ROOT=$(find_project_root "$(pwd)"); then
        true
    else
        echo -e "${RED}No .autopilot/ directory found.${NC} Searched from $(pwd) upward."
        echo "Use --path <dir> to specify the project directory."
        exit 1
    fi

    AUDIT_DIR="$ROOT/.autopilot"
    mkdir -p "$AUDIT_DIR"
    AUDIT_FILE="$AUDIT_DIR/audit.jsonl"
    # Also maintain legacy log.md for backward compatibility
    LEGACY_LOG="$AUDIT_DIR/log.md"
}

AUDIT_FILE=""
AUDIT_DIR=""
LEGACY_LOG=""
ROOT=""

# ─── Hash Chain ──────────────────────────────────────────────────────────────

get_last_hash() {
    if [ -f "$AUDIT_FILE" ] && [ -s "$AUDIT_FILE" ]; then
        tail -1 "$AUDIT_FILE" | shasum -a 256 | cut -d' ' -f1
    else
        echo "0000000000000000000000000000000000000000000000000000000000000000"
    fi
}

# ─── Log Command ─────────────────────────────────────────────────────────────

cmd_log() {
    # Usage: audit.sh log <action> --level <N> --service <svc> --result <result> [--session <id>] [--detail <text>]
    local action="" level="" service="" result="" session="" detail=""

    # First positional arg is the action
    if [ $# -gt 0 ] && [[ ! "$1" == --* ]]; then
        action="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --level)   level="$2";   shift 2 ;;
            --service) service="$2"; shift 2 ;;
            --result)  result="$2";  shift 2 ;;
            --session) session="$2"; shift 2 ;;
            --detail)  detail="$2";  shift 2 ;;
            *) shift ;;
        esac
    done

    if [ -z "$action" ]; then
        echo "ERROR: audit.sh log requires an action" >&2
        echo "Usage: audit.sh log <action> --level <N> --service <svc> --result <result>" >&2
        exit 1
    fi

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local prev_hash
    prev_hash=$(get_last_hash)

    # Build JSON entry
    local entry
    entry=$(jq -n -c \
        --arg ts "$timestamp" \
        --arg act "$action" \
        --arg lvl "${level:-0}" \
        --arg svc "${service:-}" \
        --arg res "${result:-done}" \
        --arg sess "${session:-}" \
        --arg det "${detail:-}" \
        --arg prev "$prev_hash" \
        '{
            timestamp: $ts,
            action: $act,
            level: ($lvl | tonumber),
            service: $svc,
            result: $res,
            session: $sess,
            detail: $det,
            prev_hash: $prev
        } | with_entries(select(.value != "" and .value != 0))')

    # Append atomically
    echo "$entry" >> "$AUDIT_FILE"

    # Also append to legacy markdown log for backward compat
    local seq
    seq=$(wc -l < "$AUDIT_FILE" | tr -d ' ')
    local time_short
    time_short=$(date '+%H:%M')

    # Ensure legacy log exists with header if this is first entry in session
    if [ -n "$session" ] && [ ! -f "$LEGACY_LOG" ]; then
        {
            echo "## Session: $(date '+%Y-%m-%d %H:%M') — $session"
            echo ""
            echo "| # | Time | Action | Level | Service | Result |"
            echo "|---|------|--------|-------|---------|--------|"
        } >> "$LEGACY_LOG"
    fi

    if [ -f "$LEGACY_LOG" ]; then
        echo "| $seq | $time_short | $action | L${level:-0} | ${service:-—} | ${result:-done} |" >> "$LEGACY_LOG"
    fi
}

# ─── Display Helpers ─────────────────────────────────────────────────────────

format_entry() {
    local json="$1"
    local ts act lvl svc res det
    ts=$(echo "$json" | jq -r '.timestamp // ""')
    act=$(echo "$json" | jq -r '.action // ""')
    lvl=$(echo "$json" | jq -r '.level // 0')
    svc=$(echo "$json" | jq -r '.service // "—"')
    res=$(echo "$json" | jq -r '.result // "done"')
    det=$(echo "$json" | jq -r '.detail // ""')

    # Format timestamp to local short form
    local time_short
    if [ -n "$ts" ]; then
        time_short=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" '+%H:%M' 2>/dev/null || echo "${ts:11:5}")
    else
        time_short="??:??"
    fi

    local color="$NC"
    case "$res" in
        *FAILED*|*failed*|*error*)  color="$RED" ;;
        *ACCOUNT\ CREATED*)        color="$YELLOW" ;;
        *LOGGED\ IN*)              color="$BLUE" ;;
        *TOKEN\ STORED*)           color="$CYAN" ;;
        *done*)                    color="$GREEN" ;;
    esac

    local line="  ${DIM}${time_short}${NC}  L${lvl}  ${svc}  ${BOLD}${act}${NC}  ${color}${res}${NC}"
    if [ -n "$det" ]; then
        line="$line  ${DIM}${det}${NC}"
    fi
    echo -e "$line"
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_show() {
    local count="${1:-20}"
    if [ ! -f "$AUDIT_FILE" ] || [ ! -s "$AUDIT_FILE" ]; then
        echo -e "${DIM}No audit entries yet.${NC}"
        return
    fi

    local total
    total=$(wc -l < "$AUDIT_FILE" | tr -d ' ')
    echo -e "${BOLD}Audit Log${NC} — showing last $count of $total entries"
    echo ""

    local current_session=""
    tail -"$count" "$AUDIT_FILE" | while IFS= read -r line; do
        local sess
        sess=$(echo "$line" | jq -r '.session // ""')
        if [ -n "$sess" ] && [ "$sess" != "$current_session" ]; then
            current_session="$sess"
            echo ""
            echo -e "${BOLD}Session: ${sess}${NC}"
        fi
        format_entry "$line"
    done
}

cmd_search() {
    local term="$1"
    echo -e "${BOLD}Search: ${NC}${term}"
    echo ""
    local found=false
    while IFS= read -r line; do
        if echo "$line" | grep -qi "$term"; then
            format_entry "$line"
            found=true
        fi
    done < "$AUDIT_FILE"
    if ! $found; then
        echo -e "${DIM}No matches found.${NC}"
    fi
}

cmd_accounts() {
    echo -e "${BOLD}Account Activity${NC}"
    echo ""
    local found=false
    while IFS= read -r line; do
        local res
        res=$(echo "$line" | jq -r '.result // ""')
        if echo "$res" | grep -qiE 'ACCOUNT CREATED|LOGGED IN|TOKEN STORED'; then
            format_entry "$line"
            found=true
        fi
    done < "$AUDIT_FILE"
    if ! $found; then
        echo -e "${DIM}No account activity found.${NC}"
    fi
}

cmd_failures() {
    echo -e "${BOLD}Failures${NC}"
    echo ""
    local found=false
    while IFS= read -r line; do
        local res
        res=$(echo "$line" | jq -r '.result // ""')
        if echo "$res" | grep -qiE 'FAILED|error'; then
            format_entry "$line"
            found=true
        fi
    done < "$AUDIT_FILE"
    if ! $found; then
        echo -e "${GREEN}No failures found.${NC}"
    fi
}

cmd_summary() {
    echo -e "${BOLD}Session Summary${NC}"
    echo ""
    if [ ! -f "$AUDIT_FILE" ] || [ ! -s "$AUDIT_FILE" ]; then
        echo -e "${DIM}No audit entries yet.${NC}"
        return
    fi

    # Group by session
    jq -r -s '
        group_by(.session) |
        map(select(.[0].session != null and .[0].session != "")) |
        .[] |
        {
            session: .[0].session,
            count: length,
            failures: [.[] | select(.result | test("FAILED|error"; "i"))] | length,
            first: .[0].timestamp,
            last: .[-1].timestamp
        } |
        "\(.first[0:16])  \(.session)  \(.count) actions  \(.failures) failed"
    ' "$AUDIT_FILE" 2>/dev/null | while IFS= read -r line; do
        local failures
        failures=$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')
        if [ "${failures:-0}" -gt 0 ]; then
            echo -e "  ${DIM}${line% *failed}${NC}  ${RED}${failures} failed${NC}"
        else
            echo -e "  ${DIM}${line}${NC}"
        fi
    done
}

cmd_verify() {
    echo -e "${BOLD}Hash Chain Verification${NC}"
    echo ""

    if [ ! -f "$AUDIT_FILE" ] || [ ! -s "$AUDIT_FILE" ]; then
        echo -e "${DIM}No audit entries to verify.${NC}"
        return
    fi

    local prev_expected="0000000000000000000000000000000000000000000000000000000000000000"
    local line_num=0
    local tampered=false
    local prev_line=""

    while IFS= read -r line; do
        ((line_num++)) || true
        local stored_prev
        stored_prev=$(echo "$line" | jq -r '.prev_hash // ""')

        if [ "$line_num" -gt 1 ]; then
            # Verify this entry's prev_hash matches the SHA-256 of the previous line
            local computed_hash
            computed_hash=$(echo "$prev_line" | shasum -a 256 | cut -d' ' -f1)

            if [ "$stored_prev" != "$computed_hash" ]; then
                echo -e "${RED}✗ TAMPERED at line ${line_num}${NC}"
                echo -e "  Expected prev_hash: ${computed_hash}"
                echo -e "  Found prev_hash:    ${stored_prev}"
                tampered=true
            fi
        else
            # First entry should have the genesis hash
            if [ "$stored_prev" != "$prev_expected" ]; then
                echo -e "${RED}✗ TAMPERED at line 1 — genesis hash mismatch${NC}"
                tampered=true
            fi
        fi

        prev_line="$line"
    done < "$AUDIT_FILE"

    local total
    total=$(wc -l < "$AUDIT_FILE" | tr -d ' ')

    if $tampered; then
        echo ""
        echo -e "${RED}✗ Hash chain BROKEN — audit log may have been tampered with${NC}"
        echo -e "  Total entries: $total"
    else
        echo -e "${GREEN}✓ Hash chain intact${NC} — $total entries verified"
    fi
}

cmd_export() {
    local format="${1:-markdown}"

    case "$format" in
        markdown|md)
            echo "# Autopilot Audit Log"
            echo ""
            local current_session=""
            while IFS= read -r line; do
                local sess ts act lvl svc res
                sess=$(echo "$line" | jq -r '.session // ""')
                ts=$(echo "$line" | jq -r '.timestamp // ""')
                act=$(echo "$line" | jq -r '.action // ""')
                lvl=$(echo "$line" | jq -r '.level // 0')
                svc=$(echo "$line" | jq -r '.service // "—"')
                res=$(echo "$line" | jq -r '.result // "done"')

                if [ -n "$sess" ] && [ "$sess" != "$current_session" ]; then
                    current_session="$sess"
                    echo ""
                    echo "## Session: $sess"
                    echo ""
                    echo "| Time | Action | Level | Service | Result |"
                    echo "|------|--------|-------|---------|--------|"
                fi

                local time_short="${ts:11:5}"
                echo "| $time_short | $act | L$lvl | $svc | $res |"
            done < "$AUDIT_FILE"
            ;;
        csv)
            echo "timestamp,action,level,service,result,session,detail"
            while IFS= read -r line; do
                echo "$line" | jq -r '[.timestamp, .action, .level, .service, .result, .session, .detail] | map(. // "") | @csv'
            done < "$AUDIT_FILE"
            ;;
        *)
            echo "ERROR: Unknown format '$format'. Use 'markdown' or 'csv'." >&2
            exit 1
            ;;
    esac
}

cmd_help() {
    echo -e "${BOLD}audit.sh${NC} — Autopilot structured audit log (JSONL + SHA-256 hash chain)"
    echo ""
    echo "Usage:"
    echo "  audit.sh log <action> [options]    Append audit entry"
    echo "    --level <N>                      Decision level (1-5)"
    echo "    --service <name>                 Service involved"
    echo "    --result <text>                  Result (done, FAILED, TOKEN STORED, etc.)"
    echo "    --session <id>                   Session identifier"
    echo "    --detail <text>                  Additional detail"
    echo ""
    echo "  audit.sh show [N]                  Show last N entries (default: 20)"
    echo "  audit.sh search <term>             Search logs"
    echo "  audit.sh accounts                  Account activity only"
    echo "  audit.sh failures                  Failed actions only"
    echo "  audit.sh summary                   Per-session summary"
    echo "  audit.sh verify                    Verify hash chain integrity"
    echo "  audit.sh export [markdown|csv]     Export log"
    echo ""
    echo "Flags:"
    echo "  --path <dir>                       Specify project path"
}

# ─── Main ────────────────────────────────────────────────────────────────────

COMMAND="${1:-show}"

case "$COMMAND" in
    help|--help|-h) cmd_help ;;
    log)
        resolve_log_file
        shift
        cmd_log "$@"
        ;;
    show)
        resolve_log_file
        shift || true
        cmd_show "${1:-20}"
        ;;
    search)
        if [ -z "${2:-}" ]; then
            echo -e "${RED}Usage: audit.sh search <term>${NC}"
            exit 1
        fi
        resolve_log_file
        cmd_search "$2"
        ;;
    accounts)   resolve_log_file; cmd_accounts ;;
    failures)   resolve_log_file; cmd_failures ;;
    summary)    resolve_log_file; cmd_summary ;;
    verify)     resolve_log_file; cmd_verify ;;
    export)
        resolve_log_file
        shift || true
        cmd_export "${1:-markdown}"
        ;;
    all)
        # Backward compat — show all entries
        resolve_log_file
        total=$(wc -l < "$AUDIT_FILE" 2>/dev/null | tr -d ' ' || echo "0")
        cmd_show "$total"
        ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}"
        cmd_help
        exit 1
        ;;
esac
