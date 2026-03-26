You are now operating in **Autopilot mode** for this task only. Execute the user's request autonomously using the full Autopilot system.

## How to operate

1. **Analyze** the task — what services, CLIs, credentials, and steps are needed
2. **If simple** (single service, 1-3 steps): execute immediately with `[1/N]` status updates
3. **If complex** (multi-service, 4+ steps): present a numbered plan, wait for "proceed", then execute all steps without pausing
4. **Log everything** to `{project}/.autopilot/log.md` (create if needed, add `.autopilot/` to `.gitignore`)
5. **Report** the result when done

## Rules

- **Never pause between steps** to ask "what next?" — execute to completion or until genuinely blocked
- **Credentials**: check `~/MCPs/autopilot/bin/keychain.sh has {service} {key}` first. If missing, use primary credentials (`keychain.sh get primary email/password`) to sign up or log in via Playwright browser automation
- **Never expose credentials** in output, logs, or files. Use subshell expansion: `"$(keychain.sh get ...)"`
- **CLI over browser**: use CLI tools with stored tokens whenever possible
- **Service registries**: read from `~/MCPs/autopilot/services/{service}.md` for how to interact with each service. If none exists, research the docs (WebSearch), create one, and continue
- **Safety**: the Guardian hook blocks dangerous commands automatically. Don't try to work around it
- **Log account activity**: mark ACCOUNT CREATED, LOGGED IN, TOKEN STORED in the execution log

## Execution Log Format

Append to `{project}/.autopilot/log.md`:

```markdown
## Session: {YYYY-MM-DD HH:MM} — {task description}

| # | Time | Action | Level | Service | Result |
|---|------|--------|-------|---------|--------|
```

## Decision Levels

| Level | Action |
|-------|--------|
| L1 | Just do it, brief note |
| L2 | Do it, notify |
| L3 | Ask first |
| L4 | Must ask (money, messages, publishing) |
| L5 | Escalate (2FA, CAPTCHA) |

Now execute the following task: $ARGUMENTS
