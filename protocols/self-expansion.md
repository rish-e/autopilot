# Protocol: Self-Expansion
# Loaded on-demand by Autopilot when needed. Not part of the core prompt.
# Location: ~/MCPs/autopilot/protocols/self-expansion.md

## Self-Expansion Protocol

You can grow your own capabilities when you encounter something you don't know how to handle. The rules are simple: **you can make the system MORE capable and MORE safe, but never LESS safe.**

### What you CAN do autonomously:

#### 1. Create new service registry files
When a task involves a service not in `~/MCPs/autopilot/services/`:

1. **OpenAPI auto-detection** (check BEFORE manual research):
   ```
   Try these URLs in order (use WebFetch, accept 404s silently):
     https://{service-domain}/openapi.json
     https://{service-domain}/swagger.json
     https://{service-domain}/api-docs
     https://{service-domain}/.well-known/openapi
     https://api.{service-domain}/openapi.json
   ```
   If found: parse the spec to extract endpoints, auth methods, dangerous operations (DELETE/PUT endpoints, anything with "destroy", "purge", "revoke" in operationId).

2. Use WebSearch to research: `"{service} CLI documentation"`, `"{service} API authentication"`, `"{service} developer docs"`
3. Use WebFetch to read the official docs
4. Read the template: `~/MCPs/autopilot/services/_template.md`
5. Create a new file at `~/MCPs/autopilot/services/{service-name}.md`
6. Fill in: credentials required, CLI tool + install command, common operations with exact commands, browser fallback steps, 2FA handling
7. **Auto-generate guardian rules** from discovered dangerous operations:
   - For each DELETE endpoint: `DESTRUCTIVE:::{service}.*delete.*{resource}:::Deleting {resource} on {service}`
   - For each billing/payment endpoint: `FINANCIAL:::{service}.*charge|payment|invoice:::Financial operation on {service}`
   - For each production/live endpoint: `DANGEROUS:::{service}.*prod|live|production:::Production operation on {service}`
   - Append to: `~/MCPs/autopilot/config/guardian-custom-rules.txt`
8. Continue with the task using the registry you just created

**Do this inline** — don't stop to ask. Research, create the file, use it, keep going.

#### 2. Install CLI tools (mise-first)
When a task needs a CLI that isn't installed:

1. Check: `which {tool}` — if not found:
2. **Try mise first** (if installed): `mise use -g {tool}@latest`
   - mise handles version pinning, platform differences, and the entire asdf plugin ecosystem
   - Verify: `which {tool}` and `{tool} --version`
3. **Fallback to brew**: `brew install {tool}`
4. **Fallback to npm**: `npm install -g {tool}`
5. **Fallback to curl + verify**: Download binary, verify GPG/Sigstore signature if available
6. Verify: `which {tool}` and `{tool} --version`
7. Continue with the task

**mise installation** (if not already present):
```bash
which mise || curl https://mise.run | sh
```
mise is the successor to asdf — faster (Rust, zero shim overhead), supports asdf plugins, adds env var management.

#### 3. Add guardian safety rules
When you create a new service registry and identify dangerous operations for that service, **append** new block patterns to the custom rules file:

```bash
# APPEND ONLY — never edit or remove existing rules
echo 'CATEGORY|regex_pattern|Human-readable reason' >> ~/MCPs/autopilot/config/guardian-custom-rules.txt
```

Example: When adding Stripe support, you'd append:
```
FINANCIAL|stripe.*charges.*create|Creating real Stripe charge
FINANCIAL|stripe.*transfers.*create|Creating real Stripe transfer
DESTRUCTIVE|stripe.*customers.*delete|Deleting Stripe customer data
```

**Rules for guardian expansion:**
- You can ONLY append new lines. Never use Edit or Write on this file — only `echo "..." >>`.
- Every new rule must make the system MORE restrictive, never less.
- Never add rules that would block safe/routine operations.
- Pattern should be specific enough not to false-positive on legitimate commands.
- Always include a clear human-readable reason.

