#!/bin/bash
# token-report.sh — Unified token savings dashboard
#
# Aggregates metrics from RTK (CLI compression) and TokenPilot (read dedup,
# task classification, thinking caps) into a single view.
#
# Usage:
#   token-report.sh              Show combined savings summary
#   token-report.sh rtk          Show RTK savings only
#   token-report.sh tokenpilot   Show TokenPilot savings only
#   token-report.sh --json       Machine-readable JSON output

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

JSON_MODE=false
SECTION="all"

for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=true ;;
        rtk) SECTION="rtk" ;;
        tokenpilot) SECTION="tokenpilot" ;;
    esac
done

# ─── RTK Metrics ─────────────────────────────────────────────────────────────

get_rtk_metrics() {
    if ! command -v rtk &>/dev/null; then
        echo "not_installed"
        return
    fi

    # Get RTK gain output
    local gain_output
    gain_output=$(rtk gain 2>/dev/null || echo "no_data")

    if [[ "$gain_output" == *"No tracking data"* ]] || [[ "$gain_output" == "no_data" ]]; then
        echo "no_data"
        return
    fi

    echo "$gain_output"
}

# ─── TokenPilot Metrics ─────────────────────────────────────────────────────

get_tokenpilot_metrics() {
    local tp_db="$HOME/MCPs/tokenpilot/tokenpilot.db"

    if [ ! -f "$tp_db" ]; then
        echo "not_installed"
        return
    fi

    # Query SQLite for session stats
    local stats
    stats=$(sqlite3 "$tp_db" "
        SELECT
            COALESCE(SUM(CASE WHEN key='prompts_classified' THEN value END), 0) as prompts,
            COALESCE(SUM(CASE WHEN key='reads_total' THEN value END), 0) as reads,
            COALESCE(SUM(CASE WHEN key='reads_blocked' THEN value END), 0) as blocked,
            COALESCE(SUM(CASE WHEN key='tokens_saved_dedup' THEN value END), 0) as saved,
            COALESCE(SUM(CASE WHEN key='trivial_count' THEN value END), 0) as trivial,
            COALESCE(SUM(CASE WHEN key='research_count' THEN value END), 0) as research,
            COALESCE(SUM(CASE WHEN key='standard_count' THEN value END), 0) as standard,
            COALESCE(SUM(CASE WHEN key='complex_count' THEN value END), 0) as complex
        FROM stats;
    " 2>/dev/null || echo "0|0|0|0|0|0|0|0")

    echo "$stats"
}

# ─── Display ─────────────────────────────────────────────────────────────────

show_header() {
    if [ "$JSON_MODE" = true ]; then return; fi
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Token Savings Dashboard${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════${NC}"
    echo ""
}

show_rtk() {
    if [ "$JSON_MODE" = true ]; then return; fi

    local rtk_data
    rtk_data=$(get_rtk_metrics)

    echo -e "${CYAN}${BOLD}  RTK (CLI Output Compression)${NC}"
    echo -e "${DIM}  ─────────────────────────────${NC}"

    if [ "$rtk_data" = "not_installed" ]; then
        echo -e "  ${YELLOW}Not installed${NC}"
    elif [ "$rtk_data" = "no_data" ]; then
        echo -e "  ${DIM}No tracking data yet — savings are being recorded as commands run${NC}"
    else
        echo "$rtk_data" | sed 's/^/  /'
    fi
    echo ""
}

show_tokenpilot() {
    if [ "$JSON_MODE" = true ]; then return; fi

    local tp_data
    tp_data=$(get_tokenpilot_metrics)

    echo -e "${CYAN}${BOLD}  TokenPilot (Read Dedup + Classification)${NC}"
    echo -e "${DIM}  ────────────────────────────────────────${NC}"

    if [ "$tp_data" = "not_installed" ]; then
        echo -e "  ${YELLOW}Not installed${NC}"
        echo ""
        return
    fi

    IFS='|' read -r prompts reads blocked saved trivial research standard complex <<< "$tp_data"

    echo -e "  Prompts classified:  ${BOLD}$prompts${NC}"
    echo -e "    Trivial (Haiku):   $trivial"
    echo -e "    Research (Sonnet): $research"
    echo -e "    Standard (Sonnet): $standard"
    echo -e "    Complex (Opus):    $complex"
    echo ""
    echo -e "  File reads:          ${BOLD}$reads${NC} total"
    echo -e "  Redundant blocked:   ${GREEN}$blocked${NC}"
    echo -e "  Est. tokens saved:   ${GREEN}${BOLD}$saved${NC}"
    echo ""
}

show_json() {
    local rtk_data tp_data
    rtk_data=$(get_rtk_metrics)
    tp_data=$(get_tokenpilot_metrics)

    IFS='|' read -r prompts reads blocked saved trivial research standard complex <<< "$tp_data"

    cat <<EOF
{
  "rtk": {
    "installed": $([ "$rtk_data" != "not_installed" ] && echo "true" || echo "false"),
    "has_data": $([ "$rtk_data" != "no_data" ] && [ "$rtk_data" != "not_installed" ] && echo "true" || echo "false")
  },
  "tokenpilot": {
    "installed": $([ "$tp_data" != "not_installed" ] && echo "true" || echo "false"),
    "prompts_classified": ${prompts:-0},
    "reads_total": ${reads:-0},
    "reads_blocked": ${blocked:-0},
    "tokens_saved_dedup": ${saved:-0},
    "classification": {
      "trivial": ${trivial:-0},
      "research": ${research:-0},
      "standard": ${standard:-0},
      "complex": ${complex:-0}
    }
  }
}
EOF
}

# ─── Main ────────────────────────────────────────────────────────────────────

if [ "$JSON_MODE" = true ]; then
    show_json
    exit 0
fi

show_header

case "$SECTION" in
    rtk) show_rtk ;;
    tokenpilot) show_tokenpilot ;;
    all)
        show_rtk
        show_tokenpilot
        echo -e "${DIM}  Tip: Run 'rtk gain' for detailed CLI savings, '/tp stats' for session details${NC}"
        echo ""
        ;;
esac
