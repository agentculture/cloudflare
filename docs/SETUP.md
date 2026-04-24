# Setup

This repo talks to the AgentCulture CloudFlare account over the REST
API. The installed `cfafi` CLI reads credentials from environment
variables; bash skills under `.claude/skills/cfafi/` also accept a
`.env` file at the repo root for local development.

This guide walks you through:

1. Credentials — environment variables (primary, recommended).
2. Creating the right token in the CloudFlare dashboard.
3. Looking up the account ID.
4. Wiring both into your environment (or `.env` for dev).
5. Verifying the setup works end-to-end.
6. Diagnosing the errors you are likeliest to hit.
7. PyPI Trusted Publisher setup (maintainer, one-time).

---

## Credentials — environment variables

The installed `cfafi` CLI reads `CLOUDFLARE_API_TOKEN` and
`CLOUDFLARE_ACCOUNT_ID` from the environment only. It does not walk
upward for a `.env` file.

**Recommended pattern** (secure):

```bash
# 1. Store creds in a file owned by the agent's POSIX user, mode 0600:
install -m 0600 /dev/null ~/.config/agent/cfafi.env
$EDITOR ~/.config/agent/cfafi.env
# CLOUDFLARE_API_TOKEN=...
# CLOUDFLARE_ACCOUNT_ID=...

# 2. Source into the environment just before invoking cfafi:
set -a; . ~/.config/agent/cfafi.env; set +a
cfafi zones list
```

Bash scripts under `.claude/skills/cfafi/scripts/` still read `.env`
from the repo root during coexistence — that's a dev-convenience for
people working in the repo, not how the installed CLI behaves.

---

## 2. Create the API token

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

| Scope (CloudFlare dashboard label)     | Level   | Access | `cfafi` verb | Bash script |
|----------------------------------------|---------|--------|---|---|
| **Account · Account Settings**         | Account | Read   | `cfafi whoami` | `cf-whoami.sh` |
| **Account · Workers Scripts**          | Account | Read   | — | `cf-workers.sh` |
| **Account · Cloudflare Pages**         | Account | Read   | — | `cf-pages.sh` |
| **Account · Account Analytics**        | Account | Read   | — (optional) | — |
| **Zone · Zone** (All zones in account) | Zone    | Read   | `cfafi zones list` | `cf-zones.sh` |
| **Zone · DNS** (All zones in account)  | Zone    | Read   | — | `cf-dns.sh <zone>` |
| **Zone · Workers Routes** (All zones)  | Zone    | Read   | — | `cf-workers-routes.sh` |

All zone-level scopes must be set to **All zones from the AgentCulture
account**. Scoping to a single zone is the most common setup mistake —
it silently passes `cf-zones.sh` (account-level) while failing every
per-zone call with the same `code 10000` error.

### 2.5 Write-ops token (optional, for the `cfafi-write` skill and `cfafi dns create`)

The table above lists **Read** scopes only. Scripts in the companion
`cfafi-write` skill (create / update / delete operations) and the
`cfafi dns create` Python verb need **Edit** scopes, which are
intentionally gated behind a separate token.

Create a **second** token — keep it distinct from your read token so
the mutating credential isn't lying around on machines that only need
inventory access. Suggested name: `claudeflare-write`. Give it every
scope from the Read table above (so `cfafi whoami` / `cfafi zones list`
still work) **plus** the Edit scopes below. Scope to the AgentCulture
account and "All zones from an account" exactly like the read token.

| Scope (CloudFlare dashboard label)       | Level   | Access | `cfafi` verb | Bash script |
|------------------------------------------|---------|--------|---|---|
| **Zone · Single Redirect** (All zones)  | Zone    | Edit   | — | `cf-redirect-create.sh` |
| **Zone · DNS** (All zones)               | Zone    | Edit   | `cfafi dns create` | `cf-dns-create.sh` |
| **Account · Cloudflare Pages**           | Account | Edit   | — | `cf-pages-deployment-delete.sh` / `cf-pages-deployments-purge.sh` |

