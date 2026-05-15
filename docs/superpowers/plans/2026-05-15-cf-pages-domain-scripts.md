# Part A — `cultureflare-write` Pages-domain tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the three `cultureflare-write` capabilities the `culture.dev` → `agentculture/katvan` Cloudflare Pages cutover needs — `cf-pages-domain-add.sh`, `cf-pages-domain-remove.sh`, and `--env-var=KEY=VALUE` on `cf-pages-project-create.sh` — as one reviewed PR.

**Architecture:** Two new bash scripts plus one extension, each following the established `cultureflare-write` pattern (arg loop → name validation → `_lib.sh` source → pre-flight idempotency GET → `jq -n` body → `--apply` gate → `--json` passthrough). Both new scripts use a single GET to the project's `/domains` list endpoint, which doubles as the project-existence check. Dry-run is the default; the live mutation only fires with `--apply`.

**Tech Stack:** bash + `curl` + `jq`; `bats` with a PATH-injected `curl` stub for offline tests; `shellcheck` and `markdownlint-cli2` for lint; `version-bump` skill for the release bump.

**Scope:** This plan is **Part A** of the spec `docs/superpowers/specs/2026-05-15-culture-dev-katvan-cutover-design.md`. **Part B** (the live cutover runbook) is executed against live Cloudflare state *after* this PR merges and is not part of this plan.

**Branch:** `feat/cf-pages-domain-scripts` (already created from latest `main`; the design doc is already committed on it).

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `tests/fixtures/pages_domains_katvan.json` | Domains-list fixture: a project with no custom domains attached | 1 |
| `tests/fixtures/pages_domains_culture_dev.json` | Domains-list fixture: a project with `culture.dev` attached | 1 |
| `tests/fixtures/pages_domain_add_ok.json` | `POST .../domains` success response | 1 |
| `tests/fixtures/pages_domain_remove_ok.json` | `DELETE .../domains/{d}` success response | 1 |
| `.claude/skills/cultureflare-write/scripts/cf-pages-domain-add.sh` | Bind a custom domain to a Pages project | 2 |
| `tests/bats/cf-pages-domain-add.bats` | bats coverage for `cf-pages-domain-add.sh` | 2 |
| `.claude/skills/cultureflare-write/scripts/cf-pages-domain-remove.sh` | Detach a custom domain from a Pages project | 3 |
| `tests/bats/cf-pages-domain-remove.bats` | bats coverage for `cf-pages-domain-remove.sh` | 3 |
| `.claude/skills/cultureflare-write/scripts/cf-pages-project-create.sh` | **Modified:** add `--env-var=KEY=VALUE` | 4 |
| `tests/bats/cf-pages-project-create.bats` | **Modified:** add `--env-var` coverage | 4 |
| `.claude/skills/cultureflare-write/SKILL.md` | **Modified:** document the two new scripts + the new flag | 5 |
| `pyproject.toml`, `CHANGELOG.md` | **Modified:** version bump 0.7.0 → 0.8.0 | 6 |

> **Note on literal tabs:** `tests/bats/test_helper.bash` logs each `curl` invocation tab-separated. Several assertions below (`cf_assert_called "-X⇥POST"`, the `_assert_no_post` / `_assert_no_delete` helpers) contain a **literal TAB character** between tokens — shown here as `⇥` only where ambiguous, but written as a real tab in the file. Copy them from the existing `tests/bats/cf-pages-deployment-delete.bats` / `cf-pages-project-create.bats` if in doubt: those files use the identical pattern.

---

## Task 1: Test fixtures for the domain scripts

Both new scripts' bats files reference these fixtures via `cf_mock`. Create them first so Tasks 2 and 3 are clean TDD cycles. These are JSON data files — no test cycle, just create and commit.

**Files:**
- Create: `tests/fixtures/pages_domains_katvan.json`
- Create: `tests/fixtures/pages_domains_culture_dev.json`
- Create: `tests/fixtures/pages_domain_add_ok.json`
- Create: `tests/fixtures/pages_domain_remove_ok.json`

- [ ] **Step 1: Create `tests/fixtures/pages_domains_katvan.json`**

A project with zero custom domains — the pre-flight state for an *add*, and the "not attached" state for a *remove*.

```json
{
  "success": true,
  "errors": [],
  "messages": [],
  "result": [],
  "result_info": {"page": 1, "per_page": 10, "total_pages": 1, "count": 0, "total_count": 0}
}
```

- [ ] **Step 2: Create `tests/fixtures/pages_domains_culture_dev.json`**

A project with `culture.dev` already attached — the idempotency-violation state for an *add*, and the valid pre-flight state for a *remove*.

```json
{
  "success": true,
  "errors": [],
  "messages": [],
  "result": [
    {
      "id": "domain-id-culture-dev",
      "name": "culture.dev",
      "status": "active",
      "created_on": "2026-04-10T18:35:00.000000Z"
    }
  ],
  "result_info": {"page": 1, "per_page": 10, "total_pages": 1, "count": 1, "total_count": 1}
}
```

- [ ] **Step 3: Create `tests/fixtures/pages_domain_add_ok.json`**

The `POST .../domains` success envelope.

```json
{
  "success": true,
  "errors": [],
  "messages": [],
  "result": {
    "id": "domain-id-culture-dev-new",
    "name": "culture.dev",
    "status": "pending",
    "created_on": "2026-05-15T12:00:00.000000Z"
  }
}
```

- [ ] **Step 4: Create `tests/fixtures/pages_domain_remove_ok.json`**

The `DELETE .../domains/{domain}` success envelope. Cloudflare returns a `null` result for this endpoint.

```json
{
  "success": true,
  "errors": [],
  "messages": [],
  "result": null
}
```

