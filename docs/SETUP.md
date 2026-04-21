# Setup

This repo talks to the AgentCulture CloudFlare account over the REST
API. All calls authenticate with a single API token loaded from a
local `.env` file. The `cloudflare` skill's scripts read that token
via `_lib.sh` — no other configuration is required.

This guide walks you through:

1. Creating the right token in the CloudFlare dashboard.
2. Looking up the account ID.
3. Wiring both into `.env`.
4. Verifying the setup works end-to-end.
5. Diagnosing the errors you are likeliest to hit.

## 1. Create the API token

1. Go to <https://dash.cloudflare.com/profile/api-tokens> while logged
   in as the user who owns the AgentCulture account.
2. Click **Create Token** → **Create Custom Token**.
3. Name it something retrievable, e.g. `claudeflare-readonly`.
4. Add the **Permissions** listed in the table below. Each row
   corresponds to one "permission" row in the token UI.
5. Under **Account Resources**, select **Include → Specific account →
   AgentCulture**.
6. Under **Zone Resources**, select **Include → All zones from an
   account → AgentCulture**. *This matters* — scoping Zone resources
   to a single zone (e.g. only `culture.dev`) causes
   `code 10000 Authentication error` on every other zone in the
   account.
7. Leave **Client IP Address Filtering** empty and **TTL** at "Never
   expire" unless you have a reason to rotate.
8. **Continue to summary** → **Create Token**. Copy the token *now* —
   CloudFlare only shows it once.

### Scope-to-script mapping

Every script below needs at least the scopes in its row. `cf-status.sh`
needs the union of everything (it calls all the others).

| Scope (CloudFlare dashboard label)     | Level   | Access | Powers                                                     |
|----------------------------------------|---------|--------|------------------------------------------------------------|
| **Account · Account Settings**         | Account | Read   | `cf-whoami.sh` indirectly; required by most account calls  |
| **Account · Workers Scripts**          | Account | Read   | `cf-workers.sh`                                            |
| **Account · Cloudflare Pages**         | Account | Read   | `cf-pages.sh` (list projects + deployments)                |
| **Account · Account Analytics**        | Account | Read   | Optional — useful for future state checks                  |
| **Zone · Zone** (All zones in account) | Zone    | Read   | `cf-zones.sh`, enumeration step inside `cf-workers-routes.sh` |
| **Zone · DNS** (All zones in account)  | Zone    | Read   | `cf-dns.sh <zone>`                                         |
| **Zone · Workers Routes** (All zones)  | Zone    | Read   | `cf-workers-routes.sh`                                     |

All zone-level scopes must be set to **All zones from the AgentCulture
account**. Scoping to a single zone is the most common setup mistake —
it silently passes `cf-zones.sh` (account-level) while failing every
per-zone call with the same `code 10000` error.

## 2. Find the account ID

The account ID is required for account-scoped endpoints (Workers,
Pages). To find it:

1. Open <https://dash.cloudflare.com/> and pick the **AgentCulture**
   account.
2. Scroll the right-hand **Account details** panel to **Account ID**
   and click the copy button.

The ID is a 32-character hex string, e.g. `1f094060...`.

## 3. Wire up `.env`

From the repo root:

```sh
cp .env.example .env
```

Edit `.env` and fill in both values:

```text
CLOUDFLARE_API_TOKEN=paste-the-token-here
CLOUDFLARE_ACCOUNT_ID=paste-the-account-id-here
```

`.env` is gitignored. Do not commit it. `_lib.sh` reads the file with
a safe `KEY=VALUE` parser (no `source`, no shell execution) on every
script invocation.

## 4. Verify

Run these in order. Any failure points at a specific fix below.

```sh
bash .claude/skills/cloudflare/scripts/cf-whoami.sh
bash .claude/skills/cloudflare/scripts/cf-zones.sh
bash .claude/skills/cloudflare/scripts/cf-status.sh
```

- `cf-whoami.sh` exercises the token itself (no scope requirements
  beyond "token is valid").
- `cf-zones.sh` exercises the `Zone · Zone` scope.
- `cf-status.sh` exercises every remaining scope (DNS, Workers
  Scripts, Workers Routes, Pages) in one shot — if this succeeds, the
  token is fully provisioned.

## 5. Common errors

### `ERROR: CLOUDFLARE_API_TOKEN not set`

`.env` is missing, empty, or `CLOUDFLARE_API_TOKEN=` is blank.
Re-check step 3.

### `ERROR: CLOUDFLARE_ACCOUNT_ID not set`

`CLOUDFLARE_ACCOUNT_ID` is blank in `.env`. Only `cf-workers.sh`,
`cf-pages.sh`, and `cf-status.sh` need this; `cf-whoami.sh` and
`cf-zones.sh` work without it.

### `code 10000 Authentication error`

CloudFlare returns this when the token *is* valid but *lacks the
specific scope* the endpoint requires, or the scope is attached to the
wrong account/zone. In this repo the failure mode is almost always:

| Script failing with 10000       | Missing / mis-scoped                                 |
|---------------------------------|------------------------------------------------------|
| `cf-dns.sh <zone>`              | **Zone · DNS · Read**, scoped to "All zones"         |
| `cf-workers-routes.sh`          | **Zone · Workers Routes · Read**, scoped to "All zones" |
| `cf-workers.sh`                 | **Account · Workers Scripts · Read** on AgentCulture |
| `cf-pages.sh`                   | **Account · Cloudflare Pages · Read** on AgentCulture |

Edit the token in the dashboard, add / re-scope the permission,
**save**, and re-run. Most often the token was created with Zone
resources set to a single zone rather than "All zones from an
account".

### `code 8000024 Invalid list options provided. Review the page or per_page parameter.`

The CloudFlare Pages list endpoint caps `per_page` at 10 but this
skill's `cf_api_paginated` defaults to 50. `cf-pages.sh` pins the
value to 10 internally so you should never see this error from a
released version — if you do, either something is overriding
`CF_PAGE_SIZE` to >10, or a new Pages-related script is missing the
same pin. Set `CF_PAGE_SIZE=10` explicitly to confirm, then trace the
override.

### `code 9109 Unauthorized to access requested resource`

The account in `.env` is not the one the token is scoped to, or you
are a member of multiple CloudFlare accounts. Re-check step 2 against
the dashboard URL — the account ID in `dash.cloudflare.com/<id>/...`
is the one to use.

## 6. Rotating the token

When the token is compromised or a team member leaves:

1. Dashboard → API Tokens → find the token → **Roll** (issues a new
   secret for the same scopes) or **Delete** (invalidates; you need
   to create a new one from scratch).
2. Update `.env` on every machine running this skill.
3. `cf-whoami.sh` is the quickest way to confirm the new token is
   live.

There is no separate rotation workflow in this repo — everything flows
through `.env`.
