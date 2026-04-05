#!/bin/bash
# guardian-compile.sh — Compile guardian-rules.yaml into a fast-lookup cache
#
# Reads the declarative YAML config and produces a line-based cache file
# that guardian.sh can source without needing a YAML parser at runtime.
#
# Output format (one rule per line, sorted by tier):
#   TIER|CATEGORY|PATTERN|REASON
#
# Usage:
#   guardian-compile.sh              # Compile rules, write cache
#   guardian-compile.sh --check      # Validate only, don't write cache
#   guardian-compile.sh --verbose    # Show detailed per-rule output
#
# Exit codes:
#   0 = success
#   1 = validation error
#   2 = missing dependency or file

set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOPILOT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$AUTOPILOT_DIR/config"

RULES_YAML="$CONFIG_DIR/guardian-rules.yaml"
CUSTOM_RULES="$CONFIG_DIR/guardian-custom-rules.txt"
COMPILED_CACHE="$CONFIG_DIR/guardian-compiled.cache"

# ─── Options ─────────────────────────────────────────────────────────────────

CHECK_ONLY=false
VERBOSE=false

for arg in "$@"; do
    case "$arg" in
        --check)   CHECK_ONLY=true ;;
        --verbose) VERBOSE=true ;;
        --help|-h)
            echo "Usage: guardian-compile.sh [--check] [--verbose]"
            echo ""
            echo "  --check    Validate YAML only, don't write cache file"
            echo "  --verbose  Show detailed per-rule output during compilation"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $arg" >&2
            exit 2
            ;;
    esac
done

# ─── Dependency checks ──────────────────────────────────────────────────────

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 is required but not found" >&2
    exit 2
fi

if ! python3 -c "import yaml" 2>/dev/null; then
    echo "ERROR: PyYAML is required but not installed" >&2
    echo "Install with: pip3 install pyyaml" >&2
    echo "Attempting automatic install..." >&2
    if pip3 install pyyaml --quiet 2>/dev/null; then
        echo "PyYAML installed successfully" >&2
    else
        exit 2
    fi
fi

if [ ! -f "$RULES_YAML" ]; then
    echo "ERROR: Rules file not found: $RULES_YAML" >&2
    exit 2
fi

# ─── Generate timestamp ─────────────────────────────────────────────────────

COMPILE_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date)

# ─── Write Python script to tempfile (avoids quoting nightmares) ─────────────

PYSCRIPT=$(mktemp /tmp/guardian-compile.XXXXXX.py)
trap "rm -f '$PYSCRIPT'" EXIT

cat > "$PYSCRIPT" << 'PYTHON_EOF'
import yaml
import sys
import os
from collections import defaultdict