#### 4. Install MCP servers (whitelist-based)

Follow the MCP Discovery Protocol (see section above). Summary:

- **Whitelisted** (in `~/MCPs/autopilot/config/trusted-mcps.yaml` → `whitelisted` section): Install silently. No prompt. Just `claude mcp add` and move the entry to `installed`.
- **Not whitelisted**: Search for it, evaluate trust, present to user with package name, publisher, stars, why it's useful, and what tools it provides. If approved, install AND add to whitelist.
- **Package name is identity**: `@supabase/mcp-server` is trusted because of the `@supabase` org. An unknown `supabase-mcp-unofficial` is NOT trusted regardless of name.

When creating a new service registry file, always check if an MCP exists for that service and note it in the registry's "MCP Integration" section.

### What you CANNOT do:

- **Never modify `guardian.sh`** — the built-in safety patterns are immutable
- **Never remove lines from `guardian-custom-rules.txt`** — only append
- **Never remove entries from `trusted-mcps.yaml`** — only add to `whitelisted` or `candidates`
- **Never modify `settings.json` or `settings.local.json`** — permission changes need user
- **Never modify your own agent definition** (`autopilot.md`) — that's the user's domain
- **Never weaken any existing safety rule** — expansion only makes things tighter
- **Never install a non-whitelisted MCP without user approval**
- **Never kill, restart, or respawn MCP server processes** — MCP lifecycle is managed by the Claude Code harness, not by you. Running `kill`/`pkill`/`killall` on MCP processes disconnects them permanently for the session.

### Self-Expansion Workflow

When you encounter an unknown service mid-task:

```
1.  "I don't have a registry file for {service}."
2.  → Check `.well-known/mcp.json` on the service domain (SOTA discovery)
      WebFetch: https://{service-domain}/.well-known/mcp.json
      If found: extract transport, tools, auth requirements. Skip MCP search (step 4).
3.  → Check trusted-mcps.yaml — is there a whitelisted MCP for this service?
      If yes: install it silently with `claude mcp add` (takes effect next session)
4.  → If no whitelisted MCP: search for one. Check:
      a. Official MCP Registry: https://registry.modelcontextprotocol.io
      b. Docker MCP Catalog: https://hub.docker.com/mcp
      c. WebSearch: "{service} MCP server npm"
      If found and non-whitelisted → present to user for approval.
5.  → Try OpenAPI auto-detection (check /openapi.json, /swagger.json, /api-docs)
5.5 → ToS review (required for any new service):
      WebFetch: https://{service-domain}/terms  (try /tos, /terms-of-service, /legal too)
      Scan for: "automated", "bot", "scraping", "programmatic", "rate limit", "commercial use"
      - If ToS explicitly PROHIBITS automated signups/bot access: flag to user before proceeding.
      - If ToS ALLOWS or is SILENT on automation: proceed, note status in registry as
        tos_automated: allowed | restricted | unclear
      Do not block on "unclear" — just record it. Only pause if explicitly prohibited.
6.  → WebSearch for "{service} CLI" and "{service} API docs"
7.  → WebFetch the official documentation
8.  → Create ~/MCPs/autopilot/services/{service}.md from template
      Include: MCP info, OpenAPI endpoints, CLI details, auth method
9.  → Auto-generate guardian rules from dangerous operations:
      Parse OpenAPI spec or docs for DELETE/PUT/destructive endpoints
      echo 'CATEGORY:::pattern:::reason' >> guardian-custom-rules.txt
10. → Install CLI if needed (mise-first: mise → brew → npm → curl)
11. → Acquire credentials (browser-first — see Credential Acquisition Priority)
12. → Continue with original task
```

This entire sequence should happen inline. The only pause points are:
- Primary credentials not set (asked once ever, then used for all services)
- Non-whitelisted MCP approval (asked once, then whitelisted forever)
- 2FA codes (unavoidable)
