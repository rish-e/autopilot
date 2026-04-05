#!/bin/bash
# mcp-compress.sh — Wrap MCP servers with mcp-compressor for token savings
#
# Wraps heavyweight MCP servers to reduce schema token consumption.
# Instead of loading 94 tool definitions (GitHub), loads 2 compressed
# wrapper tools — saving ~17,000 tokens per server.
#
# Usage:
#   mcp-compress.sh status                 Show compression status for all servers
#   mcp-compress.sh enable <server>        Wrap a server with mcp-compressor
#   mcp-compress.sh disable <server>       Restore original server config
#   mcp-compress.sh enable-recommended     Wrap github, uimax, backend-max
#   mcp-compress.sh estimate               Show estimated token savings
#
# Supported servers: github (HTTP), uimax (stdio), backend-max (stdio)
# Requires: mcp-compressor (pip install mcp-compressor)

set -eo pipefail

CLAUDE_JSON="$HOME/.claude.json"
BACKUP_DIR="$HOME/.claude/backups"

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ─── Helpers ─────────────────────────────────────────────────────────────────

check_deps() {
    if ! command -v mcp-compressor &>/dev/null; then
        echo -e "${RED}Error:${NC} mcp-compressor not found."
        echo "Install: pip install mcp-compressor"
        exit 1
    fi
    if ! command -v python3 &>/dev/null; then
        echo -e "${RED}Error:${NC} python3 not found."
        exit 1
    fi
    if [ ! -f "$CLAUDE_JSON" ]; then
        echo -e "${RED}Error:${NC} $CLAUDE_JSON not found."
        exit 1
    fi
}

backup_config() {
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%d_%H%M%S)
    cp "$CLAUDE_JSON" "$BACKUP_DIR/claude.json.${ts}.bak"
    echo -e "${DIM}Backup: $BACKUP_DIR/claude.json.${ts}.bak${NC}"
}

is_compressed() {
    local server="$1"
    python3 -c "
import json, sys
d = json.load(open('$CLAUDE_JSON'))
s = d.get('mcpServers', {}).get('$server', {})
cmd = s.get('command', '')
args = ' '.join(s.get('args', []))
# Check if it's wrapped with mcp-compressor
if 'mcp-compressor' in cmd or 'mcp-compressor' in args:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# ─── Token Estimates ─────────────────────────────────────────────────────────

# Estimated tokens per server (tool count * ~187 tokens/tool average)
TOKENS_PER_TOOL=187
COMPRESSED_OVERHEAD=500  # ~500 tokens for the 2 wrapper tools + tool list

get_tool_count() {
    case "$1" in
        github) echo 94 ;;
        uimax) echo 30 ;;
        backend-max) echo 28 ;;
        playwright) echo 21 ;;
        filesystem) echo 14 ;;
        jcodemunch) echo 11 ;;
        shadcn-ui) echo 10 ;;
        memory) echo 9 ;;
        magicui) echo 3 ;;
        context7) echo 2 ;;
        *) echo 10 ;;
    esac
}

# ─── Commands ────────────────────────────────────────────────────────────────

cmd_status() {
    echo -e "${BOLD}MCP Compression Status${NC}"
    echo ""

    python3 -c "
import json
d = json.load(open('$CLAUDE_JSON'))
servers = d.get('mcpServers', {})
for name in sorted(servers.keys()):
    s = servers[name]
    cmd = s.get('command', '')
    args = ' '.join(s.get('args', []))
    stype = s.get('type', 'stdio')
    compressed = 'mcp-compressor' in cmd or 'mcp-compressor' in args
    status = '\033[0;32mcompressed\033[0m' if compressed else '\033[2moriginal\033[0m'
    print(f'  {name:25s} {stype:6s}  {status}')
"
    echo ""
}

cmd_estimate() {
    echo -e "${BOLD}Estimated Token Savings${NC}"
    echo ""
    echo -e "  ${DIM}Server                    Tools   Tokens    Compressed   Savings${NC}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────${NC}"

    local total_current=0
    local total_compressed=0

    for server in github uimax backend-max playwright; do
        local tools
        tools=$(get_tool_count "$server")
        local current=$((tools * TOKENS_PER_TOOL))
        local compressed=$COMPRESSED_OVERHEAD
        local savings=$((current - compressed))
        local pct=$((savings * 100 / current))

        total_current=$((total_current + current))
        total_compressed=$((total_compressed + compressed))

        local recommend=""
        if [ "$tools" -ge 20 ]; then
            recommend="${GREEN}recommended${NC}"
        else
            recommend="${DIM}marginal${NC}"
        fi

        printf "  %-25s %3d   %6d    %6d       %s (%d%%)\n" \
            "$server" "$tools" "$current" "$compressed" "-$savings" "$pct"
    done

    local total_savings=$((total_current - total_compressed))
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────${NC}"
    printf "  ${BOLD}%-25s %3s   %6d    %6d       -%d (%d%%)${NC}\n" \
        "TOTAL (top 4)" "" "$total_current" "$total_compressed" "$total_savings" \
        "$((total_savings * 100 / total_current))"
    echo ""
    echo -e "  ${DIM}Recommended: github, uimax, backend-max (20+ tools each)${NC}"
    echo ""
}

