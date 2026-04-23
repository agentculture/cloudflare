# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

**cfafi** — **C**loud**F**lare **A**gent **F**irst **I**nterface. CloudFlare management for the **AgentCulture OSS** organization, built as Claude Code **skills and subagents**. Part of the Culture workspace (see `culture` CLI / <https://culture.dev>). Maintained jointly by agents and one human (Ori Nachum).

Repo lives at <https://github.com/agentculture/cfafi> (renamed from `cloudflare`; the skill directories under `.claude/skills/` are still named `cloudflare/` and `cloudflare-write/` pending the next renovation pass).

Parent workspace context lives in `../CLAUDE.md`. The global workspace uses uv for Python, but this repo is bash-based (see "Tooling choice" below).

## Before you start

**Don't trust this doc for current state — it drifts.** Every session,
orient against live CF and the skills themselves, in this order:

1. **Live state.** `bash .claude/skills/cloudflare/scripts/cf-status.sh`
   — single-shot digest of zones, Workers scripts, Workers routes, and
   Pages projects. Authoritative answer to "what exists right now."
2. **Skill for your task.** Load `cloudflare` (read-only) or
   `cloudflare-write` (mutations). Each skill's `SKILL.md` carries
   its own current script inventory, token-scope requirements, and
   the pointers to `references/` for architecture notes and the
   CF API gotchas we've paid for.
3. **Session memory** (Claude Code session-local, not committed to the
   repo). Claude Code persists per-project memory under
   `~/.claude/projects/<slug>/memory/`, where `<slug>` is a
   filename-safe encoding of this repo's absolute path
   (e.g. `/home/alice/src/cfafi` → `-home-alice-src-cfafi`).
   Read `MEMORY.md` in that directory for conversation-scoped
   agreements (site structure, applied-resource IDs, workflow
   preferences). Only your own sessions have written there — freshly
   cloned machines start empty.

## Layout

Four skills under `.claude/skills/`:

- `cloudflare/` — read-only inventory (zones, DNS, Workers, Pages, status).
- `cloudflare-write/` — mutations; dry-run by default, `--apply` to commit.
  Carries `templates/` and `references/` (including `cf-api-gotchas.md`).
- `pr-review/` — vendored PR comment fetch/reply/resolve.
- `poll/` — background reviewer-wait subagent.

Read each skill's `SKILL.md` for its current script inventory — don't
maintain a duplicate index here. Supporting infrastructure:
`tests/bats/` + `tests/fixtures/` (offline via PATH-injected curl
stub), `tests/shellcheck.sh`, `tests/markdownlint.sh`,
`.github/workflows/test.yml`, `docs/SETUP.md` (token scopes).

**Skills split:** `cloudflare` (read) and `cloudflare-write` (write) are discrete skills with separate discovery triggers so agents can't accidentally mutate state while answering an inventory question. Both share `_lib.sh` via symlink (`cloudflare-write/scripts/_lib.sh` → `../../cloudflare/scripts/_lib.sh`) — fixes to the helpers apply to both. Write scripts default to dry-run and require `--apply` to actually POST/PUT/DELETE.

Pagination is transparent: `cf_api_paginated` in `_lib.sh` walks every page of a list endpoint so scripts see one aggregated `.result`. `shopt -s inherit_errexit` is enabled in `_lib.sh` so `exit 1` inside `cf_api` propagates through the `$(...)` layer `cf_api_paginated` adds — removing this breaks error-path tests silently.

## Hard constraints

- **Do not join the culture mesh from this repo.** Ori will signal when it's time. Until then, skills are invoked locally in Claude Code but must be designed as if a mesh peer will call them later: stable CLI interfaces, deterministic output, structured enough for another agent to parse.
- **Credentials never live in the repo.** The CloudFlare API token goes in a `.env` file at the repo root (gitignored). `CLOUDFLARE_API_TOKEN` is the env var name; `CLOUDFLARE_ACCOUNT_ID` is also expected for account-scoped endpoints. `_lib.sh` loads `.env` on import with a safe `KEY=VALUE` parser — no `source`, no shell execution.
- **Ownership model:** CloudFlare responsibility is earned through work and can be split across multiple agents by domain or resource area. Skills must therefore be parameterized by zone/account — never hardcode `culture.dev` or a specific account ID in skill logic; take it as an arg or from env.

## Tooling choice

Bash + `curl` + `jq`, no runtime Python deps. Matches the house style in `culture/` and `citation-cli/`. `wrangler` CLI and the official SDK are acceptable for one-off needs, but skills should default to REST via `curl` for a uniform surface across DNS/Workers/Pages/account and to avoid stateful `wrangler login` under a dedicated agent user.

## Output conventions

- **Default:** markdown — tables for list data (pipe-delimited with `| --- |` separator rows), markdown key-value (`- **key:** value`) for single-object data. This is agent-readable, renders anywhere, and stays grep-able.
- **`--json` flag on every script:** raw API JSON passthrough for bots, scripts, and `jq` pipelines.

## Roadmap

1. **Phase 1 — read-only skills** ✓ Done.
2. **Phase 2 — write skill + create primitives** ✓ Done. Establishes
   the dry-run-by-default / `--apply`-to-commit pattern all future
   `cf-*-create.sh` / `cf-*-update.sh` / `cf-*-delete.sh` follow.
3. **Phase 2.5 — sub-site pattern** ✓ Done for `agex`, `citation-cli`,
   `afi`; `zehut` and `shushu` pending. Pattern is Direct Upload
   Pages project + proxy Worker + Workers route — see
   `cloudflare-write/references/subpath-site-pattern.md`.
4. **Phase 3 — delete primitives + `agentirc.dev` cleanup.** Needs
   `cf-pages-project-delete.sh`, `cf-worker-delete.sh`,
   `cf-workers-route-delete.sh` first, then the audit-then-delete
   run on `agentirc.dev` (still deprecated, still present).
5. **Later:** mesh integration, R2 / Access / Zero Trust, mixed
   CloudFlare–AWS workflows.

Because this drifts: `cf-status.sh` is authoritative for what
exists; this section is authoritative for *what we plan next*.

## Conventions for adding code

- **Names, not IDs.** Scripts accept domain / project / script names and resolve to IDs internally (e.g. `cf-dns.sh culture.dev`, not a zone id). One extra API call is the price of ergonomics.
- **URL-encode any user-supplied argument** before interpolating into a URL (`jq -rn --arg v "$input" '$v|@uri'`).
- **Every list script uses `cf_api_paginated`.** Single-object endpoints (e.g. `/user/tokens/verify`) use `cf_api` directly.
- **Agent-readable default, `--json` opt-in.** Markdown tables for lists, markdown key-value for single objects, raw JSON only when explicitly requested.
- **Every new script ships with a bats file under `tests/bats/` and at least one fixture under `tests/fixtures/`.** CI runs them all on every PR.

## PR workflow

All work goes through a feature branch + PR + automated review cycle (qodo, Copilot, SonarCloud). The vendored `pr-review` skill at `.claude/skills/pr-review/` owns the details — read its `SKILL.md` for the full workflow. Four cheat-sheet points:

- **Before you start: pull latest `main` and fork the branch from there.**

  ```sh
  git fetch origin
  git switch main && git pull --ff-only
  git switch -c feat/<short-descriptive-name>
  ```

  Do this even if you think you're up to date. PRs in this repo squash-merge, which collapses their commits into a single new commit on `main`; any branch forked before that squash still carries the original commits and will hit spurious add/add conflicts on rebase. Starting fresh from the latest `main` avoids the whole class of problem.

- **After `gh pr create`, immediately invoke the `poll` skill.** It spawns a background subagent that watches the PR and notifies you only when both qodo and Copilot have finished. Cheaper than self-paced wakeups because the main session doesn't burn context on heartbeats. See `.claude/skills/poll/SKILL.md`.
- **Fetch ALL review feedback with one call:** `bash .claude/skills/pr-review/scripts/pr-comments.sh <PR>`. It returns inline comments, issue comments, top-level reviews, and SonarCloud new issues in a single pass — don't hand-roll `gh api` / `curl sonarcloud.io` calls.
- **Triage / reply / resolve** via the `pr-review` skill once the poll wakes you.
