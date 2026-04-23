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
- **Account · Cloudflare Pages · Edit** (this account) —
  required by `cf-pages-project-create.sh`,
  `cf-pages-deployment-delete.sh`, and
  `cf-pages-deployments-purge.sh`. Creating a **GitHub-connected**
  Pages project (no `--direct-upload`) additionally needs the
  **Cloudflare Pages GitHub App** installed on the source GitHub
  owner (org or user) with access to the target repo — a one-time
  dashboard / GitHub-admin step this skill cannot automate.
  `--direct-upload` projects have no GitHub App dependency.
- **Account · Workers Scripts · Edit** (this account) —
  required by `cf-worker-create.sh`. Uploads a Worker script (the
  subpath-proxy template, typically) via multipart PUT.
- **Zone · Workers Routes · Edit** (**All zones from AgentCulture**) —
  required by `cf-workers-route-create.sh`. Per
  `memory/zone_ids.md`, zone-level scopes on a subset fail with code
  10000; cover every zone or the route POST will reject even though
  the dry-run passed.

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
| Create a Pages project connected to a GitHub repo | `bash .claude/skills/cloudflare-write/scripts/cf-pages-project-create.sh NAME GITHUB_OWNER REPO_NAME [--clone-from=PROJECT] [...] [--apply] [--json]` |
| Create a Direct Upload Pages project (no git source) | `bash .claude/skills/cloudflare-write/scripts/cf-pages-project-create.sh NAME --direct-upload [--compatibility-date=DATE] [--apply] [--json]` |
| Upload a Worker script | `bash .claude/skills/cloudflare-write/scripts/cf-worker-create.sh NAME --from-file=PATH [--module\|--service-worker] [--compatibility-date=DATE] [--apply] [--json]` |
| Create a Workers route on a zone | `bash .claude/skills/cloudflare-write/scripts/cf-workers-route-create.sh ZONE PATTERN SCRIPT [--apply] [--json]` |
| Stand up a new `culture.dev/NAME` sub-site (agex-style) | 3 scripts above + `templates/subpath-proxy.js`; see `references/subpath-site-pattern.md` |
| Delete one Pages deployment | `bash .claude/skills/cloudflare-write/scripts/cf-pages-deployment-delete.sh PROJECT SHORT_ID_OR_ID [--force-canonical] [--apply] [--json]` |
| Bulk-delete all deployments in a Pages project | `bash .claude/skills/cloudflare-write/scripts/cf-pages-deployments-purge.sh PROJECT [...]` (two-phase, see §3.3) |

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

### cf-pages-project-create.sh

Creates a Cloudflare Pages project in either **GitHub-connected**
mode (default) or **Direct Upload** mode (with `--direct-upload`).
Mirrors the build + deployment settings of an existing project when
given `--clone-from=PROJECT`, so "spin up a second project with the
same style as culture-dev" is one flag, not a dozen.

**Direct Upload vs GitHub-connected** — with `--direct-upload` the
project has no `source` field, no GitHub App dependency, and
deployments come from `wrangler pages deploy` / CF's direct-upload
API rather than auto-builds. That's the mode used by the
`culture.dev/NAME` sub-site pattern (agex, citation-cli, afi) where
the consumer repo's own CI builds the site and uploads the finished
bundle. See `references/subpath-site-pattern.md`.

```sh
# Dry-run — shows the full POST body we would send, including the
# build_config / deployment_configs lifted from culture-dev:
bash .claude/skills/cloudflare-write/scripts/cf-pages-project-create.sh \
  culture agentculture culture --clone-from=culture-dev

# Apply for real:
bash .claude/skills/cloudflare-write/scripts/cf-pages-project-create.sh \
  culture agentculture culture --clone-from=culture-dev --apply

# Direct Upload variant (agex / citation-cli / afi style — no source):
bash .claude/skills/cloudflare-write/scripts/cf-pages-project-create.sh \
  afi --direct-upload --compatibility-date=2026-04-20 --apply
```

Positional args:

- `NAME` — Pages project name, becomes `NAME.pages.dev`. Must be
  1-58 chars, lowercase alphanumeric + hyphens, no leading/trailing
  hyphen. Enforced locally before the POST.
- `GITHUB_OWNER` — GitHub org or user that owns the repo
  (e.g. `agentculture`). **Only with the default GitHub-connected
  mode.** Omit under `--direct-upload`.
- `REPO_NAME` — repository name within that owner (e.g. `culture`).
  Same rule — omit under `--direct-upload`.

Flags:

- `--direct-upload` — create a Direct Upload project (no `source`
  field in the POST body; deployments happen via `wrangler pages
  deploy` or direct-upload API calls). Positional args collapse to
  NAME only; passing OWNER / REPO alongside is an error.
- `--clone-from=PROJECT` — copy `build_config`, `deployment_configs`,
  and `production_branch` from an existing Pages project in the
  same account. Works with or without `--direct-upload`. Individual
  overrides (below) still win.
- `--production-branch=BRANCH` — git branch that produces
  production deployments. Default `main` (or the cloned value).
- `--build-command=CMD` — shell command CF runs to build the site.
- `--destination-dir=DIR` — path CF uploads (relative to root-dir).
- `--root-dir=DIR` — repo subdirectory to build from. `""` (the
  default) means the repo root.
- `--compatibility-date=YYYY-MM-DD` — applied to both preview and
  production deployment configs.
- `--build-image-version=N` — `1`, `2`, or `3` (default `3` = latest).
- `--apply` — actually POST. Without it, dry-run.
- `--json` — raw CloudFlare response envelope (or simulated body in
  dry-run).

Idempotency: scripts refuses to proceed if `NAME` already exists in
the account. Pick a different name or delete the existing project.

**GitHub App prerequisite.** The apply path calls
`POST /accounts/:id/pages/projects` with the GitHub `owner` and
`repo_name`. For this to succeed the Cloudflare Pages GitHub App
must be installed on `GITHUB_OWNER` with access to `REPO_NAME`. If
the dashboard UI couldn't list the repo when connecting manually,
the API call will fail for the same underlying reason — the script
surfaces the CF error and exits 1. The fix is a one-time
installation/authorization step in the GitHub org admin UI, not
something this skill can automate.

Custom domains (including apex mappings like `culture.dev`) are not
created by this script; attach them in the Pages dashboard or via a
follow-on `cf-pages-domain-add.sh` once that lands.

### cf-worker-create.sh

Uploads a Cloudflare Worker script from a local file via the
multipart `PUT /accounts/:id/workers/scripts/:name` endpoint.

```sh
# Dry-run (no mutation; prints metadata + a 20-line source preview):
bash .claude/skills/cloudflare-write/scripts/cf-worker-create.sh \
  afi-proxy --from-file=/tmp/afi-proxy.js --compatibility-date=2026-04-20

# Apply:
bash .claude/skills/cloudflare-write/scripts/cf-worker-create.sh \
  afi-proxy --from-file=/tmp/afi-proxy.js --compatibility-date=2026-04-20 --apply
```

Positional args:

- `NAME` — Worker script name. 1-63 chars, lowercase alphanumeric
  plus `_-`, no leading/trailing `_` or `-`. Enforced locally.

Flags:

- `--from-file=PATH` — local `.js` file to upload. Required.
- `--module` — ES-module format (default). Metadata:
  `{"main_module":"worker.js", "compatibility_date": ...}`.
  Part content-type `application/javascript+module`.
- `--service-worker` — legacy service-worker format. Metadata:
  `{"body_part":"script", "compatibility_date": ...}`. Part
  content-type `application/javascript`. Mutually exclusive with
  `--module`.
- `--compatibility-date=YYYY-MM-DD` — pins the Workers runtime
  version. Defaults to today (UTC). Match existing peer Workers to
  keep behavior consistent — `agex-proxy` uses `2026-04-20`.
- `--no-workers-dev` — suppress the default post-upload
  enable-workers.dev-subdomain step. By default (match agex-proxy /
  citation-cli-proxy), the script does two writes: the multipart
  PUT of the script, then a POST to
  `/accounts/{id}/workers/scripts/{name}/subdomain` with
  `{enabled: true, previews_enabled: false}`. The second POST is
  necessary because CF's upload endpoint leaves the `.workers.dev`
  subdomain disabled, unlike the dashboard. Use `--no-workers-dev`
  for private Workers that should only run on Workers routes.
- `--apply` — actually PUT+POST. Without it, dry-run.
- `--json` — merged CloudFlare envelope
  `{success, result: {upload, subdomain}}` (or simulated body in
  dry-run).

Idempotency: pre-flight lists the account's Workers scripts and
refuses with exit 1 if `NAME` already exists. Overwriting an existing
Worker is a separate (future) `cf-worker-update.sh` responsibility.

### cf-workers-route-create.sh

Creates a Workers route on a zone — binds a Worker script to a URL
pattern. The route sits at
`POST /zones/:zone_id/workers/routes` with body
`{pattern, script}`.