def main():
    rules_yaml = os.environ["GC_RULES_YAML"]
    custom_rules_path = os.environ["GC_CUSTOM_RULES"]
    check_only = os.environ.get("GC_CHECK_ONLY", "false") == "true"
    verbose = os.environ.get("GC_VERBOSE", "false") == "true"
    timestamp = os.environ.get("GC_TIMESTAMP", "unknown")
    cache_path = os.environ["GC_COMPILED_CACHE"]

    # ── Load YAML ──

    try:
        with open(rules_yaml, "r") as f:
            data = yaml.safe_load(f)
    except yaml.YAMLError as e:
        print(f"YAML_ERROR: Failed to parse {rules_yaml}: {e}", file=sys.stderr)
        sys.exit(1)
    except IOError as e:
        print(f"FILE_ERROR: Cannot read {rules_yaml}: {e}", file=sys.stderr)
        sys.exit(1)

    # ── Validate top-level structure ──

    errors = []

    if not isinstance(data, dict):
        errors.append("Root element must be a mapping")
        for e in errors:
            print(f"VALIDATION_ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    version = data.get("version")
    if version is None:
        errors.append("Missing required top-level field: version")

    categories = data.get("categories")
    if categories is None:
        errors.append("Missing required top-level field: categories")
    elif not isinstance(categories, list):
        errors.append("categories must be a list")

    egress_allowlist = data.get("egress_allowlist", [])

    if errors:
        for e in errors:
            print(f"VALIDATION_ERROR: {e}", file=sys.stderr)
        sys.exit(1)

    # ── Validate each category and rule ──

    all_rules = []          # (tier, category, pattern, reason, scope)
    seen_patterns = {}      # pattern -> category (for duplicate detection)
    category_counts = defaultdict(int)
    tier_counts = defaultdict(int)
    scope_counts = defaultdict(int)
    category_names = set()

    for cat_idx, cat in enumerate(categories):
        if not isinstance(cat, dict):
            errors.append(f"Category #{cat_idx + 1} is not a mapping")
            continue

        cat_name = cat.get("name")
        if not cat_name:
            errors.append(f"Category #{cat_idx + 1} missing required field: name")
            continue

        if cat_name in category_names:
            errors.append(f"Duplicate category name: {cat_name}")
        category_names.add(cat_name)

        if "description" not in cat:
            errors.append(f"Category {cat_name} missing field: description")

        rules = cat.get("rules")
        if rules is None:
            errors.append(f"Category {cat_name} missing required field: rules")
            continue
        if not isinstance(rules, list):
            errors.append(f"Category {cat_name}: rules must be a list")
            continue

        for rule_idx, rule in enumerate(rules):
            rule_label = f"{cat_name} rule #{rule_idx + 1}"

            if not isinstance(rule, dict):
                errors.append(f"{rule_label} is not a mapping")
                continue

            # Required fields
            pattern = rule.get("pattern")
            reason = rule.get("reason")
            tier = rule.get("tier")

            if not pattern:
                errors.append(f"{rule_label} missing required field: pattern")
            if not reason:
                errors.append(f"{rule_label} missing required field: reason")
            if tier is None:
                errors.append(f"{rule_label} missing required field: tier")
            elif tier not in (1, 2, 3):
                errors.append(f"{rule_label} invalid tier: {tier} (must be 1, 2, or 3)")

            if not pattern or not reason or tier not in (1, 2, 3):
                continue

            # Optional fields
            scope = rule.get("scope", "bash")

            # Duplicate check
            if pattern in seen_patterns:
                errors.append(
                    f'{rule_label} duplicate pattern "{pattern}" '
                    f"(already in {seen_patterns[pattern]})"
                )
            else:
                seen_patterns[pattern] = cat_name

            # Collect stats
            category_counts[cat_name] += 1
            tier_counts[tier] += 1
            scope_counts[scope] += 1

            all_rules.append((tier, cat_name, pattern, reason, scope))

    # ── Report validation errors ──

    if errors:
        print(f"\nFound {len(errors)} validation error(s):", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)

    # ── Sort by tier (1 first, then 2, then 3), preserving order within tier ──

    all_rules.sort(key=lambda r: r[0])

    # ── Handle custom rules ──

    custom_count = 0
    custom_rules_list = []

    if os.path.isfile(custom_rules_path) and os.path.getsize(custom_rules_path) > 0:
        with open(custom_rules_path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue

                parts = None
                if ":::" in line:
                    segments = line.split(":::", 2)
                    if len(segments) >= 2:
                        cat = segments[0].strip()
                        pat = segments[1].strip()
                        rsn = segments[2].strip() if len(segments) > 2 else "Blocked by custom rule"
                        parts = (cat, pat, rsn)
                elif "|" in line:
                    segments = line.split("|", 2)
                    if len(segments) >= 2:
                        cat = segments[0].strip()
                        pat = segments[1].strip()
                        rsn = segments[2].strip() if len(segments) > 2 else "Blocked by custom rule"
                        parts = (cat, pat, rsn)

                if parts:
                    custom_rules_list.append((3, parts[0], parts[1], parts[2], "bash"))
                    custom_count += 1
                    category_counts[f"CUSTOM:{parts[0]}"] += 1
                    tier_counts[3] = tier_counts.get(3, 0)

    # ── Generate cache content ──

    cache_lines = []
    cache_lines.append("# guardian-compiled.cache -- Auto-generated by guardian-compile.sh")
    cache_lines.append("# DO NOT EDIT -- regenerate with: bin/guardian-compile.sh")
    cache_lines.append(f"# Source: config/guardian-rules.yaml (v{version})")
    cache_lines.append(f"# Generated: {timestamp}")
    cache_lines.append(f"# Total rules: {len(all_rules)} yaml + {custom_count} custom = {len(all_rules) + custom_count}")
    cache_lines.append("#")
    cache_lines.append("# Format: TIER|CATEGORY|PATTERN|REASON[|SCOPE]")
    cache_lines.append("#")

    # Egress allowlist as a special entry
    if egress_allowlist:
        domains = ",".join(str(d) for d in egress_allowlist)
        cache_lines.append(f"# EGRESS_ALLOWLIST={domains}")
        cache_lines.append("#")

    for tier, cat, pattern, reason, scope in all_rules:
        if scope != "bash":
            cache_lines.append(f"{tier}|{cat}|{pattern}|{reason}|{scope}")
        else:
            cache_lines.append(f"{tier}|{cat}|{pattern}|{reason}")

    # Separator before custom rules
    if custom_rules_list:
        cache_lines.append("#")
        cache_lines.append("# -- Custom rules (from guardian-custom-rules.txt) --")
        cache_lines.append("#")
        for tier, cat, pattern, reason, scope in custom_rules_list:
            cache_lines.append(f"{tier}|{cat}|{pattern}|{reason}")

    cache_content = "\n".join(cache_lines) + "\n"

    # ── Output stats to stdout ──

    yaml_count = len(all_rules)
    total_count = yaml_count + custom_count

    print("Guardian Rules Compiler")
    print("=======================")
    print(f"Source:  {rules_yaml}")
    print(f"Version: {version}")
    print()
    print("Rules by tier:")
    for t in sorted(tier_counts.keys()):
        label = {
            1: "Tier 1 (literal/glob)",
            2: "Tier 2 (regex)",
            3: "Tier 3 (custom/slow)",
        }.get(t, f"Tier {t}")
        print(f"  {label}: {tier_counts[t]}")
    print()
    print("Rules by category:")
    for cat in sorted(category_counts.keys()):
        print(f"  {cat}: {category_counts[cat]}")
    print()
    print("Rule scopes:")
    for scope in sorted(scope_counts.keys()):
        print(f"  {scope}: {scope_counts[scope]}")
    print()
    print(f"Egress allowlist: {len(egress_allowlist)} domains")
    print(f"Custom rules:     {custom_count} (from guardian-custom-rules.txt)")
    print()
    print(f"Total: {yaml_count} YAML + {custom_count} custom = {total_count} rules")
    print()

    if verbose:
        print("Compiled rules (sorted by tier):")
        print("-" * 70)
        for tier, cat, pattern, reason, scope in all_rules:
            scope_tag = f" [{scope}]" if scope != "bash" else ""
            print(f"  T{tier} [{cat}] {pattern}{scope_tag}")
            print(f"       -> {reason}")
        if custom_rules_list:
            print()
            print("Custom rules:")
            print("-" * 70)
            for tier, cat, pattern, reason, scope in custom_rules_list:
                print(f"  T{tier} [{cat}] {pattern}")
                print(f"       -> {reason}")
        print()

    if check_only:
        print("Validation passed. No cache file written (--check mode).")
    else:
        # Write cache file directly from Python
        try:
            with open(cache_path, "w") as f:
                f.write(cache_content)
            rule_count = sum(1 for line in cache_content.splitlines() if line and line[0].isdigit())
            print(f"Wrote {cache_path} ({rule_count} rules)")
        except IOError as e:
            print(f"ERROR: Cannot write cache file: {e}", file=sys.stderr)
            sys.exit(1)

    print(f"All {total_count} rules validated successfully.")


if __name__ == "__main__":
    main()
PYTHON_EOF

# ─── Run the Python compiler ────────────────────────────────────────────────

export GC_RULES_YAML="$RULES_YAML"
export GC_CUSTOM_RULES="$CUSTOM_RULES"
export GC_COMPILED_CACHE="$COMPILED_CACHE"
export GC_CHECK_ONLY="$CHECK_ONLY"
export GC_VERBOSE="$VERBOSE"
export GC_TIMESTAMP="$COMPILE_TIMESTAMP"

if python3 "$PYSCRIPT"; then
    echo "Done."
    exit 0
else
    PYTHON_EXIT=$?
    echo "" >&2
    echo "Compilation failed with exit code $PYTHON_EXIT" >&2
    exit 1
fi
