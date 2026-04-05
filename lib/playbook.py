#!/usr/bin/env python3
"""
playbook.py — Dynamic Playbook Engine for Autopilot

Generator → Cache → Engine pattern:
  1. Check cache for existing playbook (disk YAML + memory.db metadata)
  2. If not found, generate a skeleton for the agent to fill in
  3. After successful execution, cache the playbook for reuse
  4. Track success/failure rates per playbook

Designed to work in BOTH modes:
  - Agent mode:  `python3 lib/playbook.py <command>` from Claude Code
  - Daemon mode:  `from lib.playbook import PlaybookEngine`

Playbook YAML files stored at: ~/MCPs/autopilot/playbooks/{service}/{flow}.yaml
Playbook metadata stored in:   ~/.autopilot/memory.db (playbooks table)
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import yaml

# ─── Configuration ───────────────────────────────────────────────────────────

AUTOPILOT_DIR = Path(os.environ.get(
    "AUTOPILOT_DIR",
    Path.home() / "MCPs" / "autopilot"
))
PLAYBOOKS_DIR = AUTOPILOT_DIR / "playbooks"
TEMPLATE_PATH = AUTOPILOT_DIR / "config" / "playbook-template.yaml"

PLAYBOOKS_DIR.mkdir(parents=True, exist_ok=True)

# Import memory store (same directory)
sys.path.insert(0, str(Path(__file__).parent))
from memory import AutopilotMemory

# ─── Colors ──────────────────────────────────────────────────────────────────

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
BLUE = "\033[0;34m"
CYAN = "\033[0;36m"
BOLD = "\033[1m"
DIM = "\033[2m"
NC = "\033[0m"


# ═════════════════════════════════════════════════════════════════════════════
# PlaybookEngine
# ═════════════════════════════════════════════════════════════════════════════

class PlaybookEngine:
    """Generate, cache, and manage browser automation playbooks.

    Usage:
        engine = PlaybookEngine()

        # Check if playbook exists
        pb = engine.get("vercel", "signup")

        # Generate skeleton for a new service
        skeleton = engine.generate("render", "signup",
            urls={"signup": "https://render.com/register"})

        # Save a playbook (after agent fills in steps)
        engine.save("render", "signup", playbook_dict)

        # Record execution result
        engine.record_run("render", "signup", success=True, duration_ms=15000)

        # List all cached playbooks
        engine.list_all()
    """

    def __init__(self, mem: AutopilotMemory = None):
        self.mem = mem or AutopilotMemory()
        self._owns_mem = mem is None  # track if we created it

    def close(self):
        if self._owns_mem:
            self.mem.close()

    # ════════════════════════════════════════════════════════════════════════
    # GET — check cache for existing playbook
    # ════════════════════════════════════════════════════════════════════════

    def get(self, service: str, flow: str) -> Optional[dict]:
        """Get a cached playbook. Returns None if not found.

        Checks disk YAML first, then memory.db metadata.
        """
        # Check disk
        yaml_path = PLAYBOOKS_DIR / service / f"{flow}.yaml"
        if yaml_path.exists():
            try:
                with open(yaml_path) as f:
                    return yaml.safe_load(f)
            except Exception:
                pass  # corrupt file, fall through

        # Check memory.db for file_path
        meta = self.mem.get_playbook(service, flow)
        if meta and meta.get("file_path"):
            fp = Path(meta["file_path"])
            if fp.exists():
                try:
                    with open(fp) as f:
                        return yaml.safe_load(f)
                except Exception:
                    pass

        return None

    def has(self, service: str, flow: str) -> bool:
        """Check if a playbook exists."""
        return self.get(service, flow) is not None

    # ════════════════════════════════════════════════════════════════════════
    # GENERATE — create a playbook skeleton
    # ════════════════════════════════════════════════════════════════════════

    def generate(self, service: str, flow: str,
                 urls: dict = None,
                 cli_info: dict = None,
                 extra_vars: dict = None) -> dict:
        """Generate a playbook skeleton for the agent to fill in.

        The agent calls this, then uses browser_snapshot to fill in
        actual selectors, URLs, and field mappings.

        Args:
            service:   Service name (e.g., "vercel", "render")
            flow:      Flow type: "signup", "login", "get_api_key", or custom
            urls:      Dict of known URLs for this service
            cli_info:  Dict with CLI details if available
            extra_vars: Additional template variables

        Returns:
            A playbook dict with pre-populated steps based on flow type.
        """
        now = datetime.now(timezone.utc).isoformat()

        playbook = {
            "service": service,
            "flow": flow,
            "version": 1,
            "generated_at": now,
            "last_verified": None,
            "config": {
                "timeout_ms": 30000,
                "retry_on_failure": True,
                "max_retries": 2,
                "screenshot_on_error": True,
                "cli_available": bool(cli_info),
                "cli_tool": cli_info.get("tool") if cli_info else None,
                "cli_install": cli_info.get("install") if cli_info else None,
                "prefer_cli": True,
                "auth_method": cli_info.get("auth_method", "password") if cli_info else "password",
            },
            "urls": urls or {
                "home": f"https://{service}.com",
                "signup": f"https://{service}.com/signup",
                "login": f"https://{service}.com/login",
                "dashboard": f"https://{service}.com/dashboard",
                "api_keys": f"https://{service}.com/settings/tokens",
            },
            "vars": {
                "email": "{{primary_email}}",
                "password": "{{primary_password}}",
                "username": "{{professional_primary}}",
            },
            "steps": [],
            "on_error": [
                {
                    "condition": "snapshot_contains:captcha",
                    "action": "escalate",
                    "level": 5,
                    "message": f"CAPTCHA detected on {service}",
                },
                {
                    "condition": "snapshot_contains:rate limit",
                    "action": "wait",
                    "duration_ms": 60000,
                    "then": "retry",
                },
                {
                    "condition": "element_not_found",
                    "action": "retry_with_snapshot",
                    "note": "Take browser_snapshot, find alternative selector, auto-heal playbook",
                },
                {
                    "condition": "timeout",
                    "action": "screenshot_and_escalate",
                },
            ],
            "on_success": [
                {
                    "action": "log",
                    "message": f"{flow} completed for {service}",
                },
            ],
        }

        if extra_vars:
            playbook["vars"].update(extra_vars)

        # Pre-populate steps based on flow type
        playbook["steps"] = self._generate_steps(service, flow, urls or {})

        return playbook

    def _generate_steps(self, service: str, flow: str, urls: dict) -> list:
        """Generate default steps based on flow type."""

        if flow == "signup":
            return [
                {
                    "id": "navigate_signup",
                    "intent": "Open the service signup page",
                    "action": "browser_navigate",
                    "params": {"url": urls.get("signup", f"https://{service}.com/signup")},
                    "expect": {"snapshot_contains": "sign up|create account|register|get started"},
                    "note": "AGENT: verify URL from research",
                },
                {
                    "id": "fill_email",
                    "intent": "Pre-fill account email address for user",
                    "action": "browser_type",
                    "params": {"field": "email", "text": "{{email}}"},
                    "note": "AGENT: update field ref from browser_snapshot",
                },
                {
                    "id": "fill_password",
                    "intent": "Pre-fill the account password for user",
                    "action": "browser_type",
                    "params": {"field": "password", "text": "{{password}}"},
                    "note": "AGENT: update field ref from browser_snapshot",
                },
                {
                    "id": "user_handoff",
                    "intent": "Ask user to click signup button and complete verification (CAPTCHA, email, 2FA)",
                    "action": "user_confirm",
                    "params": {"message": f"I've filled the signup form for {service}. Please click the signup button and complete any verification. Tell me when you're in."},
                    "note": "ASSISTED SIGNUP: Claude Code prohibits autonomous account creation. User clicks the button, autopilot handles everything else.",
                },
                {
                    "id": "check_result",
                    "intent": "Verify signup succeeded and find where user landed",
                    "action": "browser_snapshot",
                    "expect": {"one_of": ["dashboard", "verify your email", "welcome", "confirm", "api key", "settings"]},
                },
                {
                    "id": "handle_email_verification",
                    "intent": "Complete email verification if required",
                    "action": "verify_email",
                    "params": {
                        "sender": f"noreply@{service}.com",
                        "timeout_ms": 120000,
                    },
                    "condition": "previous_contains:verify|confirm your email",
                },
            ]

        elif flow == "login":
            return [
                {
                    "id": "navigate_login",
                    "intent": "Open the service login page",
                    "action": "browser_navigate",
                    "params": {"url": urls.get("login", f"https://{service}.com/login")},
                    "expect": {"snapshot_contains": "sign in|log in|email|password"},
                },
                {
                    "id": "fill_email",
                    "intent": "Enter login email address",
                    "action": "browser_type",
                    "params": {"field": "email", "text": "{{email}}"},
                },
                {
                    "id": "fill_password",
                    "intent": "Enter login password",
                    "action": "browser_type",
                    "params": {"field": "password", "text": "{{password}}"},
                },
                {
                    "id": "submit_login",
                    "intent": "Submit the login form",
                    "action": "browser_click",
                    "params": {"target": "sign in button"},
                },
                {
                    "id": "handle_2fa",
                    "intent": "Complete two-factor authentication if prompted",
                    "action": "totp",
                    "params": {"service": service},
                    "condition": "snapshot_contains:verification code|two-factor|2fa|authenticator",
                },
                {
                    "id": "verify_logged_in",
                    "intent": "Confirm login was successful",
                    "action": "browser_snapshot",
                    "expect": {"snapshot_contains": "dashboard|home|overview|settings"},
                },
            ]

        elif flow == "get_api_key":
            return [
                {
                    "id": "ensure_logged_in",
                    "intent": "Ensure we have an active session",
                    "action": "run_flow",
                    "params": {"flow": "login"},
                    "condition": "not_logged_in",
                },
                {
                    "id": "navigate_tokens",
                    "intent": "Navigate to the API token management page",
                    "action": "browser_navigate",
                    "params": {"url": urls.get("api_keys", f"https://{service}.com/settings/tokens")},
                    "expect": {"snapshot_contains": "token|api key|access key"},
                    "note": "AGENT: update URL from research",
                },
                {
                    "id": "click_create",
                    "intent": "Initiate creation of a new API token",
                    "action": "browser_click",
                    "params": {"target": "create token/key button"},
                    "note": "AGENT: update button ref from browser_snapshot",
                },
                {
                    "id": "name_token",
                    "intent": "Name the token for identification",
                    "action": "browser_type",
                    "params": {"field": "token name", "text": "autopilot-{{timestamp}}"},
                    "condition": "snapshot_contains:name|label|description",
                },
                {
                    "id": "submit_create",
                    "intent": "Confirm token creation",
                    "action": "browser_click",
                    "params": {"target": "create/generate button"},
                },
                {
                    "id": "capture_token",
                    "intent": "Read the generated token value from the page",
                    "action": "browser_snapshot",
                    "note": "AGENT: extract token value from snapshot text, store via keychain",
                },
                {
                    "id": "store_in_keychain",
                    "intent": "Securely store the token in OS keychain",
                    "action": "keychain_set",
                    "params": {"service": service, "key": "api-token"},
                    "note": "AGENT: pass captured token value",
                },
            ]

        else:
            # Unknown flow — return empty steps for agent to fill
            return [
                {
                    "id": "step_1",
                    "intent": f"Complete the {flow} flow for {service}",
                    "action": "browser_navigate",
                    "params": {"url": f"https://{service}.com"},
                    "note": f"AGENT: research {service} {flow} flow and fill in steps",
                },
            ]

    # ════════════════════════════════════════════════════════════════════════
    # SAVE — cache a playbook to disk and memory.db
    # ════════════════════════════════════════════════════════════════════════

    def save(self, service: str, flow: str, playbook: dict,
             generated_by: str = "auto"):
        """Save a playbook to disk and register in memory.db."""
        # Ensure directory exists
        service_dir = PLAYBOOKS_DIR / service
        service_dir.mkdir(parents=True, exist_ok=True)

        # Write YAML
        yaml_path = service_dir / f"{flow}.yaml"
        with open(yaml_path, "w") as f:
            yaml.dump(playbook, f, default_flow_style=False, sort_keys=False,
                      allow_unicode=True, width=120)

        # Register in memory.db
        self.mem.register_playbook(service, flow, str(yaml_path), generated_by)

        return str(yaml_path)

    # ════════════════════════════════════════════════════════════════════════
    # RECORD — track execution results
    # ════════════════════════════════════════════════════════════════════════

    def record_run(self, service: str, flow: str,
                   success: bool, duration_ms: int = 0):
        """Record a playbook execution result."""
        self.mem.record_playbook_run(service, flow, success, duration_ms)

        # If the playbook succeeded, update last_verified
        if success:
            yaml_path = PLAYBOOKS_DIR / service / f"{flow}.yaml"
            if yaml_path.exists():
                try:
                    with open(yaml_path) as f:
                        pb = yaml.safe_load(f)
                    pb["last_verified"] = datetime.now(timezone.utc).isoformat()
                    with open(yaml_path, "w") as f:
                        yaml.dump(pb, f, default_flow_style=False,
                                  sort_keys=False, allow_unicode=True, width=120)
                except Exception:
                    pass  # non-critical

    # ════════════════════════════════════════════════════════════════════════
    # SELF-HEALING — auto-update selectors when they fail
    # ════════════════════════════════════════════════════════════════════════

    def heal_selector(self, service: str, flow: str, step_id: str,
                      old_selector: str, new_selector: str,
                      source: str = "snapshot") -> bool:
        """Update a broken selector in a playbook step.

        When Playwright can't find an element, the agent:
        1. Takes a browser_snapshot to see the current page
        2. Identifies the correct new selector from the snapshot
        3. Calls this method to patch the playbook

        The old selector is logged in selector_history for pattern detection.

        Args:
            service:      Service name
            flow:         Flow name
            step_id:      ID of the step with the broken selector
            old_selector: The selector that failed
            new_selector: The corrected selector from live page
            source:       How the fix was found (snapshot, computer_use, manual)

        Returns:
            True if the playbook was updated, False if step not found.
        """
        yaml_path = PLAYBOOKS_DIR / service / f"{flow}.yaml"
        if not yaml_path.exists():
            return False

        try:
            with open(yaml_path) as f:
                pb = yaml.safe_load(f)
        except Exception:
            return False

        # Find the step and update it
        updated = False
        for step in pb.get("steps", []):
            if step.get("id") == step_id:
                params = step.get("params", {})

                # Log the selector change in history
                if "selector_history" not in step:
                    step["selector_history"] = []
                step["selector_history"].append({
                    "old": old_selector,
                    "new": new_selector,
                    "source": source,
                    "healed_at": datetime.now(timezone.utc).isoformat(),
                })
                # Keep only last 5 history entries
                step["selector_history"] = step["selector_history"][-5:]

                # Update the selector in params (check common param keys)
                for key in ["field", "target", "selector", "element", "ref"]:
                    if key in params and params[key] == old_selector:
                        params[key] = new_selector
                        updated = True
                        break

                # If no exact match in params, try text replacement in all string values
                if not updated:
                    for key, val in params.items():
                        if isinstance(val, str) and old_selector in val:
                            params[key] = val.replace(old_selector, new_selector)
                            updated = True
                            break

                if updated:
                    step["last_healed"] = datetime.now(timezone.utc).isoformat()
                    step["heal_count"] = step.get("heal_count", 0) + 1
                break

        if updated:
            # Bump version and save
            pb["version"] = pb.get("version", 1) + 1
            pb["last_healed"] = datetime.now(timezone.utc).isoformat()
            with open(yaml_path, "w") as f:
                yaml.dump(pb, f, default_flow_style=False,
                          sort_keys=False, allow_unicode=True, width=120)

        return updated

    def heal_timing(self, service: str, flow: str, step_id: str,
                    actual_wait_ms: int, succeeded: bool) -> bool:
        """Auto-adjust wait/timeout durations based on execution history.

        Tracks actual wait times that led to success vs failure, then
        adjusts the step's timeout_ms to be ~1.5x the p90 successful wait.

        Args:
            service:        Service name
            flow:           Flow name
            step_id:        Step ID
            actual_wait_ms: How long the wait actually took
            succeeded:      Whether the step succeeded

        Returns:
            True if timing was adjusted, False otherwise.
        """
        yaml_path = PLAYBOOKS_DIR / service / f"{flow}.yaml"
        if not yaml_path.exists():
            return False

        try:
            with open(yaml_path) as f:
                pb = yaml.safe_load(f)
        except Exception:
            return False

        updated = False
        for step in pb.get("steps", []):
            if step.get("id") == step_id:
                # Track timing history
                if "timing_history" not in step:
                    step["timing_history"] = []
                step["timing_history"].append({
                    "wait_ms": actual_wait_ms,
                    "success": succeeded,
                    "at": datetime.now(timezone.utc).isoformat(),
                })
                # Keep last 20 entries
                step["timing_history"] = step["timing_history"][-20:]

                # Calculate optimal timeout from successful waits
                success_waits = [
                    t["wait_ms"] for t in step["timing_history"] if t["success"]
                ]
                if len(success_waits) >= 3:
                    success_waits.sort()
                    p90_idx = int(len(success_waits) * 0.9)
                    p90 = success_waits[min(p90_idx, len(success_waits) - 1)]
                    optimal = int(p90 * 1.5)  # 50% buffer over p90

                    params = step.get("params", {})
                    old_timeout = params.get("timeout_ms", step.get("timeout_ms"))
                    if old_timeout and abs(optimal - old_timeout) > old_timeout * 0.2:
                        # Only adjust if >20% difference
                        if "timeout_ms" in params:
                            params["timeout_ms"] = optimal
                        else:
                            step["timeout_ms"] = optimal
                        updated = True

                break

        if updated:
            with open(yaml_path, "w") as f:
                yaml.dump(pb, f, default_flow_style=False,
                          sort_keys=False, allow_unicode=True, width=120)

        return updated

    def get_fragile_steps(self, service: str = None) -> list[dict]:
        """Find playbook steps that break frequently (heal_count >= 3).

        These steps need a more robust selector strategy — switch from
        CSS selectors to role-based/label-based selectors, or add
        multiple fallback selectors.
        """
        results = []
        search_dirs = [PLAYBOOKS_DIR / service] if service else list(PLAYBOOKS_DIR.iterdir())

        for svc_dir in search_dirs:
            if not svc_dir.is_dir():
                continue
            for yaml_file in svc_dir.glob("*.yaml"):
                try:
                    with open(yaml_file) as f:
                        pb = yaml.safe_load(f)
                    for step in pb.get("steps", []):
                        heal_count = step.get("heal_count", 0)
                        if heal_count >= 3:
                            results.append({
                                "service": svc_dir.name,
                                "flow": yaml_file.stem,
                                "step_id": step.get("id", "?"),
                                "heal_count": heal_count,
                                "last_healed": step.get("last_healed"),
                                "history": step.get("selector_history", []),
                            })
                except Exception:
                    continue

        return sorted(results, key=lambda x: x["heal_count"], reverse=True)

    # ════════════════════════════════════════════════════════════════════════
    # LIST — show all cached playbooks
    # ════════════════════════════════════════════════════════════════════════

    def list_all(self) -> list[dict]:
        """List all playbooks with metadata from memory.db."""
        rows = self.mem.db.execute("""
            SELECT service, flow, version, success_count, fail_count,
                   last_status, last_run_at, generated_by, file_path
            FROM playbooks
            ORDER BY service, flow
        """).fetchall()
        return [dict(r) for r in rows]

    def list_services(self) -> list[str]:
        """List services that have cached playbooks."""
        # Combine disk and DB
        services = set()

        # From disk
        if PLAYBOOKS_DIR.exists():
            for d in PLAYBOOKS_DIR.iterdir():
                if d.is_dir() and d.name != ".gitkeep":
                    services.add(d.name)

        # From DB
        rows = self.mem.db.execute(
            "SELECT DISTINCT service FROM playbooks"
        ).fetchall()
        for r in rows:
            services.add(r["service"])

        return sorted(services)

    def list_flows(self, service: str) -> list[str]:
        """List available flows for a service."""
        flows = set()

        # From disk
        service_dir = PLAYBOOKS_DIR / service
        if service_dir.exists():
            for f in service_dir.glob("*.yaml"):
                flows.add(f.stem)

        # From DB
        rows = self.mem.db.execute(
            "SELECT DISTINCT flow FROM playbooks WHERE service = ?", (service,)
        ).fetchall()
        for r in rows:
            flows.add(r["flow"])

        return sorted(flows)

    def get_stats(self) -> dict:
        """Get overall playbook statistics."""
        row = self.mem.db.execute("""
            SELECT
                COUNT(DISTINCT service) as services,
                COUNT(*) as total_playbooks,
                SUM(success_count) as total_successes,
                SUM(fail_count) as total_failures
            FROM playbooks
        """).fetchone()
        return dict(row) if row else {}


# ═════════════════════════════════════════════════════════════════════════════
# CLI Interface
# ═════════════════════════════════════════════════════════════════════════════

def cli_list(engine: PlaybookEngine):
    playbooks = engine.list_all()
    if not playbooks:
        print("No playbooks cached yet.")
        print(f"\nPlaybook directory: {PLAYBOOKS_DIR}")
        print("Generate one: python3 playbook.py generate <service> <flow>")
        return

    print(f"{BOLD}Cached Playbooks{NC}")
    print()
    current_service = ""
    for pb in playbooks:
        if pb["service"] != current_service:
            current_service = pb["service"]
            print(f"  {BOLD}{current_service}{NC}")

        total = (pb["success_count"] or 0) + (pb["fail_count"] or 0)
        if total > 0:
            rate = (pb["success_count"] or 0) / total * 100
            status = f"runs={total} rate={rate:.0f}%"
        else:
            status = "never run"

        gen = pb.get("generated_by", "auto")
        print(f"    {pb['flow']:20s}  v{pb['version']}  {status:20s}  ({gen})")


def cli_get(engine: PlaybookEngine, service: str, flow: str):
    pb = engine.get(service, flow)
    if pb:
        print(yaml.dump(pb, default_flow_style=False, sort_keys=False,
                        allow_unicode=True, width=120))
    else:
        print(f"No playbook found for {service}/{flow}", file=sys.stderr)
        print(f"\nGenerate one: python3 playbook.py generate {service} {flow}",
              file=sys.stderr)
        sys.exit(1)


def cli_generate(engine: PlaybookEngine, service: str, flow: str):
    # Check if already exists
    existing = engine.get(service, flow)
    if existing:
        print(f"Playbook already exists for {service}/{flow} (v{existing.get('version', '?')})",
              file=sys.stderr)
        print(f"Use 'get' to view it, or delete the file to regenerate.",
              file=sys.stderr)
        sys.exit(1)

    # Generate skeleton
    pb = engine.generate(service, flow)

    # Save to disk
    path = engine.save(service, flow, pb, generated_by="cli")

    print(f"{GREEN}Generated{NC}: {path}")
    print()
    print(f"Steps ({len(pb['steps'])} pre-populated for '{flow}' flow):")
    for step in pb["steps"]:
        note = f"  {DIM}← {step['note']}{NC}" if step.get("note") else ""
        print(f"  {step['id']:30s}  {step['action']}{note}")
    print()
    print(f"Next: edit the YAML to fill in actual selectors from browser_snapshot")


def cli_stats(engine: PlaybookEngine):
    stats = engine.get_stats()
    print(f"{BOLD}Playbook Stats{NC}")
    print(f"  Services:    {stats.get('services', 0) or 0}")
    print(f"  Playbooks:   {stats.get('total_playbooks', 0) or 0}")
    print(f"  Successes:   {stats.get('total_successes', 0) or 0}")
    print(f"  Failures:    {stats.get('total_failures', 0) or 0}")
    print(f"  Directory:   {PLAYBOOKS_DIR}")


def cli_services(engine: PlaybookEngine):
    services = engine.list_services()
    if not services:
        print("No services with playbooks yet.")
        return
    print(f"{BOLD}Services with Playbooks{NC}")
    for svc in services:
        flows = engine.list_flows(svc)
        print(f"  {svc:20s}  flows: {', '.join(flows)}")


def cli_heal(engine: PlaybookEngine, service: str, flow: str,
             step_id: str, old_sel: str, new_sel: str):
    if engine.heal_selector(service, flow, step_id, old_sel, new_sel):
        print(f"{GREEN}Healed{NC}: {service}/{flow} step '{step_id}'")
        print(f"  {DIM}{old_sel}{NC} → {new_sel}")
    else:
        print(f"{RED}Failed{NC}: step '{step_id}' not found in {service}/{flow}",
              file=sys.stderr)
        sys.exit(1)


def cli_fragile(engine: PlaybookEngine, service: str = None):
    results = engine.get_fragile_steps(service)
    if not results:
        print("No fragile steps found. All selectors are stable.")
        return
    print(f"{BOLD}Fragile Steps{NC} (healed 3+ times — switch to role-based selectors)")
    print()
    for r in results:
        print(f"  {r['service']}/{r['flow']}  step={r['step_id']}  "
              f"healed={r['heal_count']}x  last={r.get('last_healed', 'unknown')}")


def main():
    usage = f"""Usage: python3 playbook.py <command> [args]