```sh
# Dry-run:
bash .claude/skills/cloudflare-write/scripts/cf-workers-route-create.sh \
  culture.dev 'culture.dev/afi*' afi-proxy

# Apply:
bash .claude/skills/cloudflare-write/scripts/cf-workers-route-create.sh \
  culture.dev 'culture.dev/afi*' afi-proxy --apply
```

Positional args:

- `ZONE` — zone name (e.g. `culture.dev`). Resolved to id via the
  usual `cf_api_paginated /zones` lookup.
- `PATTERN` — CF Workers pattern, scheme-less (`culture.dev/afi*`,
  not `https://culture.dev/afi*`). Quote it in the shell so the
  globbing doesn't eat the `*`. Scheme-prefixed patterns are
  rejected up-front.
- `SCRIPT` — name of an existing Workers script (per
  `cf-worker-create.sh` naming rules).

Flags:

- `--apply` — actually POST. Without it, dry-run.
- `--json` — raw CloudFlare response envelope.

Idempotency: pre-flight lists the zone's routes and refuses with
exit 1 if a route with the identical `{pattern, script}` pair
already exists. Different scripts mapped to the same pattern (or the
same script on different patterns) are allowed — only exact dupes
are refused.

### 3.3 cf-pages-deployment-delete.sh

Deletes a single Pages deployment by `SHORT_ID` (8-char prefix) or
full UUID. Dry-run by default; `--apply` to commit.

```sh
# Inventory first (read skill) to pick a short_id:
bash .claude/skills/cloudflare/scripts/cf-pages.sh agentirc-dev

# Dry-run:
bash .claude/skills/cloudflare-write/scripts/cf-pages-deployment-delete.sh \
  agentirc-dev 66aaccee

# Apply for real:
bash .claude/skills/cloudflare-write/scripts/cf-pages-deployment-delete.sh \
  agentirc-dev 66aaccee --apply
```

The **canonical (aliased) deployment is protected by default** — it
is whatever `<project>.pages.dev` currently serves, so deleting it
without replacement breaks the site. If the target is canonical, the
script exits `1` with a refusal message. Override with
`--force-canonical`, which maps to `?force=true` on the CF DELETE
endpoint.

### 3.4 cf-pages-deployments-purge.sh (tick + sign manifest workflow)

Bulk-deletes Pages deployments in a project. Reach for this when a
project has accumulated hundreds of historical deployments
(issue #1: `agentirc-dev` had 138).

"Delete all of them" is one typo from an outage, so the apply path is
gated by a **three-phase manifest workflow** nothing else in this
skill uses:

1. **Plan** — the default invocation (no `--apply`) writes a manifest
   file to `./.cf-purge-manifests/<ts>-<project>.md` listing every
   deployment it *could* delete. Each row is a GFM task-list item
   starting `- [ ]`; at the bottom sits a **canary** row whose random
   22-char alnum string also lives in the `canary:` header. No API
   mutations happen. The manifest directory is gitignored at the repo
   root.

   ```sh
   bash .claude/skills/cloudflare-write/scripts/cf-pages-deployments-purge.sh agentirc-dev
   ```

2. **Tick + sign** — open the manifest, read each row, and change
   `- [ ]` to `- [x]` for every deployment you actually want deleted.
   **Leave the canary row under `## Canary` untouched.** Then append
   exactly one signature line at the bottom:

   ```text
   SIGNED: <your-name-or-agent-id> <ISO-8601-UTC-timestamp>
   ```

   Example: `SIGNED: ori 2026-04-22T14:10:00Z`. The signature must be
   within `CF_PURGE_SIG_TTL` seconds (default 3600) of apply-time.

3. **Apply** — re-run the script with `--manifest <path> --apply`.
   Before any DELETE fires, the script:
   - validates the v2 header, `canary:` field, `ids_sha256`, and
     project + account match,
   - validates the `SIGNED:` line (exactly one, well-formed, fresh),
   - verifies the canary row is present exactly once, its string
     matches the header, and its checkbox is untouched (the
     "sed-replace all `[ ]` with `[x]`" shortcut ticks the canary too
     and aborts the whole apply),
   - refuses if **no deployment boxes are ticked** — that implies the
     operator forgot step 2, not that they want a no-op,
   - **re-fetches live state** and rejects on drift (any new
     non-canonical deployment added since signing), and
   - skips any ticked ids that are already gone (idempotent re-runs).

   ```sh
   bash .claude/skills/cloudflare-write/scripts/cf-pages-deployments-purge.sh \
     agentirc-dev --manifest ./.cf-purge-manifests/20260422T140700Z-agentirc-dev.md --apply
   ```

An `<manifest>.applied.log` is written next to the manifest with
per-id outcomes and final counts — permanent audit trail rather than
stdout-only.

Flags:

- `--include-canonical` — (plan only) include the canonical
  deployment in the manifest. The flag is recorded in the manifest
  header so the operator signs the canonical-inclusion decision
  explicitly. (Apply unconditionally sends `?force=true` on every
  DELETE since CF Pages marks canonical **and** every per-branch
  preview as aliased; `?force=true` is a no-op on unaliased
  deployments. The per-row tick is the real consent gate.)
- `--manifest PATH` — (apply only) path to the signed manifest.
- `--manifest-dir DIR` — (plan only) override the default output
  directory (`./.cf-purge-manifests`).
- `--apply` — actually DELETE. Requires `--manifest`.
- `--continue-on-error` — on a failed DELETE, keep going instead of
  halting. The exit code is still non-zero if any DELETE failed.
- `--json` — structured envelope for both plan and apply phases.
- `CF_PURGE_SIG_TTL` / `CF_PURGE_SLEEP` — env knobs for signature
  TTL and inter-delete pacing. `CF_PURGE_SLEEP=0` disables the
  default 250ms pacing (used by the test suite).

Exit codes: `0` plan wrote manifest (or "nothing to delete") / apply
completed with zero failures; `1` API error / manifest validation
failure / signature invalid / drift detected / any failed DELETE;
`2` usage error.

**Why tick + canary on top of signing?** The signed-manifest layer
answers "is this approval fresh and matching live state?"; the
tick + canary layer answers "which items did the operator *actually*
pick, and did they review each one?"

1. Forces the operator to **mark each deployment individually** —
   the approval granularity is per row, not per manifest.
2. The canary is **randomly generated at plan time** and its string
   must match both the header and the list row, so a "tick the
   entire manifest" shortcut (regex-replace or a distracted
   `sed -i`) also ticks the canary, which aborts apply with zero
   DELETEs. Per-line review is enforced, not just expected.
