---
name: cloudflare
description: >
  Read-only visibility into CloudFlare state for the AgentCulture
  organization: zones, DNS records, Workers scripts and routes, Pages
  projects and deployments, plus a single-shot status digest. Use
  when: checking CloudFlare state, verifying DNS, inventorying Pages
  or Workers deployments, auditing before a cleanup, or the user says
  "cloudflare status", "cf-status", "check cloudflare", "list zones",
  "dns records", "pages deployments", "workers scripts", "workers
  routes", "cf-whoami", "inventory agentirc", "verify the cloudflare
  token".
---

# cloudflare

Read-only skill for inspecting CloudFlare state. Every script is a
thin wrapper around the CloudFlare REST API that renders an
agent-readable markdown table (or key-value list for single-object
responses) by default, and emits raw JSON with `--json` for bots and
`jq` pipelines.

**Read-only.** For create / update / delete, use the companion
[`cloudflare-write`](../cloudflare-write/SKILL.md) skill — it lives
next to this one and shares `_lib.sh` via symlink.

## 1. Pre-flight

Before running anything else, confirm credentials are wired:

```sh
bash .claude/skills/cloudflare/scripts/cf-whoami.sh
```

Expected output: a `**CloudFlare token**` section with the token id,
`status: active`, `not_before`, and `expires_on`. If you see
`CLOUDFLARE_API_TOKEN not set`, or if later scripts return
`code 10000 Authentication error`, see `docs/SETUP.md` for the full
token-creation walkthrough, the scope-to-script mapping, and common
errors. `cf-whoami` does NOT list the token's granted scopes —
`/user/tokens/verify` doesn't return them; consult the dashboard for
scopes if needed.

## 2. Read recipes

Question → script:

| Question | Script |
|---|---|
| Give me everything in one shot | `bash .claude/skills/cloudflare/scripts/cf-status.sh` |
| What zones does the token see? | `bash .claude/skills/cloudflare/scripts/cf-zones.sh` |
| What DNS records exist on `<zone>`? | `bash .claude/skills/cloudflare/scripts/cf-dns.sh <zone>` |
| What Workers scripts are deployed? | `bash .claude/skills/cloudflare/scripts/cf-workers.sh` |
| Which Workers routes exist across all zones? | `bash .claude/skills/cloudflare/scripts/cf-workers-routes.sh` |
| What Pages projects exist? | `bash .claude/skills/cloudflare/scripts/cf-pages.sh` |
| What deployments does `<project>` have? | `bash .claude/skills/cloudflare/scripts/cf-pages.sh <project>` |

Every script accepts `--json` to emit the raw CloudFlare response
envelope (for Workers routes and `cf-status`, a synthetic envelope —
those scripts aggregate across multiple calls).

**Prefer `cf-status.sh` for "what's the state?" questions.** It runs
every other read script in `--json` mode and composes one digest, so
you get token + zones + Workers scripts + Workers routes + Pages
projects in a single command (and therefore a single tool call) — no
need to run five scripts, read each block, and stitch the summary
together by hand.

## 3. Targeting culture.dev

The typical pattern for inspecting the primary zone:

```sh
# What's attached to culture.dev?
bash .claude/skills/cloudflare/scripts/cf-dns.sh culture.dev

# What Workers are behind culture.dev?
bash .claude/skills/cloudflare/scripts/cf-workers-routes.sh | grep culture.dev

# What Pages projects point at culture.dev?
bash .claude/skills/cloudflare/scripts/cf-pages.sh --json | jq '.result[] | select(.domains | any(test("culture.dev")))'
```

Scripts take zone/project **names**, not IDs — names are resolved
internally.

## 4. Inventorying agentirc.dev before cleanup

`agentirc.dev` is the deprecated domain that's been folded into
`culture.dev/agentirc`. The Pages deployment needs cleanup; this
skill is the inventory tool before any removal.

