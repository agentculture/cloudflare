# Repoint `culture.dev` Cloudflare Pages to `agentculture/katvan`

Tracking issue: [agentculture/cultureflare#34][issue34]. Upstream
context: [agentculture/katvan#1][katvan1] — Phase 0a of the
culture/katvan docs-site split.

## Problem

The `culture.dev` documentation site was migrated out of
`agentculture/culture` into a dedicated repo, `agentculture/katvan`.
katvan's `main` now builds the complete site green. The last step
before culture can delete its copy of the site is repointing the
Cloudflare Pages deployment that serves `culture.dev` from
`agentculture/culture` to `agentculture/katvan` — with a build config
change, because katvan keeps its Jekyll project under a `site/`
subdirectory rather than at the repo root.

Two facts make this more than a one-script task:

- **No tooling exists for it.** `cultureflare-write` does no updates
  (PUT/PATCH) and has no custom-domain script. It can *create* a
  GitHub-connected Pages project (`cf-pages-project-create.sh`), but
  nothing binds or moves a custom domain, and the create script
  cannot set deployment environment variables.
- **`culture.dev` must not 404 at any point.** Production agents
  (spark-culture and peers) reference `culture.dev` URLs in their
  flows; even a momentary outage risks breaking them.

## Goal

Cut `culture.dev` over to a katvan-backed Cloudflare Pages project
with no human-perceptible outage, then signal katvan so culture can
file its Phase 1 PR deleting the duplicate site files. Deliver the
missing `cultureflare-write` tooling as proper, reviewed scripts so
the cutover runs behind the repo's dry-run-by-default safety rail and
the tooling is reusable for the pending `zehut` / `shushu`
migrations.

## Non-goals

- **In-place repoint of the existing project.** Rejected in favor of
  a new project (see Decisions). No `cf-pages-project-update.sh`.
- **Deleting the old `culture-dev` Pages project.** It stays in place
  as the rollback target. Its eventual deletion is Phase 4 / a later
  issue.
- **Deleting the duplicate site files from `agentculture/culture`.**
  That is culture's Phase 1 PR, filed by culture after this cutover
  completes — out of this repo's scope.
- **A standalone `cf-pages-env-set.sh` (PATCH).** Environment
  variables are set at project-creation time by extending
  `cf-pages-project-create.sh`; a standalone env-setter would be the
  "update" category the skill deliberately avoids.
- **The manifest/canary gate on `cf-pages-domain-remove.sh`.** That
  pattern is for *bulk* destructive ops. A single named-domain detach
  wrapped in the cutover runbook is the same blast-radius class as
  `cf-dns-create.sh` — dry-run-by-default + explicit `--apply` + a
  loud dry-run banner is the safety model.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Cutover mechanism | **New Pages project** + custom-domain move | Verify on the new project's `*.pages.dev` preview *before* touching the live domain; avoids the unreliable "re-link a connected GitHub repo via API" path; uses the existing `cf-pages-project-create.sh`. The `*.pages.dev` hostname changes — katvan has no preference on that. |
| Tooling | **Proper write-skill scripts + PR** | Keeps the production-critical mutations behind dry-run-by-default; leaves reusable domain-move tooling for `zehut` / `shushu`. |
| No-dark-window posture | **Minimize + rollback-ready** | The apex custom-domain move is inherently remove-then-add. Step 0 finds the tightest sequence; execute off-peak with a one-command rollback ready. "No dark window" read as "no human-perceptible outage." |
| Env-var tooling | **Extend `cf-pages-project-create.sh`** | New-project path sets env vars at creation time; a standalone setter would be a PATCH. |
| New project name | `katvan` | Matches the source repo; `katvan.pages.dev` is the preview host. |

## Architecture

Two parts, strictly ordered: **Part A** (tooling) merges first, then
**Part B** (the cutover) runs the merged scripts with `--apply`.

### Part A — new `cultureflare-write` tooling (one PR)

Three deliverables, each following the pattern `cf-redirect-create.sh`
sets (arg loop, `_lib.sh` source, name→ID resolution, pre-flight
idempotency check, `jq -n` body, `--apply` gate, `--json`).

1. **`cf-pages-domain-add.sh PROJECT DOMAIN [--apply] [--json]`**
   - `POST /accounts/{acct}/pages/projects/{project}/domains` with
     body `{"name": "<domain>"}`.
   - Pre-flight: account id present; `PROJECT` exists in the account;
     `DOMAIN` not already attached to `PROJECT` (GET the project's
     `/domains`, refuse with exit 1 on a dup).
   - URL-encode `PROJECT` and `DOMAIN` before path interpolation.
   - Dry-run prints the `would POST` body; `--apply` POSTs.

2. **`cf-pages-domain-remove.sh PROJECT DOMAIN [--apply] [--json]`**
   - `DELETE /accounts/{acct}/pages/projects/{project}/domains/{domain}`.
   - Pre-flight: account id present; `PROJECT` exists; `DOMAIN` *is*
     currently attached to `PROJECT` (else exit 1 — nothing to
     remove).
   - This is the step that can take `culture.dev` dark. The dry-run
     banner is explicit about blast radius (names the project and
     domain, states that the domain will stop serving from this
     project). No manifest/canary gate — see Non-goals.
   - Dry-run prints the `would DELETE` path; `--apply` DELETEs.

3. **`--env-var=KEY=VALUE` (repeatable) on `cf-pages-project-create.sh`**
   - Uses the repo's `--flag=value` convention (space-separated flag
     values are rejected repo-wide); `${arg#*=}` yields `KEY=VALUE`.
   - Each occurrence parsed into a `{KEY: {type:"plain_text",
     value:VALUE}}` entry, merged into **both**
     `deployment_configs.preview.env_vars` and
     `deployment_configs.production.env_vars` in the POST body.
   - `KEY` validated as `^[A-Za-z_][A-Za-z0-9_]*$`; an `--env-var=`
     value missing the inner `=` is a usage error (exit 2).
   - Reflected in the dry-run markdown summary and the `would POST`
     body. `--clone-from` still only clones build/deploy config, not
     env vars; explicit `--env-var` flags are additive.

Housekeeping in the same PR: bats + curl-stub fixtures for all three
(dry-run, apply, idempotency, name resolution, unknown flag, `--json`
— and for the create-script change, env-var parsing + the malformed
`KEY=VALUE` usage error); `SKILL.md` script-table entries for the two
new scripts and the new flag; `shellcheck` + `markdownlint` clean;
`doctest-align` check; version bump + CHANGELOG entry. No token-scope
change — `Account · Cloudflare Pages · Edit` already covers
custom-domain add/remove.

### Part B — the cutover runbook

Executed after Part A merges. Each live step uses the merged scripts
with `--apply`.

**Step 0 — Credentials + live-state investigation.**

- Operator provides a write-scoped token (`Account · Cloudflare
  Pages · Edit` plus the read scopes) via `.env` or the environment,
  per `docs/SETUP.md` §2.5.
- Confirm the Cloudflare Pages GitHub App has `agentculture/katvan`
  access — a GitHub-org-admin check that cannot be automated. If it
  is missing, Step 1's `--apply` fails with a CF "repo unreachable"
  error and the fix is a one-time GitHub-org-admin action.
- `cf-status.sh`; `cf-dns.sh culture.dev`; `cf-workers-routes.sh` —
  establish the **old project's exact name** (assumed `culture-dev`),
  how the `culture.dev` apex and any `www.culture.dev` are wired, the
  current custom-domain bindings, and the tightest possible
  domain-move sequence. Record the resolved IDs / names in session
  `MEMORY.md`.

**Step 1 — Create the new Pages project** (creating a
GitHub-connected project triggers an initial production build from
`main` automatically):

```sh
cf-pages-project-create.sh katvan agentculture katvan \
  --clone-from=culture-dev \
  --root-dir=site \
  --build-command='bundle exec jekyll build --config _config.base.yml,_config.culture.yml -d _site_culture' \
  --destination-dir=_site_culture \
  --env-var=JEKYLL_ENV=production \
  --env-var=RUBY_VERSION=3.3 \
  --apply
```

`--clone-from=culture-dev` carries over compatibility-date and
build-image version; the three build-config flags and the two
`--env-var` flags override per the issue's build-config table.

**Step 2 — Verify the preview build** on `katvan.pages.dev` once the
initial deployment is green, against the issue's checklist: `/`,
`/agentirc/`, `/reference/cli/`, `/sitemap.xml`,
`/sitemap-main.xml`, `/agentirc/sitemap.xml`, `/robots.txt`,
`/favicon.ico`, and that the sidebar nav tree + search box render. If
the build breaks katvan-side (e.g. Ruby version), file a focused
issue on `agentculture/katvan` per the round-trip protocol in
katvan#1.

**Step 3 — Move the custom domain** (the critical step; off-peak,
back-to-back):

```sh
cf-pages-domain-remove.sh culture-dev culture.dev --apply
cf-pages-domain-add.sh    katvan      culture.dev --apply
```

Plus `www.culture.dev` if Step 0 finds it is a custom domain too.
**Rollback:** `cf-pages-domain-add.sh culture-dev culture.dev --apply`
re-attaches the domain to the old project, which remains fully intact.

**Step 4 — Verify `culture.dev`** serves from katvan with no 404s
(same checklist as Step 2, against `culture.dev` itself), and confirm
the `/afi/`, `/agex/`, `/citation-cli/` Workers routes still resolve.
Those routes are zone-level and hostname/path-matched, so they are
independent of which Pages project serves the apex — but the issue
explicitly asks to verify they apply cleanly.

**Step 5 — Signal katvan.** Only after Step 4 passes: comment on
`agentculture/katvan#1` via the `communicate` skill that the cutover
is complete, so culture can file its Phase 1 PR. The old
`culture-dev` project is left in place as rollback.

## Data flow

```
Part A (PR, reviewed, merged)
  cf-pages-domain-add.sh      ── POST   /accounts/{a}/pages/projects/{p}/domains
  cf-pages-domain-remove.sh   ── DELETE /accounts/{a}/pages/projects/{p}/domains/{d}
  cf-pages-project-create.sh  ── POST   /accounts/{a}/pages/projects  (+ env_vars)

Part B (runbook, uses the merged scripts)
  Step 0  read-only: cf-status / cf-dns / cf-workers-routes  → MEMORY.md
  Step 1  cf-pages-project-create.sh ... --apply             → katvan.pages.dev + auto-build
  Step 2  verify katvan.pages.dev                            → checklist
  Step 3  cf-pages-domain-remove.sh culture-dev culture.dev --apply
          cf-pages-domain-add.sh    katvan      culture.dev --apply
  Step 4  verify culture.dev + Workers routes                → checklist
  Step 5  communicate → comment on katvan#1
```

## Error handling

- **Part A scripts** follow the skill's exit-code convention: `0`
  success (dry-run or apply), `1` API error / idempotency violation /
  name not found, `2` usage error. Idempotency is enforced locally
  before any mutating call.
- **Step 1 fails (GitHub App)** — CF returns a "repo unreachable"
  error; the create script surfaces it and exits 1. Fix is the
  GitHub-org-admin install/authorization step, then re-run.
- **Step 2 build fails** — iterate on build config; if it is a
  katvan-side content/toolchain issue, file a focused issue on
  `agentculture/katvan` and pause the runbook.
- **Step 3 add fails after remove succeeded** — `culture.dev` is
  dark; immediately run the rollback (`cf-pages-domain-add.sh
  culture-dev culture.dev --apply`) to re-attach to the intact old
  project, then diagnose.

## Testing

- **Part A:** bats with PATH-injected curl-stub fixtures for each
  script — dry-run, apply, idempotency refusal, name resolution,
  unknown flag, `--json` passthrough; plus env-var parsing and the
  malformed-`KEY=VALUE` usage error for the create-script change.
  `tests/shellcheck.sh`, `tests/markdownlint.sh`, `bats tests/bats/`,
  and the `doctest-align` agent all clean before the PR.
- **Part B:** verified by the live verification checklists in
  Steps 2 and 4. No automated coverage — it is a one-time runbook.

## Risks / open items

- **GitHub App → `agentculture/katvan` access** — hard prerequisite
  for Step 1; cannot be automated; surfaced as a CF error if missing.
- **Domain-move window** — Step 0 measures it and finds the tightest
  sequence; posture is minimize + rollback-ready.
- **Ruby pin** — `RUBY_VERSION=3.3` as a deployment env var should
  match katvan's CI. If CF's build image does not honor it, the
  fallback is asking katvan to add `site/.ruby-version` (per the
  open question in issue #34).
- **Old project name** — this design assumes `culture-dev`; Step 0
  confirms the exact name against live state before any `--apply`.
- **`www.culture.dev`** — whether it is a separate custom domain is
  unknown until Step 0; if it is, it gets the same remove/add
  treatment in Step 3.

[issue34]: https://github.com/agentculture/cultureflare/issues/34
[katvan1]: https://github.com/agentculture/katvan/issues/1