3. **Reviewable artifact** — the manifest is a concrete diff a peer
   can read and challenge before signing; pairs with
   one-agent-plans-another-agent-signs.
4. **Time-boxed** — a 60-minute-old signature is rejected, so stale
   approvals can't be replayed days later.
5. **Drift-aware** — a new non-canonical deployment appearing
   between plan and apply causes a hard reject, not a silent skip.

This pattern (per-line tick + canary) is the **repo-wide convention
for any future bulk-destructive script**, not just this one. New
`cf-*-delete.sh` / `cf-*-purge.sh` scripts should follow the same
manifest shape.

## 3.5 Sub-site pattern on `culture.dev` (agex-style)

The `culture.dev/agex`, `culture.dev/citation-cli`, and
`culture.dev/afi` sub-sites share a single three-resource pattern:

1. a **Direct Upload** Pages project `NAME` (see §cf-pages-project-create.sh);
2. a **Worker** `NAME-proxy` rendered from
   `templates/subpath-proxy.js` (see §cf-worker-create.sh);
3. a **Workers route** `culture.dev/NAME*` → `NAME-proxy`
   (see §cf-workers-route-create.sh).

For the render-and-deploy recipe, zehut/shushu onboarding, and the
three-URL verification checklist, read the full reference at
`references/subpath-site-pattern.md`.

## 3.6 Templates and references

- `templates/subpath-proxy.js` — subpath-proxy Worker source, two
  placeholders (`__SUBPATH__`, `__UPSTREAM__`). Derived from the
  live `agex-proxy` script and kept deliberately small so updates
  stay reviewable. Render with `sed` before feeding to
  `cf-worker-create.sh`.
- `references/subpath-site-pattern.md` — architecture note for the
  `culture.dev/NAME` sub-site pattern plus a step-by-step recipe for
  standing up a new one.
- `references/cf-api-gotchas.md` — consolidated index of CF API
  quirks we've paid for (Pages `per_page` cap, subdomain auto-suffix,
  Workers multipart `filename` matching, Workers subdomain endpoint
  method, Workers subdomain default, zone-scope 10000). Read this
  before your first live `--apply` against a surface you haven't
  written to before.

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
- **Deleting the Pages project itself.** `cf-pages-deployments-purge.sh`
  deletes every deployment but leaves the zero-deployment project
  behind. A future `cf-pages-project-delete.sh` will land as a
  separate, smaller PR.
- **Workers / DNS / zone deletion.** Still Phase 3 territory; new
  `cf-*-delete.sh` scripts can follow the same dry-run-by-default
  pattern. Whether to re-use the manifest gate depends on blast
  radius — a single DNS record rarely warrants it; bulk route
  deletion probably does.
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
