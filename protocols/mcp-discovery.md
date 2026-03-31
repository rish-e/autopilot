# Protocol: MCP Discovery
# Loaded on-demand by Autopilot when needed. Not part of the core prompt.
# Location: ~/MCPs/autopilot/protocols/mcp-discovery.md

## MCP Discovery Protocol

Before falling back to CLI or browser, check if an MCP server exists that would do a better job. MCPs are superior to CLIs because they provide structured tool calls, type safety, and direct integration — no shell parsing, no output scraping.

### Step 0: Check `.well-known/mcp.json` (SOTA)

Before any registry search, check if the service itself publishes MCP capabilities:

```bash
# Try the service's own domain
WebFetch https://{service-domain}/.well-known/mcp.json
```

If found, the response contains: transport type (SSE/stdio/streamable), available tools, auth requirements, and protocol version. This is the most authoritative source — skip to installation.

As of March 2026, Replicate ships this. The MCP spec has active enhancement proposals (SEP-1649, SEP-1960) to standardize this.

### Step 1: Check the whitelist

Read `~/MCPs/autopilot/config/trusted-mcps.yaml`. Check both `installed` and `whitelisted` sections.

- **Already installed?** → Use it. Done.
- **On the whitelist but not installed?** → Install it silently (Step 2). No need to ask the user.
- **Not on the whitelist?** → Search for it (Step 3).

### Step 2: Silent install (whitelisted MCPs)

For MCPs on the whitelist, install without asking:

```bash
# For npm packages:
claude mcp add {name} -- npx -y {package}

# If the MCP needs an API token, get it from keychain or acquire via browser first:
claude mcp add {name} -e API_KEY="$(~/MCPs/autopilot/bin/keychain.sh get {service} api-token)" -- npx -y {package}
```

**Pre-install security scan** (if mcp-scan is available):
```bash
# Check for known vulnerabilities before installing
which mcp-scan && mcp-scan --package {package} 2>/dev/null
# If scan reports critical vulnerabilities → block install, present to user
# If scan reports warnings → install but notify user
# If mcp-scan not installed → proceed (install it later: pip3 install mcp-scan)
```

After installing:
- Move the entry from `whitelisted` to `installed` in the YAML
- Note: The MCP takes effect next session. Fall back to CLI/browser for the current task.
- Notify the user: "Installed {name} MCP for future use. Using CLI for now."

### Step 3: Search for non-whitelisted MCPs

When a service isn't on the whitelist, search in this order:

1. **Official MCP Registry**: `https://registry.modelcontextprotocol.io`
   - Uses namespace authentication (reverse DNS: `io.github.username/server`)
   - Tied to verified GitHub accounts or domains
   - 10,000+ active servers as of March 2026

2. **Docker MCP Catalog**: `https://hub.docker.com/mcp`
   - 300+ verified servers as container images
   - Two tiers: Docker-built (cryptographic signatures, SBOMs, provenance attestations) and community-built
   - Prefer Docker-built servers — they have continuous vulnerability scanning

3. **npm / WebSearch fallback**: `"{service} MCP server"` or `"{service} model context protocol"`

4. **Evaluate** what you find:
   - **Package name**: exact npm package or GitHub repo
   - **Publisher**: who made it? Official service provider? Anthropic? Unknown?
   - **Namespace verification**: `@supabase/mcp-server` is trusted (verified org). `supabase-mcp-unofficial` is NOT.
   - **Activity**: GitHub stars, last commit date, download count
   - **Provenance**: Check Sigstore/npm attestations if available (ToolHive pattern)
   - **Capabilities**: what tools does it expose? Does it cover what we need?

5. **Security scan** before presenting to user:
   ```bash
   which mcp-scan && mcp-scan --package {package} 2>/dev/null
   ```

6. **If found — present to user** with this format:

   ```
   Found MCP: {name}
   Package: {npm package or repo URL}
   Publisher: {who}
   Registry: {official MCP registry | Docker catalog | npm}
   Stars/Downloads: {numbers}
   Verified: {yes/no — namespace verification or provenance attestation}
   Security scan: {clean | N warnings | N critical | not scanned}
   Last updated: {date}

   Why: {specific reason this MCP is better than CLI/browser for the current task}
   Tools it provides: {list of key tools}

   Install command: claude mcp add {name} -- npx -y {package}

   Want me to install it?
   ```

7. **If user approves**: Install it AND add to the `whitelisted` section in trusted-mcps.yaml (so it's auto-approved forever).

8. **If user declines**: Add to the `candidates` section with a note, then fall back to CLI/browser.

9. **If nothing found**: Fall back to CLI/browser. Do not mention the search to the user — just proceed.

### When to trigger MCP discovery

Don't search for MCPs on every task. Only search when:
- You're about to use CLI/browser for a service you'll interact with **repeatedly** (not a one-off command)
- The service has complex operations that would benefit from structured tool calls (databases, payment providers, infrastructure)
- You're creating a new service registry file (natural time to check for MCPs too)

Do NOT search when:
- The task is a quick one-off (just use CLI)
- An MCP is already installed for this service
- You're in the middle of a time-sensitive operation (search later)

### Trust rules

- **Never install an MCP that isn't on npm or a verifiable GitHub repo**
- **Never install from a fork** when an official version exists
- **Package name is the identity** — `@supabase/mcp-server` is trusted because it's the `@supabase` org, not because it's called "supabase"
- **If the package name doesn't match the org you'd expect** (e.g., a Stripe MCP not from `@stripe`), treat it as untrusted and ask the user
- **Prefer `@modelcontextprotocol/` prefix** — maintained by the Agentic AI Foundation (Linux Foundation)
- **Check npm provenance attestations** when available — cryptographic proof the package was built from its stated source repo
- **Docker-built MCP servers** have higher trust than community-built: they include SBOMs, Sigstore signatures, and continuous vulnerability scanning
- **30 CVEs in 60 days** (early 2026) — the MCP ecosystem has real security risks. Always scan before installing unknown packages.
