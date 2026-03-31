# Service Registry Index

Quick-reference for all registered services. Read the individual file for full operational details.

| Service | Category | CLI | MCP | Auth Pattern | 2FA | File |
|---------|----------|-----|-----|-------------|-----|------|
| **Vercel** | deployment | `vercel` | installable | token-flag | email | [vercel.md](vercel.md) |
| **GitHub** | source-control | `gh` | installed | cli-login | authenticator | [github.md](github.md) |
| **Supabase** | database | `supabase` | installable | token-env | email | [supabase.md](supabase.md) |
| **Cloudflare** | cdn/hosting/storage | `wrangler` | installable | token-env | authenticator | [cloudflare.md](cloudflare.md) |
| **Stripe** | payments | `stripe` | none | api-key-header | authenticator | [stripe.md](stripe.md) |
| **Razorpay** | payments | none | none | api-key-header | sms | [razorpay.md](razorpay.md) |
| **Alpaca** | trading | none | none | api-key-header | none | [alpaca.md](alpaca.md) |
| **Telegram** | messaging | none | none | api-key-header | none | [telegram.md](telegram.md) |

## Decision Level Quick-Reference

| Level | Meaning | Examples |
|-------|---------|---------|
| L1 | Just do it | List projects, check status, read data |
| L2 | Do it, notify | Preview deploys, paper trades, send to known chat |
| L3 | Ask first | Production deploys, DNS changes, DB migrations |
| L4 | Must ask | Live trades, charges, refunds, delete resources |

## Credential Status

Check all credentials: `~/MCPs/autopilot/bin/keychain.sh check-ttl`