Commands:
  list                                  List all cached playbooks
  get <service> <flow>                  Show a playbook's YAML
  generate <service> <flow>             Generate a playbook skeleton
  services                              List services with playbooks
  stats                                 Show playbook statistics
  has <service> <flow>                  Check if playbook exists (exit 0/1)
  save <service> <flow> [yaml_file]      Save a playbook from YAML file (or stdin)
  record <service> <flow> <ok|fail> [ms] Record a playbook execution result
  heal <svc> <flow> <step> <old> <new>  Self-heal a broken selector
  fragile [service]                     Show steps that break frequently

Examples:
  python3 playbook.py generate vercel signup
  python3 playbook.py get vercel signup
  python3 playbook.py heal vercel login fill_email "input[name=email]" "#email-field"
  python3 playbook.py fragile
"""

    if len(sys.argv) < 2:
        print(usage)
        sys.exit(1)

    engine = PlaybookEngine()
    cmd = sys.argv[1]

    try:
        if cmd == "list":
            cli_list(engine)
        elif cmd == "get":
            if len(sys.argv) < 4:
                print("Usage: playbook.py get <service> <flow>", file=sys.stderr)
                sys.exit(1)
            cli_get(engine, sys.argv[2], sys.argv[3])
        elif cmd == "generate":
            if len(sys.argv) < 4:
                print("Usage: playbook.py generate <service> <flow>", file=sys.stderr)
                sys.exit(1)
            cli_generate(engine, sys.argv[2], sys.argv[3])
        elif cmd == "services":
            cli_services(engine)
        elif cmd == "stats":
            cli_stats(engine)
        elif cmd == "has":
            if len(sys.argv) < 4:
                print("Usage: playbook.py has <service> <flow>", file=sys.stderr)
                sys.exit(1)
            sys.exit(0 if engine.has(sys.argv[2], sys.argv[3]) else 1)
        elif cmd == "heal":
            if len(sys.argv) < 7:
                print("Usage: playbook.py heal <service> <flow> <step_id> <old_selector> <new_selector>",
                      file=sys.stderr)
                sys.exit(1)
            cli_heal(engine, sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6])
        elif cmd == "save":
            if len(sys.argv) < 4:
                print("Usage: playbook.py save <service> <flow> [yaml_file]", file=sys.stderr)
                print("  If no yaml_file, reads YAML from stdin.", file=sys.stderr)
                sys.exit(1)
            service, flow = sys.argv[2], sys.argv[3]
            if len(sys.argv) >= 5:
                with open(sys.argv[4]) as f:
                    pb = yaml.safe_load(f)
            else:
                pb = yaml.safe_load(sys.stdin)
            if not pb:
                print(f"{RED}Error:{NC} Empty or invalid YAML", file=sys.stderr)
                sys.exit(1)
            path = engine.save(service, flow, pb, generated_by="agent")
            print(f"{GREEN}Saved:{NC} {service}/{flow} -> {path}")
        elif cmd == "record":
            if len(sys.argv) < 5:
                print("Usage: playbook.py record <service> <flow> <ok|fail> [duration_ms]", file=sys.stderr)
                sys.exit(1)
            service, flow = sys.argv[2], sys.argv[3]
            success = sys.argv[4].lower() in ("ok", "success", "true", "1")
            duration_ms = int(sys.argv[5]) if len(sys.argv) >= 6 else 0
            engine.record_run(service, flow, success, duration_ms)
            status = f"{GREEN}ok{NC}" if success else f"{RED}fail{NC}"
            print(f"Recorded: {service}/{flow} [{status}]")
        elif cmd == "fragile":
            svc = sys.argv[2] if len(sys.argv) > 2 else None
            cli_fragile(engine, svc)
        else:
            print(f"Unknown command: {cmd}", file=sys.stderr)
            print(usage, file=sys.stderr)
            sys.exit(1)
    finally:
        engine.close()


if __name__ == "__main__":
    main()
