# Protocol: Credential Management
# Loaded on-demand by Autopilot when needed. Not part of the core prompt.
# Location: ~/MCPs/autopilot/protocols/credential-management.md

**HARD RULE: Never attempt any login or signup without primary credentials. Run preflight.sh first.**

## Credential Management

### Primary Credentials

A master email and password stored in Keychain, used as the default for signing up and logging into any service:

```bash
# Check if primary credentials are set
~/MCPs/autopilot/bin/keychain.sh has primary email
~/MCPs/autopilot/bin/keychain.sh has primary password

# Set primary credentials (one-time setup — user provides these once ever)
echo "{email}" | ~/MCPs/autopilot/bin/keychain.sh set primary email
echo "{password}" | ~/MCPs/autopilot/bin/keychain.sh set primary password
```

**First-time setup**: If no primary credentials exist when the agent first needs them, run `~/MCPs/autopilot/bin/preflight.sh setup` which will interactively collect the email and password and store them in macOS Keychain. This only happens once.

### Username Preferences

Preferred usernames stored in Keychain, organized by priority and context. The agent tries them in order when signing up for new services.

```bash
# Professional usernames (for work tools: GitHub, Vercel, AWS, Supabase, Stripe, etc.)
~/MCPs/autopilot/bin/keychain.sh get usernames professional-primary
~/MCPs/autopilot/bin/keychain.sh get usernames professional-secondary
~/MCPs/autopilot/bin/keychain.sh get usernames professional-tertiary

# Casual usernames (for everything else: social tools, community platforms, etc.)
~/MCPs/autopilot/bin/keychain.sh get usernames casual-primary
~/MCPs/autopilot/bin/keychain.sh get usernames casual-secondary
~/MCPs/autopilot/bin/keychain.sh get usernames casual-tertiary
```

**Context detection**: Choose professional or casual based on the service:
- **Professional**: GitHub, GitLab, Vercel, Netlify, AWS, Supabase, Stripe, Cloudflare, Sentry, Datadog, Railway, Fly.io, Firebase, Azure, GCP, npm, Docker Hub, any enterprise/work tool
- **Casual**: Everything else (community platforms, social tools, forums, creative services)

**Username selection when signing up**:
1. Try the primary username for the detected context (professional or casual)
2. If taken → try secondary
3. If taken → try tertiary
4. If all three are taken → append a short number to the primary (e.g., `rishi-k42`), never a long random string

**First-time setup**: If no usernames are stored when first needed, ask the user ONCE: "I need your preferred usernames for signing up to services. Give me 3 professional and 3 casual options in order of preference." Store all six, then never ask again.

**Never generate random usernames** like `rishi-2160504210`. Always use the stored preferences first.

### Credential Discovery Chain (AWS SDK-inspired)

For each service, try to find existing credentials in this order (inspired by the boto3 credential provider chain):

```
1. AUTOPILOT KEYCHAIN    — keychain.sh has {service} api-token
2. WELL-KNOWN CONFIG     — service-specific config file paths:
   ┌──────────────┬────────────────────────────────────────────────┐
   │ Service      │ Config Location                                │
   ├──────────────┼────────────────────────────────────────────────┤
   │ AWS          │ ~/.aws/credentials, ~/.aws/config              │
   │ Docker       │ ~/.docker/config.json (credsStore helper)      │
   │ Kubernetes   │ ~/.kube/config                                 │
   │ GitHub       │ gh auth token (OS credential store)            │
   │ Terraform    │ ~/.terraformrc, env vars                       │
   │ npm          │ ~/.npmrc (authToken)                           │
   │ GCloud       │ ~/.config/gcloud/                              │
   │ Vercel       │ ~/.vercel/auth.json                            │
   │ Supabase     │ ~/.config/supabase/access-token                │
   │ SSH          │ ~/.ssh/id_*, ~/.ssh/config                     │
   └──────────────┴────────────────────────────────────────────────┘
3. ENVIRONMENT VARS      — check standard env vars (AWS_ACCESS_KEY_ID, GITHUB_TOKEN, etc.)
4. CLI AUTH STATUS       — gh auth status, vercel whoami, supabase status
5. macOS KEYCHAIN        — security find-generic-password -l {service}
6. BROWSER ACQUISITION   — login + generate token via playbook
7. ASK USER              — absolute last resort
```

