# GUI Automation Protocol (macOS only)

AppleScript bridges the gap between CLI/browser automation and full Computer Use. It's fast, reliable, and operates via app scripting APIs rather than pixel-clicking.

---

## When to Use AppleScript

Use AppleScript when ALL of the following are true:
1. The target is a **native macOS app** (not a website)
2. The app has **no CLI, no public API, no MCP**
3. The action is something AppleScript can do (open, focus, quit, click buttons, read/write clipboard)

Do NOT use AppleScript for:
- Websites or services that have a web interface → use Playwright
- Apps that can be controlled via CLI (Xcode → xcodebuild, git, etc.) → use CLI
- Complex visual interactions (drag-to-resize, canvas work) → use Computer Use

---

## macOS-Only Guard

**Always check at runtime before using osascript:**
```bash
if [[ "$(uname -s)" != "Darwin" ]]; then
    log "GUI automation not available on this platform — skipping AppleScript step"
    # Fall back to CLI/browser equivalent or skip
fi
```

`osascript.sh` does this check automatically and exits with code 4 if not macOS.

---

## Service Interaction Priority (GUI tasks)

For native app operations, try in this order:

1. **CLI** — e.g., `xcodebuild`, `open -a AppName`, `defaults write ...`
2. **AppleScript** (via `osascript.sh`) — scripting dictionary APIs, button clicks, app control
3. **Computer Use** — only for pixel-level UI that AppleScript can't reach
4. **Ask User** — last resort

---

## Running Scripts

Always use `osascript.sh run` — never call `osascript` directly.

```bash
# Open and focus an app
~/MCPs/autopilot/bin/osascript.sh run app-control open "Figma"
~/MCPs/autopilot/bin/osascript.sh run app-control focus "com.figma.Desktop"

# Get frontmost app context
~/MCPs/autopilot/bin/osascript.sh run frontmost-info
# → {"app":"Figma","bundle_id":"com.figma.Desktop","window_title":"My Project","windows":1,"pid":5432}

# Click a dialog button
~/MCPs/autopilot/bin/osascript.sh run handle-system-dialog "Replace"
~/MCPs/autopilot/bin/osascript.sh run handle-system-dialog "Allow"

# Clipboard
~/MCPs/autopilot/bin/osascript.sh run clipboard get
~/MCPs/autopilot/bin/osascript.sh run clipboard set "text to paste"
~/MCPs/autopilot/bin/osascript.sh run clipboard clear
```

---

## Available Scripts

| Script | Purpose | Args |
|--------|---------|------|
| `app-control` | Open / focus / quit / status / relaunch apps | `<verb> <app-name-or-bundle-id>` |
| `handle-system-dialog` | Click a button in a frontmost dialog or sheet | `<button-label>` |
| `clipboard` | Read or write clipboard text | `get` / `set <value>` / `clear` |
| `frontmost-info` | JSON: app name, bundle ID, window title, PID | (none) |

---

## Permissions Required

AppleScript requires two separate macOS permissions. First run will often trigger a system prompt — escalate to user if these aren't granted.

### 1. Automation Permission
Needed for `tell application "X" to ...` (app scripting).

**How it works:** macOS prompts once per (controller app, target app) pair. Claude Code / Terminal must be authorized to send events to each target app.

**Grant path:** System Settings → Privacy & Security → Automation → Allow "Terminal" or "Claude Code" to control target apps.

**How to detect:**
```
execution error: Not authorized to send Apple events to X. (-1743)
```
→ Exit code 2 from `osascript.sh`
→ Escalate: "Please open System Settings → Privacy & Security → Automation and allow [Terminal/Claude Code] to control [App Name]."

### 2. Accessibility Permission
Needed for UI scripting via `System Events` (clicking buttons, reading window titles, etc.).

**Grant path:** System Settings → Privacy & Security → Accessibility → Add Terminal or Claude Code.

**How to detect:**
```
execution error: Accessibility access not granted. (-25211)
execution error: Not authorized to send Apple events to System Events. (-1743)
```
→ Exit code 2 from `osascript.sh`
→ Escalate: "Please open System Settings → Privacy & Security → Accessibility and add Terminal (or Claude Code) to the list."

### Permission Check
```bash
~/MCPs/autopilot/bin/osascript.sh info
```
Shows accessibility status and available scripts.

---

## Error Handling

`osascript.sh` exit codes:
| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Script error (app not running, element not found, etc.) |
| 2 | Permission denied (needs Accessibility or Automation grant) |
| 3 | Timeout (exceeded 30s) |
| 4 | Not macOS — skip gracefully |
| 5 | Bad usage / script not found |

**On exit code 2:** Always escalate to user with specific grant instructions. Do not retry — permission prompts require human action.

**On exit code 1 (app not running):** Try `osascript.sh run app-control open "AppName"` first, then retry.

**On exit code 3 (timeout):** The app may be frozen or waiting for input. Check with `frontmost-info`, then try Computer Use if the dialog is visible.

---

## Adding New Scripts

Place `.applescript` files in `~/MCPs/autopilot/applescripts/`. Guardian whitelists this directory. Files outside it will be blocked.

Script conventions:
- Use `on run argv` with positional arguments
- Return structured text (JSON-like) for machine parsing
- Never use `do shell script` — blocked by guardian
- Handle missing value from System Events gracefully
- Target apps by bundle ID when possible (more stable than display names)

Guardian will block any `osascript` invocation that:
- Uses inline `-e` flag (arbitrary inline scripts)
- Uses `-l JavaScript` (JXA)
- References files outside `~/MCPs/autopilot/applescripts/`