- [ ] **Step 5: Verify all four files are valid JSON**

Run: `for f in tests/fixtures/pages_domains_katvan.json tests/fixtures/pages_domains_culture_dev.json tests/fixtures/pages_domain_add_ok.json tests/fixtures/pages_domain_remove_ok.json; do jq -e . "$f" >/dev/null && echo "OK $f"; done`
Expected: four `OK ...` lines, exit 0.

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/pages_domains_katvan.json tests/fixtures/pages_domains_culture_dev.json tests/fixtures/pages_domain_add_ok.json tests/fixtures/pages_domain_remove_ok.json
git commit -m "test: fixtures for cf-pages-domain-{add,remove} scripts (#34)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `cf-pages-domain-add.sh`

Binds a custom domain to a Pages project via `POST /accounts/{acct}/pages/projects/{project}/domains` with body `{"name": "<domain>"}`. Pre-flight: a paginated GET of the project's `/domains` list confirms the project exists (a missing project surfaces Cloudflare's structured error) and that the domain is not already attached.

**Files:**
- Create: `tests/bats/cf-pages-domain-add.bats`
- Create: `.claude/skills/cultureflare-write/scripts/cf-pages-domain-add.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/bats/cf-pages-domain-add.bats`. The `_assert_no_post` helper and the `⇥` characters are **literal tabs** (copy the helper verbatim from `tests/bats/cf-pages-project-create.bats`).

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cfafi-write/scripts"
}

# Helper — asserts curl was NEVER invoked with `-X POST` (literal tabs).
_assert_no_post() {
  if grep -qF '	-X	POST	' "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
    echo "expected no POST, but curl.log contains one:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2
    return 1
  fi
  return 0
}

# --- usage errors ---

@test "cf-pages-domain-add exits 2 when positional args missing" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected PROJECT and DOMAIN"* ]]
}

@test "cf-pages-domain-add exits 2 with only one positional arg" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected PROJECT and DOMAIN"* ]]
}

@test "cf-pages-domain-add exits 2 on unknown flag" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan culture.dev --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-pages-domain-add exits 2 on invalid project name" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" 'bad name!' culture.dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid project name"* ]]
}

@test "cf-pages-domain-add exits 2 on invalid domain" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan 'not a domain!'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid domain"* ]]
}

# --- dry-run (default, no --apply) ---

@test "cf-pages-domain-add dry-run prints banner and would-POST body, no POST call" {
  cf_mock "/pages/projects/katvan/domains?per_page" "pages_domains_katvan.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan culture.dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"**project:** katvan"* ]]
  [[ "$output" == *"**domain:** culture.dev"* ]]
  [[ "$output" == *"**would POST**"* ]]
  [[ "$output" == *'"name": "culture.dev"'* ]]
  _assert_no_post
}

@test "cf-pages-domain-add --json dry-run emits synthetic envelope" {
  cf_mock "/pages/projects/katvan/domains?per_page" "pages_domains_katvan.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan culture.dev --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.project == "katvan"'
  echo "$output" | jq -e '.result.domain == "culture.dev"'
  echo "$output" | jq -e '.result.would_post.name == "culture.dev"'
  [[ "$output" != *"Dry-run — no changes applied"* ]]
  _assert_no_post
}

# --- apply path ---

@test "cf-pages-domain-add --apply POSTs the domain body and reports status" {
  cf_mock "/pages/projects/katvan/domains?per_page" "pages_domains_katvan.json"
  cf_mock "/pages/projects/katvan/domains"          "pages_domain_add_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan culture.dev --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Custom domain added**"* ]]
  [[ "$output" == *"**status:** pending"* ]]
  cf_assert_called "-X	POST"
  cf_assert_called "/accounts/test-account-id/pages/projects/katvan/domains"
}

@test "cf-pages-domain-add --apply --json passes CF response envelope through" {
  cf_mock "/pages/projects/katvan/domains?per_page" "pages_domains_katvan.json"
  cf_mock "/pages/projects/katvan/domains"          "pages_domain_add_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan culture.dev --apply --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.name == "culture.dev"'
  [[ "$output" != *"Custom domain added"* ]]
}

# --- idempotency & resolution errors ---

@test "cf-pages-domain-add exits 1 when domain already attached" {
  cf_mock "/pages/projects/culture-dev/domains?per_page" "pages_domains_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" culture-dev culture.dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"already attached"* ]]
  _assert_no_post
}

@test "cf-pages-domain-add exits 1 when project does not exist and surfaces the CF error" {
  cf_mock "/pages/projects/nosuch/domains" "pages_project_not_found.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" nosuch culture.dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"Project not found"* ]]
  [[ "$output" == *"could not resolve Pages project"* ]]
  _assert_no_post
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/bats/cf-pages-domain-add.bats`
Expected: every test FAILs — the script does not exist yet (`bash: .../cf-pages-domain-add.sh: No such file or directory`).

- [ ] **Step 3: Write the implementation**

Create `.claude/skills/cultureflare-write/scripts/cf-pages-domain-add.sh`:

```bash
#!/usr/bin/env bash
# Add a custom domain to a CloudFlare Pages project.
#
# Usage:
#   cf-pages-domain-add.sh PROJECT DOMAIN [--apply] [--json]
#
# Default is DRY-RUN: lists the project's custom domains (which also
# confirms the project exists), checks DOMAIN is not already attached,
# prints the JSON body it would POST, and exits 0 WITHOUT mutating
# anything. Pass --apply to actually POST.
#
# Prerequisites for --apply to succeed against the live API:
#   * CLOUDFLARE_API_TOKEN has Account · Cloudflare Pages · Edit
#
# Flags:
#   --apply   actually POST (without it, this is a dry-run)
#   --json    raw CloudFlare response envelope (or simulated body in dry-run)
#
# Exits 1 on: account id missing, project not found, domain already
#   attached, API error. Exits 2 on usage error.