This chain is implemented by `harvest.sh` (steps 1-5) and the Credential Resolution Cascade (steps 1-7).

### Acquisition Priority (how to GET credentials)

**Use the Credential Resolution Cascade defined in the Adaptive Resolution Engine section above.** The 7-step cascade (keychain → harvest → CLI auth → browser session → browser login → generate token → ask user) is the ONLY way to acquire credentials. Never skip steps. Never ask the user before exhausting steps 1-6.

**The user should NEVER have to go to a dashboard, copy a token, sign up, or paste anything.** That's your job.

### Storage (keychain wrapper)

```bash
# Read a credential (use in subshell expansion — NEVER echo)
export TOKEN=$(~/MCPs/autopilot/bin/keychain.sh get {service} {key})
command --token "$TOKEN"
unset TOKEN

# Store a credential (from browser acquisition or user input)
echo "{value}" | ~/MCPs/autopilot/bin/keychain.sh set {service} {key}

# Check existence
~/MCPs/autopilot/bin/keychain.sh has {service} {key}
```

### Token Harvesting

Use `~/MCPs/autopilot/bin/harvest.sh` to automatically discover and import tokens from the local machine.

```bash
# Scan all known services and import what's found
~/MCPs/autopilot/bin/harvest.sh

# Scan a specific service
~/MCPs/autopilot/bin/harvest.sh vercel

# Check what's in keychain vs what's discoverable
~/MCPs/autopilot/bin/harvest.sh status

# Dry run — show what would be imported
~/MCPs/autopilot/bin/harvest.sh scan
```

The harvest script scans: Vercel CLI config, GitHub CLI keychain, Supabase CLI config, npm registry tokens, Docker config, Cloudflare wrangler config, .netrc, macOS Keychain entries, and common config patterns for any service in memory.db.

**When to harvest:**
- **At the start of every session** — run `harvest.sh` silently during pre-flight checks
- After any interactive login step completes (user says "done" or "I logged in")
- When encountering a new service (harvest.sh checks common paths dynamically)

**For unknown services**, harvest.sh also scans common patterns:
- `~/.config/{service}/`
- `~/Library/Application Support/{service}/`
- `~/.{service}/`
- macOS Keychain entries matching the service name

### Credential TTL & Rotation

Keychain now tracks when each credential was stored/updated. Use TTL tracking to detect stale credentials that may need rotation.

```bash
# Check age of a specific credential
~/MCPs/autopilot/bin/keychain.sh age {service} {key}

# Show all credentials older than 90 days (default)
~/MCPs/autopilot/bin/keychain.sh check-ttl

# Show all credentials older than 30 days
~/MCPs/autopilot/bin/keychain.sh check-ttl 30

# Quick report via harvest
~/MCPs/autopilot/bin/harvest.sh age
```

**When to check TTL:**
- At the start of every session (part of pre-flight)
- After an authentication failure (credential may have expired)
- Monthly review (proactive rotation)

**Recommended rotation periods:**
- API tokens: 90 days
- OAuth tokens: check provider's expiry (often 30-90 days)
- Primary credentials: 180 days
- SSH keys: 365 days

**When a credential is flagged as stale:**
1. Attempt to use it first — it may still work
2. If it fails → re-acquire via the Credential Resolution Cascade
3. The `keychain.sh set` command automatically updates the TTL timestamp

### Hard Rules
- **NEVER** print, echo, log, or display credential values
- **NEVER** store credentials in .env files, config files, or any file (use keychain only)
- **NEVER** include credentials in git commits
- **NEVER** pass credentials as CLI arguments (use env vars or stdin)
- **ALWAYS** unset credential env vars after use
- **ALWAYS** use `"$(keychain.sh get ...)"` subshell pattern — quotes included
- When setting up a project's `.env` or `.env.local`, inject values from keychain at runtime — never hardcode them
