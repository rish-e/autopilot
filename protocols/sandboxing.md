# Protocol: OS-Level Sandboxing
# Loaded on-demand when evaluating additional safety layers.
# Location: ~/MCPs/autopilot/protocols/sandboxing.md

### Kernel Sandboxing — Second Safety Layer Beyond Guardian

**Purpose**: Guardian blocks dangerous *commands* via pattern matching. Sandboxing restricts what *any* command can do at the OS level — even if it slips past guardian.

### macOS Sandboxing Options

#### 1. sandbox-exec (Built-in, Recommended)

macOS ships with `sandbox-exec` — a built-in command that applies Seatbelt sandbox profiles to processes. No installation required.

**How it works:**
```bash
sandbox-exec -f /path/to/profile.sb /bin/bash -c "command here"
```

**Profile format (Scheme-based):**
```scheme
(version 1)
(deny default)                          ; Deny everything by default

; Allow read access to project directory
(allow file-read* (subpath "/Users/you/project"))

; Allow write only to project dir and /tmp
(allow file-write* (subpath "/Users/you/project"))
(allow file-write* (subpath "/private/tmp"))

; Allow network to whitelisted domains only
(allow network-outbound (remote tcp "*:443"))
(allow network-outbound (remote tcp "localhost:*"))

; Allow process execution (needed for CLI tools)
(allow process-exec*)
(allow process-fork)

; Allow reading system libraries, binaries, etc.
(allow file-read* (subpath "/usr"))
(allow file-read* (subpath "/bin"))
(allow file-read* (subpath "/Library"))
(allow file-read* (subpath "/System"))
(allow file-read* (subpath "/opt/homebrew"))
```

**Pros:**
- Built into macOS, no installation
- Kernel-enforced (can't be bypassed by the process)
- Fine-grained file, network, and IPC control
- No Docker, no VMs, no containers

**Cons:**
- Apple deprecated the public API (still works but undocumented)
- Profile syntax is Scheme-based, not intuitive
- Network filtering is port-based, not domain-based (can't whitelist github.com directly)
- May break some CLI tools that access unexpected paths

#### 2. macOS App Sandbox (Not Suitable)

The App Sandbox is for GUI apps distributed through the App Store. Not applicable for CLI agent use.

#### 3. Docker/OrbStack (Heavy)

Full container isolation. Works but adds 200MB+ overhead, startup latency, and complexity. Only worth it if running untrusted code.

### Recommended Approach

**Use `sandbox-exec` with auto-generated Seatbelt profiles.** It's built-in, kernel-enforced, and adds zero dependencies.

### Integration with Guardian

```
Command arrives
    ↓
[Guardian] Pattern match → block obvious dangers
    ↓
[Decision Level check]
    ├── L1-L2: Execute normally (no sandbox overhead)
    └── L3+: Wrap in sandbox-exec with restricted profile
        ↓
        sandbox-exec -f .autopilot/sandbox-L3.sb bash -c "command"
```

### Sandbox Profiles for Autopilot

#### L3 Profile (Production deploys, destructive ops)
```scheme
; .autopilot/sandbox-L3.sb
(version 1)
(deny default)

; Read: project, system libs, homebrew, temp
(allow file-read* (subpath "{PROJECT_DIR}"))
(allow file-read* (subpath "/usr"))
(allow file-read* (subpath "/bin"))
(allow file-read* (subpath "/Library"))
(allow file-read* (subpath "/System"))
(allow file-read* (subpath "/opt/homebrew"))
(allow file-read* (subpath "/private/tmp"))
(allow file-read* (subpath "{HOME}/.config"))
(allow file-read* (subpath "{HOME}/.npm"))
(allow file-read* (subpath "{HOME}/.cache"))

; Write: only project dir and temp
(allow file-write* (subpath "{PROJECT_DIR}"))
(allow file-write* (subpath "/private/tmp"))

; Network: HTTPS only
(allow network-outbound (remote tcp "*:443"))
(allow network-outbound (remote tcp "*:80"))
(allow network-outbound (remote tcp "localhost:*"))

; Process: allow execution
(allow process-exec*)
(allow process-fork)
(allow sysctl-read)
(allow mach-lookup)
```

#### L4 Profile (Financial, messaging — more restrictive)
```scheme
; .autopilot/sandbox-L4.sb — same as L3 but no network write
(version 1)
(deny default)

; Read: project and system only
(allow file-read* (subpath "{PROJECT_DIR}"))
(allow file-read* (subpath "/usr"))
(allow file-read* (subpath "/bin"))
(allow file-read* (subpath "/Library"))
(allow file-read* (subpath "/System"))
(allow file-read* (subpath "/opt/homebrew"))

; Write: only temp (no project modification)
(allow file-write* (subpath "/private/tmp"))

; Network: localhost only (no external)
(allow network-outbound (remote tcp "localhost:*"))

; Process: allow but restricted
(allow process-exec*)
(allow process-fork)
(allow sysctl-read)
(allow mach-lookup)
```

### Implementation Steps

1. **Generate profiles at session start**: Substitute `{PROJECT_DIR}` and `{HOME}` in templates
2. **Guardian integration**: After guardian allows a command, check decision level. If L3+, wrap with `sandbox-exec`
3. **Fallback**: If `sandbox-exec` fails (profile too restrictive), retry without sandbox and log a warning
4. **Testing**: Run `sandbox-exec -f profile.sb bash -c "ls /"` to verify profiles work

### Risks and Trade-offs

| Risk | Mitigation |
|------|-----------|
| sandbox-exec is deprecated by Apple | Still works on macOS 15+. Monitor for removal in future releases |
| CLI tools may fail (unexpected path access) | Start with permissive profiles, tighten over time based on logs |
| Network filtering is port-based, not domain | Guardian handles domain allowlisting, sandbox handles port restriction |
| Profile maintenance | Auto-generate from guardian-rules.yaml egress_allowlist |
| Performance overhead | <10ms per command (negligible vs. network latency) |

### When to Use

- **Always**: When Autopilot runs in production environments or handles sensitive data
- **Optional**: For development/testing (adds safety but slight overhead)
- **Skip**: When running in CI/CD where Docker isolation is already present