set -euo pipefail
shopt -s inherit_errexit

mode=md
apply=0
positional=()

for arg in "$@"; do
  case "$arg" in
    --json)   mode=json ;;
    --apply)  apply=1 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
      exit 0
      ;;
    -*)
      echo "ERROR: unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      positional+=("$arg")
      ;;
  esac
done

if (( ${#positional[@]} != 2 )); then
  echo "ERROR: expected PROJECT and DOMAIN positional args, got ${#positional[@]}" >&2
  echo "usage: cf-pages-domain-add.sh PROJECT DOMAIN [--apply] [--json]" >&2
  exit 2
fi
project="${positional[0]}"
domain="${positional[1]}"

# Project name is CF-restricted (lowercase alnum, dashes; dashboard-era
# projects also allow dots / underscores). Domain is a hostname. Reject
# anything that could escape the URL path before we interpolate.
if [[ ! "$project" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo "ERROR: invalid project name: $project" >&2
  exit 2
fi
if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
  echo "ERROR: invalid domain: $domain" >&2
  exit 2
fi

# shellcheck source=../../cloudflare/scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cf_require_account_id

project_encoded=$(jq -rn --arg v "$project" '$v|@uri')

# Pre-flight: list the project's custom domains. This GET doubles as
# the project-existence check — a missing project returns CF's
# structured "Project not found" error, which cf_api surfaces (don't
# silence its stderr) before exiting 1. Pages list endpoints cap
# per_page at 10 (CF error 8000024 on >=11); scope CF_PAGE_SIZE to
# this call so other cf_api_paginated callers are unaffected.
if ! domains_json=$(CF_PAGE_SIZE=10 cf_api_paginated "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/domains"); then
  echo "HINT: could not resolve Pages project '$project'. Check the project name with cf-pages.sh." >&2
  exit 1
fi

# Idempotency: refuse if DOMAIN is already attached to this project.
# shellcheck disable=SC2016  # single-quoted jq filter
if printf '%s' "$domains_json" | jq -e --arg d "$domain" 'any(.result[]; .name == $d)' >/dev/null; then
  echo "ERROR: domain '$domain' is already attached to Pages project '$project'" >&2
  exit 1
fi

post_path="/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/domains"
# shellcheck disable=SC2016  # single-quoted jq filter
body=$(jq -n --arg name "$domain" '{name: $name}')

render_summary_kv() {
  printf -- '- **project:** %s\n' "$project"
  printf -- '- **domain:** %s\n' "$domain"
  printf -- '- **account:** %s\n' "$CLOUDFLARE_ACCOUNT_ID"
  return 0
}

if (( apply == 0 )); then
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n --argjson body "$body" --arg account "$CLOUDFLARE_ACCOUNT_ID" \
      --arg project "$project" --arg domain "$domain" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, account_id: $account, project: $project,
                 domain: $domain, would_post: $body}}'
    exit 0
  fi
  printf '**Dry-run — no changes applied**\n\n'
  render_summary_kv
  # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
  printf '\n**would POST** `%s`:\n\n' "$post_path"
  printf '```json\n'
  printf '%s\n' "$body"
  printf '```\n'
  exit 0
fi

response=$(cf_api "$post_path" -X POST --data-binary "$body")

if [[ "$mode" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

status=$(printf '%s' "$response" | jq -r '.result.status // "—"')
printf '**Custom domain added**\n\n'
render_summary_kv
printf -- '- **status:** %s\n' "$status"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/bats/cf-pages-domain-add.bats`
Expected: all tests PASS.

- [ ] **Step 5: Shellcheck the new script**

Run: `shellcheck -e SC1091 .claude/skills/cultureflare-write/scripts/cf-pages-domain-add.sh`
Expected: no output, exit 0. If SC2016 fires on a `jq` line that lacks a `# shellcheck disable=SC2016` comment, add `# shellcheck disable=SC2016  # single-quoted jq filter` on the line directly above it (matching the comments already shown in Step 3).

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/cultureflare-write/scripts/cf-pages-domain-add.sh tests/bats/cf-pages-domain-add.bats
git commit -m "feat(skills): cf-pages-domain-add.sh — bind a custom domain to a Pages project (#34)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `cf-pages-domain-remove.sh`

Detaches a custom domain via `DELETE /accounts/{acct}/pages/projects/{project}/domains/{domain}`. Same pre-flight GET as Task 2, but the idempotency check is inverted: refuse if the domain is **not** attached. Because this is the step that can take a production domain dark, the dry-run banner names the project and domain explicitly.

**Files:**
- Create: `tests/bats/cf-pages-domain-remove.bats`
- Create: `.claude/skills/cultureflare-write/scripts/cf-pages-domain-remove.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/bats/cf-pages-domain-remove.bats`. The `_assert_no_delete` helper and the `cf_assert_called "-X⇥DELETE"` patterns use **literal tabs** (copy from `tests/bats/cf-pages-deployment-delete.bats`).

```bash
#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cfafi-write/scripts"
}

# Helper — asserts curl was NEVER invoked with `-X DELETE` (literal tab).
_assert_no_delete() {
  if grep -qF -- '-X	DELETE' "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
    echo "expected no DELETE, but curl.log contains one:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2
    return 1
  fi
  return 0
}

# --- usage errors ---

@test "cf-pages-domain-remove exits 2 when positional args missing" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected PROJECT and DOMAIN"* ]]
}

@test "cf-pages-domain-remove exits 2 on unknown flag" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev culture.dev --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-pages-domain-remove exits 2 on invalid project name" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" 'bad name!' culture.dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid project name"* ]]
}

@test "cf-pages-domain-remove exits 2 on invalid domain" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev 'not a domain!'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid domain"* ]]
}

# --- dry-run (default, no --apply) ---

@test "cf-pages-domain-remove dry-run prints loud banner and would-DELETE, no DELETE call" {
  cf_mock "/pages/projects/culture-dev/domains?per_page" "pages_domains_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev culture.dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"will stop serving from project"* ]]
  [[ "$output" == *"**project:** culture-dev"* ]]
  [[ "$output" == *"**domain:** culture.dev"* ]]
  [[ "$output" == *"would DELETE"* ]]
  [[ "$output" == *"/pages/projects/culture-dev/domains/culture.dev"* ]]
  _assert_no_delete
}

@test "cf-pages-domain-remove --json dry-run emits synthetic envelope" {
  cf_mock "/pages/projects/culture-dev/domains?per_page" "pages_domains_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev culture.dev --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.project == "culture-dev"'
  echo "$output" | jq -e '.result.domain == "culture.dev"'
  echo "$output" | jq -e '.result.would_delete | endswith("/domains/culture.dev")'
  _assert_no_delete
}

# --- apply path ---

@test "cf-pages-domain-remove --apply DELETEs the domain" {
  cf_mock "/pages/projects/culture-dev/domains?per_page"    "pages_domains_culture_dev.json"
  cf_mock "/pages/projects/culture-dev/domains/culture.dev" "pages_domain_remove_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev culture.dev --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Custom domain removed**"* ]]
  cf_assert_called "-X	DELETE"
  cf_assert_called "/pages/projects/culture-dev/domains/culture.dev"
}

@test "cf-pages-domain-remove --apply --json passes CF response envelope through" {
  cf_mock "/pages/projects/culture-dev/domains?per_page"    "pages_domains_culture_dev.json"
  cf_mock "/pages/projects/culture-dev/domains/culture.dev" "pages_domain_remove_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev culture.dev --apply --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  [[ "$output" != *"Custom domain removed"* ]]
}

# --- idempotency & resolution errors ---

@test "cf-pages-domain-remove exits 1 when domain not attached" {
  cf_mock "/pages/projects/katvan/domains?per_page" "pages_domains_katvan.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" katvan culture.dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"not attached"* ]]
  [[ "$output" == *"nothing to remove"* ]]
  _assert_no_delete
}

@test "cf-pages-domain-remove exits 1 when project does not exist and surfaces the CF error" {
  cf_mock "/pages/projects/nosuch/domains" "pages_project_not_found.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" nosuch culture.dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"Project not found"* ]]
  [[ "$output" == *"could not resolve Pages project"* ]]
  _assert_no_delete
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bats tests/bats/cf-pages-domain-remove.bats`
Expected: every test FAILs — the script does not exist yet.

- [ ] **Step 3: Write the implementation**

Create `.claude/skills/cultureflare-write/scripts/cf-pages-domain-remove.sh`:

```bash
#!/usr/bin/env bash
# Remove a custom domain from a CloudFlare Pages project.
#
# Usage:
#   cf-pages-domain-remove.sh PROJECT DOMAIN [--apply] [--json]
#
# Default is DRY-RUN: lists the project's custom domains (which also
# confirms the project exists), confirms DOMAIN is currently attached,
# prints the DELETE URL it would hit, and exits 0 WITHOUT mutating
# anything. Pass --apply to actually DELETE.
#
# This is the step that can take a production domain dark — detaching a
# custom domain stops that domain serving from this project. The
# dry-run output names the project and domain explicitly so the blast
# radius is reviewable before --apply.
#
# Prerequisites for --apply to succeed against the live API:
#   * CLOUDFLARE_API_TOKEN has Account · Cloudflare Pages · Edit
#
# Flags:
#   --apply   actually DELETE (without it, this is a dry-run)
#   --json    raw CloudFlare response envelope (or simulated body in dry-run)
#
# Exits 1 on: account id missing, project not found, domain not
#   attached, API error. Exits 2 on usage error.

set -euo pipefail
shopt -s inherit_errexit

mode=md
apply=0
positional=()

for arg in "$@"; do
  case "$arg" in
    --json)   mode=json ;;
    --apply)  apply=1 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
      exit 0
      ;;
    -*)
      echo "ERROR: unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      positional+=("$arg")
      ;;
  esac
done

if (( ${#positional[@]} != 2 )); then
  echo "ERROR: expected PROJECT and DOMAIN positional args, got ${#positional[@]}" >&2
  echo "usage: cf-pages-domain-remove.sh PROJECT DOMAIN [--apply] [--json]" >&2
  exit 2
fi
project="${positional[0]}"
domain="${positional[1]}"

if [[ ! "$project" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo "ERROR: invalid project name: $project" >&2
  exit 2
fi
if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
  echo "ERROR: invalid domain: $domain" >&2
  exit 2
fi

# shellcheck source=../../cloudflare/scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cf_require_account_id

project_encoded=$(jq -rn --arg v "$project" '$v|@uri')
domain_encoded=$(jq -rn --arg v "$domain" '$v|@uri')

# Pre-flight: list the project's custom domains. Doubles as the
# project-existence check (a missing project surfaces CF's structured
# error via cf_api). Pages list endpoints cap per_page at 10.
if ! domains_json=$(CF_PAGE_SIZE=10 cf_api_paginated "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/domains"); then
  echo "HINT: could not resolve Pages project '$project'. Check the project name with cf-pages.sh." >&2
  exit 1
fi

# Refuse if DOMAIN is NOT attached — there is nothing to remove, and a
# silent no-op would hide a typo'd domain or project name.
# shellcheck disable=SC2016  # single-quoted jq filter
if ! printf '%s' "$domains_json" | jq -e --arg d "$domain" 'any(.result[]; .name == $d)' >/dev/null; then
  echo "ERROR: domain '$domain' is not attached to Pages project '$project' — nothing to remove" >&2
  exit 1
fi

delete_path="/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/domains/$domain_encoded"

render_summary_kv() {
  printf -- '- **project:** %s\n' "$project"
  printf -- '- **domain:** %s\n' "$domain"
  printf -- '- **account:** %s\n' "$CLOUDFLARE_ACCOUNT_ID"
  return 0
}

if (( apply == 0 )); then
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n --arg account "$CLOUDFLARE_ACCOUNT_ID" --arg project "$project" \
      --arg domain "$domain" --arg delete_path "$delete_path" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, account_id: $account, project: $project,
                 domain: $domain, would_delete: $delete_path}}'
    exit 0
  fi
  printf '**Dry-run — no changes applied**\n\n'
  printf '**This detaches a custom domain — `%s` will stop serving from project `%s`.**\n\n' "$domain" "$project"
  render_summary_kv
  # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
  printf '\n**would DELETE** `%s`\n' "$delete_path"
  exit 0
fi

response=$(cf_api "$delete_path" -X DELETE)

if [[ "$mode" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

printf '**Custom domain removed**\n\n'
render_summary_kv
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bats tests/bats/cf-pages-domain-remove.bats`
Expected: all tests PASS.

- [ ] **Step 5: Shellcheck the new script**

Run: `shellcheck -e SC1091 .claude/skills/cultureflare-write/scripts/cf-pages-domain-remove.sh`
Expected: no output, exit 0. (Same SC2016 contingency as Task 2 Step 5 if needed.)

- [ ] **Step 6: Commit**

```bash
git add .claude/skills/cultureflare-write/scripts/cf-pages-domain-remove.sh tests/bats/cf-pages-domain-remove.bats
git commit -m "feat(skills): cf-pages-domain-remove.sh — detach a custom domain from a Pages project (#34)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `--env-var=KEY=VALUE` on `cf-pages-project-create.sh`

Add a repeatable `--env-var=KEY=VALUE` flag that injects `env_vars` into **both** `deployment_configs.preview` and `deployment_configs.production` in the POST body. Uses the repo's `--flag=value` convention; `${arg#*=}` yields `KEY=VALUE`. When no `--env-var` flag is given, the body omits `env_vars` entirely (same treatment as an unset `compatibility_date`).

**Files:**
- Modify: `tests/bats/cf-pages-project-create.bats` (append new `@test` blocks)
- Modify: `.claude/skills/cultureflare-write/scripts/cf-pages-project-create.sh`

- [ ] **Step 1: Write the failing tests**

Append these `@test` blocks to the end of `tests/bats/cf-pages-project-create.bats`:

```bash
# --- --env-var ---

@test "cf-pages-project-create.sh --env-var injects env_vars into both preview and production" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" katvan agentculture katvan \
    --env-var=JEKYLL_ENV=production --env-var=RUBY_VERSION=3.3 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.would_post.deployment_configs.production.env_vars.JEKYLL_ENV.type == "plain_text"'
  echo "$output" | jq -e '.result.would_post.deployment_configs.production.env_vars.JEKYLL_ENV.value == "production"'
  echo "$output" | jq -e '.result.would_post.deployment_configs.production.env_vars.RUBY_VERSION.value == "3.3"'
  echo "$output" | jq -e '.result.would_post.deployment_configs.preview.env_vars.JEKYLL_ENV.value == "production"'
}

@test "cf-pages-project-create.sh without --env-var omits env_vars entirely" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" katvan agentculture katvan --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.would_post.deployment_configs.production | has("env_vars") | not'
  echo "$output" | jq -e '.result.would_post.deployment_configs.preview | has("env_vars") | not'
}

@test "cf-pages-project-create.sh --env-var value containing = is preserved" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" katvan agentculture katvan \
    --env-var=FOO=a=b --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.would_post.deployment_configs.production.env_vars.FOO.value == "a=b"'
}

@test "cf-pages-project-create.sh --env-var without inner = is a usage error" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" katvan agentculture katvan \
    --env-var=JEKYLL_ENV
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be KEY=VALUE"* ]]
}

@test "cf-pages-project-create.sh --env-var with invalid key is a usage error" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" katvan agentculture katvan \
    --env-var=1BAD=x
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid --env-var key"* ]]
}

@test "cf-pages-project-create.sh --env-var --apply sends env_vars in the POST body" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  cf_mock "/pages/projects"          "pages_project_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" katvan agentculture katvan \
    --env-var=JEKYLL_ENV=production --apply
  [ "$status" -eq 0 ]
  grep -qF '"env_vars"' "$BATS_TEST_TMPDIR/curl.log"
  grep -qF '"JEKYLL_ENV"' "$BATS_TEST_TMPDIR/curl.log"
}
```

- [ ] **Step 2: Run the new tests to verify they fail**

Run: `bats tests/bats/cf-pages-project-create.bats`
Expected: the six new `--env-var` tests FAIL (the flag is currently rejected as an unknown flag → exit 2 with "unknown flag", or the JSON assertions fail because `env_vars` is absent); the pre-existing tests still PASS.

- [ ] **Step 3: Edit the script — declare the `env_vars` array**

In `.claude/skills/cultureflare-write/scripts/cf-pages-project-create.sh`, find:

```bash
compatibility_date=""
build_image_version=""
# Track whether each overridable flag was explicitly passed: "" is a
```

Replace with:

```bash
compatibility_date=""
build_image_version=""
env_vars=()
# Track whether each overridable flag was explicitly passed: "" is a
```

- [ ] **Step 4: Edit the script — add the `--env-var=*` arg-loop case**

Find:

```bash
    --build-image-version=*)  build_image_version="${arg#*=}"; build_image_version_set=1 ;;
    -h|--help)
```

Replace with:

```bash
    --build-image-version=*)  build_image_version="${arg#*=}"; build_image_version_set=1 ;;
    --env-var=*)
      ev="${arg#*=}"
      if [[ "$ev" != *=* ]]; then
        echo "ERROR: --env-var must be KEY=VALUE, got: $ev" >&2
        exit 2
      fi
      if [[ ! "${ev%%=*}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: invalid --env-var key: ${ev%%=*}" >&2
        exit 2
      fi
      env_vars+=("$ev")
      ;;
    -h|--help)
```

- [ ] **Step 5: Edit the script — document the flag in the header comment**

Find:

```bash
#   --build-image-version=N     1, 2, or 3 (default: 3 = latest)
#   --apply                     actually POST (without it, dry-run)
```

Replace with:

```bash
#   --build-image-version=N     1, 2, or 3 (default: 3 = latest)
#   --env-var=KEY=VALUE         set a deployment environment variable on
#                               both preview and production. Repeatable.
#                               KEY must match [A-Za-z_][A-Za-z0-9_]*.
#   --apply                     actually POST (without it, dry-run)
```

- [ ] **Step 6: Edit the script — build the `env_vars_json` object**

Find:

```bash
if (( build_image_version_set ));  then effective_build_image="$build_image_version";
else effective_build_image="${cloned_build_image:-3}"; fi

# Build the POST body. Unset fields are emitted as empty-string /
```

Replace with:

```bash
if (( build_image_version_set ));  then effective_build_image="$build_image_version";
else effective_build_image="${cloned_build_image:-3}"; fi

# Build the env_vars object for deployment_configs from any --env-var
# flags. Empty when none were passed, in which case the body omits
# env_vars entirely (same treatment as an unset compatibility_date).
env_vars_json='{}'
if (( ${#env_vars[@]} > 0 )); then
  for ev in "${env_vars[@]}"; do
    # shellcheck disable=SC2016  # single-quoted jq filter
    env_vars_json=$(jq -n --argjson acc "$env_vars_json" \
      --arg k "${ev%%=*}" --arg v "${ev#*=}" \
      '$acc + {($k): {type: "plain_text", value: $v}}')
  done
fi

# Build the POST body. Unset fields are emitted as empty-string /
```

- [ ] **Step 7: Edit the script — pass `env_vars` into the body `jq` invocation**

Find:

```bash
  --argjson build_image "$effective_build_image" \
  --argjson direct_upload "$direct_upload" \
```

Replace with:

```bash
  --argjson build_image "$effective_build_image" \
  --argjson direct_upload "$direct_upload" \
  --argjson env_vars "$env_vars_json" \
```

- [ ] **Step 8: Edit the script — merge `env_vars` into both deployment configs**

Find:

```bash
    deployment_configs: {
      preview: ({
        fail_open: true,
        always_use_latest_compatibility_date: false,
        build_image_major_version: $build_image,
        usage_model: "standard"
      } + (if $compat_date == "" then {} else {compatibility_date: $compat_date} end)),
      production: ({
        fail_open: true,
        always_use_latest_compatibility_date: false,
        build_image_major_version: $build_image,
        usage_model: "standard"
      } + (if $compat_date == "" then {} else {compatibility_date: $compat_date} end))
    }
```

Replace with:

```bash
    deployment_configs: {
      preview: ({
        fail_open: true,
        always_use_latest_compatibility_date: false,
        build_image_major_version: $build_image,
        usage_model: "standard"
      }
      + (if $compat_date == "" then {} else {compatibility_date: $compat_date} end)
      + (if ($env_vars | length) == 0 then {} else {env_vars: $env_vars} end)),
      production: ({
        fail_open: true,
        always_use_latest_compatibility_date: false,
        build_image_major_version: $build_image,
        usage_model: "standard"
      }
      + (if $compat_date == "" then {} else {compatibility_date: $compat_date} end)
      + (if ($env_vars | length) == 0 then {} else {env_vars: $env_vars} end))
    }
```

- [ ] **Step 9: Edit the script — show `env_vars` in the dry-run markdown summary**

Find:

```bash
  printf -- '- **build_image_major_version:** %s\n' "$effective_build_image"
  if [[ -n "$clone_from" ]]; then
    printf -- '- **cloned_from:** %s\n' "$clone_from"
  fi
```

Replace with:

```bash
  printf -- '- **build_image_major_version:** %s\n' "$effective_build_image"
  if (( ${#env_vars[@]} > 0 )); then
    printf -- '- **env_vars:** %s\n' "${env_vars[*]}"
  fi
  if [[ -n "$clone_from" ]]; then
    printf -- '- **cloned_from:** %s\n' "$clone_from"
  fi
```

- [ ] **Step 10: Run the full bats file to verify it passes**

Run: `bats tests/bats/cf-pages-project-create.bats`
Expected: all tests PASS — the six new `--env-var` tests and all pre-existing tests.

- [ ] **Step 11: Shellcheck the modified script**

Run: `shellcheck -e SC1091 .claude/skills/cultureflare-write/scripts/cf-pages-project-create.sh`
Expected: no output, exit 0. (Same SC2016 contingency as Task 2 Step 5 if needed.)

- [ ] **Step 12: Commit**

```bash
git add .claude/skills/cultureflare-write/scripts/cf-pages-project-create.sh tests/bats/cf-pages-project-create.bats
git commit -m "feat(skills): cf-pages-project-create.sh --env-var=KEY=VALUE (#34)

Repeatable flag injecting env_vars into both preview and production
deployment configs. Needed for JEKYLL_ENV / RUBY_VERSION on the
katvan-backed Pages project.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Document the new tooling in `SKILL.md`

Add the two new scripts to `.claude/skills/cultureflare-write/SKILL.md` — the scripts table, a full reference section for each, the `--env-var` flag under the existing `cf-pages-project-create.sh` section, and the token-scope list. Also fix the now-stale "once that lands" sentence.

**Files:**
- Modify: `.claude/skills/cultureflare-write/SKILL.md`

- [ ] **Step 1: Add the two scripts to the token-scope list (§1 Pre-flight)**

Find:

```text
- **Account · Cloudflare Pages · Edit** (this account) —
  required by `cf-pages-project-create.sh`,
  `cf-pages-deployment-delete.sh`, and
  `cf-pages-deployments-purge.sh`. Creating a **GitHub-connected**
```

Replace with:

```text
- **Account · Cloudflare Pages · Edit** (this account) —
  required by `cf-pages-project-create.sh`,
  `cf-pages-domain-add.sh`, `cf-pages-domain-remove.sh`,
  `cf-pages-deployment-delete.sh`, and
  `cf-pages-deployments-purge.sh`. Creating a **GitHub-connected**
```

- [ ] **Step 2: Add two rows to the §3 scripts table**

Find:

```text
| Create a Pages project | `bash .claude/skills/cultureflare-write/scripts/cf-pages-project-create.sh ...` *(Python port pending)* |
```

Replace with:

```text
| Create a Pages project | `bash .claude/skills/cultureflare-write/scripts/cf-pages-project-create.sh ...` *(Python port pending)* |
| Add a custom domain to a Pages project | `bash .claude/skills/cultureflare-write/scripts/cf-pages-domain-add.sh ...` |
| Remove a custom domain from a Pages project | `bash .claude/skills/cultureflare-write/scripts/cf-pages-domain-remove.sh ...` |
```

- [ ] **Step 3: Document `--env-var` in the `cf-pages-project-create.sh` section**

Find:

```text
- `--build-image-version=N` — `1`, `2`, or `3` (default `3` = latest).
- `--apply` — actually POST. Without it, dry-run.
```

Replace with:

```text
- `--build-image-version=N` — `1`, `2`, or `3` (default `3` = latest).
- `--env-var=KEY=VALUE` — set a deployment environment variable on
  **both** the preview and production deployment configs. Repeatable
  — pass it once per variable. `KEY` must match
  `[A-Za-z_][A-Za-z0-9_]*`; a value missing the inner `=` is a usage
  error. Used by the katvan cutover for `JEKYLL_ENV=production` and
  `RUBY_VERSION=3.3`. `--clone-from` does **not** copy env vars —
  they are always explicit.
- `--apply` — actually POST. Without it, dry-run.
```

- [ ] **Step 4: Fix the stale "once that lands" sentence**

Find:

```text
Custom domains (including apex mappings like `culture.dev`) are not
created by this script; attach them in the Pages dashboard or via a
follow-on `cf-pages-domain-add.sh` once that lands.
```

Replace with:

```text
Custom domains (including apex mappings like `culture.dev`) are not
attached by this script; use `cf-pages-domain-add.sh` /
`cf-pages-domain-remove.sh` (below) for that.
```

- [ ] **Step 5: Add the full reference section for `cf-pages-domain-add.sh`**

Find the start of the deployment-delete section:

```text
### 3.3 cf-pages-deployment-delete.sh
```

Insert the following **immediately before** that line:

````text
### cf-pages-domain-add.sh

Binds a custom domain to a Cloudflare Pages project — `POST
/accounts/:id/pages/projects/:project/domains` with body
`{"name": DOMAIN}`. Pre-flight lists the project's existing custom
domains, which also confirms the project exists (a missing project
surfaces CloudFlare's structured error) and enforces idempotency
(refuses if `DOMAIN` is already attached).

```sh
# Dry-run — prints the would-POST body, no mutation:
bash .claude/skills/cultureflare-write/scripts/cf-pages-domain-add.sh \
  katvan culture.dev

# Apply for real:
bash .claude/skills/cultureflare-write/scripts/cf-pages-domain-add.sh \
  katvan culture.dev --apply
```

Positional args:

- `PROJECT` — Pages project name (resolved via its `/domains` list).
- `DOMAIN` — the custom domain / hostname to attach.

Flags:

- `--apply` — actually POST. Without it, dry-run.
- `--json` — raw CloudFlare response envelope (or simulated body in
  dry-run).

Exit codes: `0` success (dry-run or apply); `1` account id missing /
project not found / domain already attached / API error; `2` usage
error.

### cf-pages-domain-remove.sh

Detaches a custom domain from a Cloudflare Pages project — `DELETE
/accounts/:id/pages/projects/:project/domains/:domain`. Pre-flight
lists the project's custom domains; refuses with exit 1 if `DOMAIN`
is **not** attached (a silent no-op would hide a typo). This is the
step that can take a production domain dark, so the dry-run banner
names the project and domain explicitly.

```sh
# Dry-run — prints the would-DELETE URL, no mutation:
bash .claude/skills/cultureflare-write/scripts/cf-pages-domain-remove.sh \
  culture-dev culture.dev

# Apply for real:
bash .claude/skills/cultureflare-write/scripts/cf-pages-domain-remove.sh \
  culture-dev culture.dev --apply
```

Positional args:

- `PROJECT` — Pages project name (resolved via its `/domains` list).
- `DOMAIN` — the custom domain / hostname to detach.

Flags:

- `--apply` — actually DELETE. Without it, dry-run.
- `--json` — raw CloudFlare response envelope (or simulated body in
  dry-run).

Exit codes: `0` success (dry-run or apply); `1` account id missing /
project not found / domain not attached / API error; `2` usage
error.

**Moving a custom domain between projects** (the `culture.dev` →
katvan cutover): CloudFlare lets a hostname be a custom domain on
only one Pages project at a time, so the move is
`cf-pages-domain-remove.sh OLD DOMAIN --apply` then
`cf-pages-domain-add.sh NEW DOMAIN --apply`, run back-to-back. See
`docs/superpowers/specs/2026-05-15-culture-dev-katvan-cutover-design.md`.

````

- [ ] **Step 6: Run markdownlint**

Run: `bash tests/markdownlint.sh`
Expected: no errors, exit 0. If a violation is reported, fix it inline (the workspace config disables MD013 line-length and MD060, so the likely candidates are list/heading spacing).

- [ ] **Step 7: Commit**

```bash
git add .claude/skills/cultureflare-write/SKILL.md
git commit -m "docs(skills): document cf-pages-domain-{add,remove} + --env-var in cultureflare-write SKILL.md (#34)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Version bump + full verification

Run the complete local CI equivalent, then bump the version (the `version-check` CI job blocks PRs that don't). `pyproject.toml` is currently `0.7.0`; this PR adds new scripts and a new flag → **minor** bump → `0.8.0`.

**Files:**
- Modify: `pyproject.toml`, `CHANGELOG.md` (via the `version-bump` skill)

- [ ] **Step 1: Run shellcheck across the whole repo**

Run: `bash tests/shellcheck.sh`
Expected: lists every shell script, then no shellcheck findings, exit 0.

- [ ] **Step 2: Run markdownlint across the whole repo**

Run: `bash tests/markdownlint.sh`
Expected: no errors, exit 0.

- [ ] **Step 3: Run the full bats suite**

Run: `bats tests/bats/`
Expected: every `.bats` file passes — including the two new files and the extended `cf-pages-project-create.bats`.

- [ ] **Step 4: Run the Python test suite**

Run: `uv run pytest -q`
Expected: all tests pass. (This PR touches only bash + docs, so the Python suite should be unaffected — running it confirms nothing regressed and matches what CI runs.)

- [ ] **Step 5: Bump the version**

Run:

```bash
echo '{"added":["skills/cultureflare-write: cf-pages-domain-add.sh and cf-pages-domain-remove.sh — bind / detach a custom domain on a Pages project (dry-run by default, --apply to commit)","skills/cultureflare-write: cf-pages-project-create.sh gains --env-var=KEY=VALUE (repeatable) to set deployment env vars on both preview and production"],"changed":["docs/superpowers/specs: 2026-05-15-culture-dev-katvan-cutover-design.md — design for repointing culture.dev Cloudflare Pages to agentculture/katvan (#34)"]}' \
  | python3 .claude/skills/version-bump/scripts/bump.py minor
```

Expected: prints the new version `0.8.0`; updates `pyproject.toml` and prepends a `## [0.8.0]` entry to `CHANGELOG.md`.

- [ ] **Step 6: Verify the bump**

Run: `grep '^version' pyproject.toml && head -20 CHANGELOG.md`
Expected: `version = "0.8.0"`; the new `## [0.8.0] - 2026-05-15` changelog entry at the top with the Added / Changed sections above the old `## [0.7.0]` entry.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: bump version to 0.8.0 (#34)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

> `git add -A` here picks up whatever `bump.py` touched (`pyproject.toml`, `CHANGELOG.md`, and any package `__version__` it keeps in sync). Confirm with `git status` that only those files are staged.

- [ ] **Step 8: Final review before PR**

Run: `git log --oneline origin/main..HEAD`
Expected: six commits — the design doc (already present from brainstorming), fixtures, `cf-pages-domain-add.sh`, `cf-pages-domain-remove.sh`, the `--env-var` change, the SKILL.md docs, and the version bump.

Optionally dispatch the `doctest-align` agent to confirm every new `cf-*.sh` has a matching bats file referencing a fixture, every fixture exists, and both scripts appear in `SKILL.md`'s scripts table.

The PR itself is created and shepherded through review via the `cicd` skill (`workflow.sh open`), then the `poll` skill — outside this plan. **Part B (the live cutover runbook) begins only after this PR merges.**

---

## Self-review notes

- **Spec coverage.** Part A's three deliverables each map to a task (2, 3, 4); fixtures → Task 1; SKILL.md + the stale-sentence fix → Task 5; version bump + the bats/shellcheck/markdownlint/doctest-align housekeeping → Task 6. The "no token-scope change" claim from the spec holds — Task 5 Step 1 only *adds the new scripts to the existing `Account · Cloudflare Pages · Edit` bullet*, it does not add a scope. Part B is explicitly out of scope and called out in the header and Task 6 Step 8.
- **Type/name consistency.** Fixture filenames are identical between Task 1 (creation) and Tasks 2–3 (`cf_mock` references). Script paths use `.claude/skills/cultureflare-write/scripts/` throughout; bats files resolve them via `WRITE_SCRIPTS="$SKILL_DIR/../cfafi-write/scripts"` (the legacy `cfafi-write` symlink — matching every existing write-skill bats file). The `--env-var=KEY=VALUE` flag spelling is identical in the script, the tests, the SKILL.md, and the spec.
- **No placeholders.** Every script and bats file is shown in full; every SKILL.md edit gives exact find/replace text. The one bounded contingency — "if shellcheck flags SC2016, add the disable comment" — names the exact comment string and mirrors the disable comments already in the shown code.