Swap tokens by editing `.env`'s `CLOUDFLARE_API_TOKEN` when you're
about to run a write script, then swap back. `.env` only stores one
token at a time; there is no per-script token selection.

You do not need this token to follow the rest of this guide, develop
read scripts, or run the test suite — the bats harness mocks `curl`
and never touches the live API.

## 3. Find the account ID

The account ID is required for account-scoped endpoints (Workers,
Pages). To find it:

1. Open <https://dash.cloudflare.com/> and pick the **AgentCulture**
   account.
2. Scroll the right-hand **Account details** panel to **Account ID**
   and click the copy button.

The ID is a 32-character hex string, e.g. `1f094060...`.

## 4. Wire up your environment (or `.env` for dev)

**For the installed CLI** — use the env-file pattern from §1 above:

```bash
set -a; . ~/.config/agent/cfafi.env; set +a
cfafi zones list
```

**For bash skills in the repo (dev convenience)** — from the repo root:

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

## 5. Verify

Run these in order. Any failure points at a specific fix below.

**Python CLI (preferred):**

```sh
cfafi whoami
cfafi zones list
```

**Bash skills (fallback / dev):**

```sh
bash .claude/skills/cfafi/scripts/cf-whoami.sh
bash .claude/skills/cfafi/scripts/cf-zones.sh
bash .claude/skills/cfafi/scripts/cf-status.sh
```

- `cfafi whoami` / `cf-whoami.sh` exercise the token itself (no scope
  requirements beyond "token is valid").
- `cfafi zones list` / `cf-zones.sh` exercise the `Zone · Zone` scope.
- `cf-status.sh` exercises every remaining scope (DNS, Workers
  Scripts, Workers Routes, Pages) in one shot — if this succeeds, the
  token is fully provisioned.

If you also provisioned a write-ops token (§2.5), activate it and run
dry-runs against a real zone to exercise the Edit scopes without
mutating anything:

```sh
# DNS · Edit via Python CLI
cfafi dns create agentculture.org A agentculture.org 192.0.2.1 --proxied
# (dry-run by default — add --apply to commit)

# Single Redirect · Edit via bash skill
bash .claude/skills/cfafi-write/scripts/cf-redirect-create.sh \
  agentculture.org culture.dev --www

# DNS · Edit via bash skill
bash .claude/skills/cfafi-write/scripts/cf-dns-create.sh \
  agentculture.org A agentculture.org 192.0.2.1 --proxied
```

Both should print a "Dry-run — no changes applied" banner followed
by the JSON body each would POST. If either errors with `code 10000`,
the token is missing the corresponding Edit scope (or it's scoped to
the wrong zones).

## 6. Common errors

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

## 7. Rotating the token

When the token is compromised or a team member leaves:

1. Dashboard → API Tokens → find the token → **Roll** (issues a new
   secret for the same scopes) or **Delete** (invalidates; you need
   to create a new one from scratch).
2. Update `~/.config/agent/cfafi.env` (or `.env` for dev) on every
   machine running this skill.
3. `cfafi whoami` (or `cf-whoami.sh`) is the quickest way to confirm
   the new token is live.

There is no separate rotation workflow in this repo — everything flows
through the environment variable.

## 8. PyPI Trusted Publisher (maintainer setup, one-time)

Publishing to PyPI uses OIDC — no API tokens stored anywhere. Before
the first release:

1. Sign in to PyPI as the AgentCulture org owner.
2. Project → Publishing → Add a new pending publisher:
   - Publisher: GitHub
   - Owner: `agentculture`
   - Repo: `cfafi`
   - Workflow name: `publish.yml`
   - Environment: `pypi`
3. Repeat on TestPyPI with environment `testpypi`.

GitHub side: `Settings → Environments → New environment` for both
`pypi` and `testpypi`. No secrets needed.