cmd_enable() {
    local server="$1"
    check_deps

    if is_compressed "$server"; then
        echo -e "${YELLOW}Already compressed:${NC} $server"
        return
    fi

    backup_config

    python3 - "$server" "$CLAUDE_JSON" << 'PYEOF'
import json, sys, copy

server = sys.argv[1]
config_path = sys.argv[2]

with open(config_path) as f:
    config = json.load(f)

servers = config.get("mcpServers", {})
if server not in servers:
    print(f"Error: server '{server}' not found in {config_path}", file=sys.stderr)
    sys.exit(1)

original = servers[server]

# Save original config for restoration
if "_mcp_compress_originals" not in config:
    config["_mcp_compress_originals"] = {}
config["_mcp_compress_originals"][server] = copy.deepcopy(original)

# Build compressed config based on server type
stype = original.get("type", "stdio")

if stype == "http":
    # HTTP server: pass URL directly
    url = original.get("url", "")
    new_config = {
        "type": "stdio",
        "command": "mcp-compressor",
        "args": [url, "--server-name", server, "--compression", "high"],
        "env": original.get("env", {})
    }
    # Carry over headers as -H args
    headers = original.get("headers", {})
    for key, value in headers.items():
        new_config["args"].extend(["--header", f"{key}={value}"])

elif stype == "stdio":
    # Stdio server: wrap the original command
    orig_cmd = original.get("command", "")
    orig_args = original.get("args", [])
    new_config = {
        "type": "stdio",
        "command": "mcp-compressor",
        "args": [
            "--stdio", orig_cmd, *orig_args,
            "--server-name", server,
            "--compression", "high"
        ],
        "env": original.get("env", {})
    }
else:
    print(f"Error: unsupported server type '{stype}' for {server}", file=sys.stderr)
    sys.exit(1)

servers[server] = new_config

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

tools_map = {"github": 94, "uimax": 30, "backend-max": 28, "playwright": 21}
t = tools_map.get(server, 10)
saved = t * 187 - 500
print(f"Compressed: {server} ({t} tools -> 2 wrappers, ~{saved} tokens saved)")
PYEOF

    echo -e "${GREEN}Enabled${NC} compression for ${BOLD}$server${NC}"
    echo -e "${DIM}Restart Claude Code for changes to take effect.${NC}"
}

cmd_disable() {
    local server="$1"
    check_deps

    if ! is_compressed "$server"; then
        echo -e "${YELLOW}Not compressed:${NC} $server"
        return
    fi

    backup_config

    python3 - "$server" "$CLAUDE_JSON" << 'PYEOF'
import json, sys

server = sys.argv[1]
config_path = sys.argv[2]

with open(config_path) as f:
    config = json.load(f)

originals = config.get("_mcp_compress_originals", {})
if server not in originals:
    print(f"Error: no original config saved for '{server}'. Restore from backup.", file=sys.stderr)
    sys.exit(1)

config["mcpServers"][server] = originals[server]
del originals[server]
if not originals:
    del config["_mcp_compress_originals"]

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

print(f"Restored original config for {server}")
PYEOF

    echo -e "${GREEN}Disabled${NC} compression for ${BOLD}$server${NC}"
    echo -e "${DIM}Restart Claude Code for changes to take effect.${NC}"
}

cmd_enable_recommended() {
    echo -e "${BOLD}Enabling compression for recommended servers...${NC}"
    echo ""
    for server in github uimax backend-max; do
        cmd_enable "$server"
    done
    echo ""
    echo -e "${GREEN}Done.${NC} Restart Claude Code to apply. Run ${BOLD}mcp-compress.sh status${NC} to verify."
}

# ─── Main ────────────────────────────────────────────────────────────────────

case "${1:-}" in
    status) cmd_status ;;
    estimate) cmd_estimate ;;
    enable)
        [ -z "${2:-}" ] && { echo "Usage: mcp-compress.sh enable <server>"; exit 1; }
        cmd_enable "$2"
        ;;
    disable)
        [ -z "${2:-}" ] && { echo "Usage: mcp-compress.sh disable <server>"; exit 1; }
        cmd_disable "$2"
        ;;
    enable-recommended) cmd_enable_recommended ;;
    *)
        echo "Usage: mcp-compress.sh <command>"
        echo ""
        echo "Commands:"
        echo "  status                Show compression status"
        echo "  estimate              Show estimated token savings"
        echo "  enable <server>       Compress a server"
        echo "  disable <server>      Restore original config"
        echo "  enable-recommended    Compress github, uimax, backend-max"
        ;;
esac
