---
name: cloudflare-write
description: >
  Write / edit / delete operations against CloudFlare state for the
  AgentCulture organization — create redirects, modify rules, delete
  resources. Use when: creating a CloudFlare redirect, adding a
  Single Redirect rule, editing / modifying CloudFlare state,
  deleting a Pages project / Worker / DNS record, or the user says
  "create redirect", "add cloudflare redirect", "edit cloudflare",
  "write cloudflare", "modify dns", "delete pages project",
  "cf-redirect-create", "cf-redirect". For **read-only** inventory
  (list zones / DNS / Workers / Pages, verify token), use the
  separate `cloudflare` skill — this skill never runs GET-only
  queries.
---

# cloudflare-write

Write-side companion to the read-only `cloudflare` skill. Every script
here mutates CloudFlare state (creates, updates, or deletes a
resource) and defaults to **dry-run** — the live API call only fires
with an explicit `--apply` flag.

Shared library: `_lib.sh` is a symlink to the read skill's copy at
`../../cloudflare/scripts/_lib.sh`, so env loading, `cf_api`,
`cf_api_paginated`, `cf_output`, `cf_output_kv`, and
`cf_require_account_id` are all available without duplicating code.
Fixes to the shared helpers apply to both skills automatically.

## 1. Pre-flight

Write operations need a **different token** than the read skill uses.
The read skill's token is scoped `Read` only; attempting a POST /
PUT / DELETE with it will fail with `code 10000 Authentication error`.

Provision a second token (see `docs/SETUP.md` §1.5 **Write-ops
token**) with these *additional* scopes on top of the read scopes:

- **Zone · Single Redirect · Edit** (All zones from AgentCulture) —
  required by `cf-redirect-create.sh`. (The CloudFlare Rulesets API
  still uses `http_request_dynamic_redirect` as the phase
  identifier, but the dashboard's token-scope label is "Single
  Redirect".)
- **Zone · DNS · Edit** (All zones from AgentCulture) —
  required by `cf-dns-create.sh`

Swap the token into `.env` when you're about to run a write script,
then swap back. One token at a time.

Verify the write-capable token is active:

```sh
bash .claude/skills/cloudflare/scripts/cf-whoami.sh
```

(Reuses the read skill — the `/user/tokens/verify` endpoint works on
any token.)

## 2. Safety model

Every write script in this skill follows the same shape:

- **Dry-run by default.** Running without `--apply` resolves names,
  performs read-only pre-flight checks (does the zone exist? does the
  resource already exist?), prints the exact JSON body the script
  would POST / PUT / DELETE, and exits 0. No mutation.
- **`--apply` makes it real.** Only with `--apply` does the script
  call the mutating endpoint.
- **Idempotency is enforced locally.** Scripts query for existing
  matching resources before creating and exit 1 with a clear error if
  one already exists — they never silently overwrite.
- **Names, not IDs.** Args are zone / project / resource names;
  scripts resolve to IDs internally via `cf_api_paginated`.

## 3. Scripts

| Question → action | Script |
|---|---|
| Create a Single Redirect for a zone | `bash .claude/skills/cloudflare-write/scripts/cf-redirect-create.sh FROM_HOST TO_HOST [--www] [--status=301] [--apply] [--json]` |
| Create a DNS record in a zone | `bash .claude/skills/cloudflare-write/scripts/cf-dns-create.sh ZONE TYPE NAME CONTENT [--proxied] [--ttl=N] [--comment=STR] [--apply] [--json]` |

### cf-redirect-create.sh

Creates a zone-level Single Redirect ruleset in the
`http_request_dynamic_redirect` phase. Path and query string are
preserved; the target URL is built as
`concat("https://TO_HOST", http.request.uri.path)` so the redirect
works for any sub-path.

```sh
# Dry-run (prints what would happen, does not touch the API mutating path):
bash .claude/skills/cloudflare-write/scripts/cf-redirect-create.sh \
  agentculture.org culture.dev --www

# Apply for real:
bash .claude/skills/cloudflare-write/scripts/cf-redirect-create.sh \
  agentculture.org culture.dev --www --apply
```

Flags:

- `--www` — match both `FROM_HOST` and `www.FROM_HOST`. Use when the
  zone has both apex and `www.` DNS records.
- `--status=N` — HTTP status code for the redirect. Defaults to `301`
  (permanent, SEO-safe). `--status=302` for testing. The `=` is
  required; `--status 302` (space-separated) is **not** accepted.
- `--apply` — actually POST. Without this, the script is a dry-run.
- `--json` — emit the raw CloudFlare response envelope instead of
  markdown. Works in both dry-run (simulated body) and `--apply`
  (real response) modes.

Exit codes: `0` success (dry-run or apply), `1` API error / already
exists / zone not found, `2` usage error (missing args, unknown flag).

### Prerequisites for the redirect to actually fire

The redirect rule only runs if traffic reaches CloudFlare's edge.
That means `FROM_HOST` must have **proxied** DNS records (A / AAAA /
CNAME, orange-cloud in the dashboard). Check with the read skill
before applying:

```sh
bash .claude/skills/cloudflare/scripts/cf-dns.sh agentculture.org
```

If every record is "—" (DNS-only) or the zone has no apex record,
the redirect won't fire. Use `cf-dns-create.sh` (below) to add the
apex and `www` records first, then create the redirect.

### cf-dns-create.sh

Creates a DNS record in a zone. Same safety model as
`cf-redirect-create.sh`: dry-run by default, `--apply` to commit,
idempotency enforced before the POST.

```sh
# Canonical setup for a redirect-only zone — apex + www, both proxied.
# 192.0.2.1 is TEST-NET-1; CF intercepts at the edge before forwarding,
# so the origin IP is irrelevant for a pure-redirect zone.
bash .claude/skills/cloudflare-write/scripts/cf-dns-create.sh \
  agentculture.org A agentculture.org 192.0.2.1 --proxied --apply
bash .claude/skills/cloudflare-write/scripts/cf-dns-create.sh \
  agentculture.org A www.agentculture.org 192.0.2.1 --proxied --apply
```

Flags:

- `--proxied` — orange-cloud the record so CF intercepts HTTP
  traffic. Required for Single Redirects to fire on the record's
  hostname.
- `--ttl=N` — TTL in seconds. Default `1` (automatic). Manual TTLs
  must be in `60..86400`. Proxied records are forced to `1` by CF;
  combining `--proxied` with `--ttl=N` (N≠1) is rejected up-front.
- `--comment=STR` — free-text note attached to the record (visible
  in the CF dashboard).
- `--apply` — actually POST. Without this, the script is a dry-run.
- `--json` — raw CloudFlare response envelope, same shape as the
  read skill's `--json` output.

Supported record types: A, AAAA, CNAME, TXT, MX, NS, SRV, CAA.
Extend the case statement in the script if you need PTR / URI /
TLSA / etc.

Idempotency key: **type + name + content**. Two A records at the
same name with different IPs are allowed (CF supports round-robin);
two records with identical type+name+content are refused as
duplicates.

## 4. Output modes

Default markdown (`cf_output_kv` for the result block):

```text
**Redirect created**
- **zone:** agentculture.org
- **from:** agentculture.org (apex + www)
- **to:** https://culture.dev
- **status:** 301
- **preserve_query_string:** true
- **ruleset_id:** <new-id>
```

Dry-run prefixes with `**Dry-run — no changes applied**` and shows
the `would POST` JSON body.

`--json` passes the CloudFlare response envelope
(`{success, errors, messages, result}`) through unchanged — same
shape as the read skill's `--json` output for consistency with
downstream jq pipelines.

## 5. What this skill does NOT do yet

- **Updates (PUT).** No `cf-*-update.sh` scripts — resources either
  exist (keep them) or don't (create new).
- **Deletes (DELETE).** Phase 2 territory: `agentirc.dev` Pages /
  Workers / DNS cleanup will land as `cf-*-delete.sh` scripts in
  this skill.
- **Account-wide rulesets.** This skill only creates zone-level
  rulesets. Account-level rulesets (applied across many zones) are
  out of scope.
- **Bulk Redirects.** For one-host-to-one-host redirects, Single
  Redirects are simpler and cheaper. Bulk Redirects (lists of
  URL-to-URL mappings) will get their own script if we ever need one.

## 6. Adding new write scripts

Follow the pattern `cf-redirect-create.sh` sets:

1. Parse args with the same `for arg in "$@"; case "$arg" in … esac`
   loop shape used by read scripts. Support `--apply`, `--json`,
   `-h`/`--help`, plus script-specific flags.
2. `source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"` — symlink
   resolves to the read skill's copy.
3. **Resolve names to IDs first** with `cf_api_paginated` and exit 1
   with a clear message if the name doesn't match anything.
4. **Pre-flight idempotency check** with `cf_api` (GET) against the
   list endpoint for the resource you're about to create / modify.
   Exit 1 if a matching resource already exists.
5. Build the mutating request body as JSON with `jq -n --arg … '…'`
   (never string concatenation — injection risk).
6. Gate the mutating call on `"$apply" == "1"`. In dry-run, print the
   body and exit 0. In apply, `cf_api "$path" -X POST --data "$body"`
   (or PUT / DELETE) and render the response.
7. Add a bats file under `tests/bats/` covering dry-run, apply,
   idempotency, name resolution, unknown flag, and the `--json`
   passthrough. Fixtures go in `tests/fixtures/`.

Run `bash tests/shellcheck.sh`, `bash tests/markdownlint.sh`, and
`bats tests/bats/` before committing.