```sh
# Confirm the Pages project still exists and find its exact name
bash .claude/skills/cloudflare/scripts/cf-pages.sh | grep -i agentirc

# Dump all deployments for that project
bash .claude/skills/cloudflare/scripts/cf-pages.sh <project-name>

# Check DNS records still attached to agentirc.dev
bash .claude/skills/cloudflare/scripts/cf-dns.sh agentirc.dev

# Check whether any Workers routes still point at agentirc.dev
bash .claude/skills/cloudflare/scripts/cf-workers-routes.sh | grep agentirc.dev
```

Save the outputs before the Phase 2 removal plan is written — they
become the audit trail.

## 5. Output modes

Default is markdown:

- **List data** → table (`| COL | COL |` + `| --- | --- |`) preceded by a `## <section> (<count>)` heading.
- **Single-object data** (only `cf-whoami` today) → key-value list (`- **key:** value`).

`--json` bypasses all formatting:

```sh
# Pipe JSON into jq
bash .claude/skills/cloudflare/scripts/cf-zones.sh --json | jq '.result[].name'

# Check how many DNS records culture.dev has
bash .claude/skills/cloudflare/scripts/cf-dns.sh culture.dev --json | jq '.result | length'
```

Pagination: handled transparently for every list endpoint via
`cf_api_paginated` in `_lib.sh`. You get every page concatenated into
one `.result` array; override the per-page size by exporting
`CF_PAGE_SIZE` in the environment of any script invocation, e.g.
`CF_PAGE_SIZE=25 bash .claude/skills/cloudflare/scripts/cf-zones.sh`.
The default is 50. `cf-pages.sh` pins it to 10 internally because the
CloudFlare Pages list endpoint rejects `per_page >= 11` with
`code 8000024`; a user-supplied `CF_PAGE_SIZE` still wins if set.

## 6. What this skill does NOT do (yet)

- **Write operations.** No create / update / delete. Added in a
  later phase with the same `.claude/skills/cloudflare/scripts/`
  layout (new `cf-*-create.sh` / `cf-*-delete.sh` scripts).
- **Scope enumeration.** `cf-whoami.sh` reports token status and
  expiry but not granted scopes — the verify endpoint doesn't return
  them. Check the dashboard.
- **Account switching.** One `CLOUDFLARE_ACCOUNT_ID` per `.env`; no
  multi-account support.
- **Live token testing in CI.** The bats suite mocks curl via a
  PATH stub so tests run offline. The real token is only exercised
  manually or in a separately-configured workflow.

## 7. References

- `../cloudflare-write/references/cf-api-gotchas.md` — consolidated
  CF API quirks. Several apply to reads too: the Pages `per_page`
  cap that `cf-pages.sh` has to work around (gotcha #1) and the
  zone-scope 10000 behavior (gotcha #6) both bite read-only
  callers.

## 8. Adding new read scripts

Follow the pattern every existing script uses:

1. Parse args with a `for arg in "$@"; case "$arg" in ... esac` loop. Support `--json` and `-h`/`--help`.
2. `source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"` — this loads `.env`, verifies `CLOUDFLARE_API_TOKEN`, and exposes `cf_api`, `cf_api_paginated`, `cf_output`, `cf_output_kv`, `cf_require_account_id`.
3. Call `cf_require_account_id` if the endpoint is account-scoped (`/accounts/:id/...`).
4. Fetch with `cf_api_paginated` for list endpoints; `cf_api` for single-object endpoints.
5. In `md` mode, emit a `## <section> (<count>)\n\n` heading, then hand off to `cf_output` (table) or `cf_output_kv` (single object).
6. URL-encode any user-supplied argument before interpolation: `jq -rn --arg v "$input" '$v|@uri'`.
7. Add a fixture under `tests/fixtures/`, a bats file under `tests/bats/`, and cover at minimum: md rendering, `--json` passthrough, correct URL target, unknown-arg exit 2, API error exit 1.

Run `bash tests/shellcheck.sh` and `bats tests/bats/` before committing.
