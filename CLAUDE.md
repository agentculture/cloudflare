# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

CloudFlare management for the **AgentCulture OSS** organization, built as Claude Code **skills and subagents** ("ClaudeFlare"). Part of the Culture workspace (see `culture` CLI / <https://culture.dev>). Maintained jointly by agents and one human (Ori Nachum).

Parent workspace context lives in `../CLAUDE.md`. The global workspace uses uv for Python, but this repo is bash-based (see "Tooling choice" below).

## Current state

Phase 1 (read-only skills) is complete. See `.claude/skills/cloudflare/SKILL.md` for the user-facing skill documentation (what each script does, when it runs, how to add new read scripts).

Layout:

```text
.claude/skills/cloudflare/        # one skill; read-only ops today, write ops will land here
  SKILL.md                        # user-facing skill instructions + trigger phrases
  scripts/
    _lib.sh                       # shared helpers: env load, cf_api, cf_api_paginated,
                                  # cf_output, cf_output_kv, cf_require_account_id
    cf-whoami.sh                  # verify token status and expiry
    cf-zones.sh                   # list zones the token can see
    cf-dns.sh ZONE                # list DNS records for a zone (resolves name → id)
    cf-workers.sh                 # list Workers scripts in the account
    cf-workers-routes.sh          # aggregate Workers routes across every zone
    cf-pages.sh [PROJECT]         # list Pages projects (or a project's deployments)
.claude/skills/pr-review/         # vendored from ~/.claude/skills — fetch/reply/resolve PR comments
tests/
  bats/                           # bats-core unit tests; PATH-injected curl stub for offline mocking
  fixtures/                       # canned API responses
  shellcheck.sh                   # shellcheck every shell script in the repo
  markdownlint.sh                 # markdownlint-cli2 every .md file in the repo
.github/workflows/test.yml        # CI: shellcheck + markdownlint + bats on every PR
```

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

1. **Phase 1 — read-only skills** ✓ Done. All six scripts (`cf-whoami`, `cf-zones`, `cf-dns`, `cf-workers`, `cf-workers-routes`, `cf-pages`) plus pagination, CI, and docs.
2. **Phase 2 — `agentirc.dev` Pages cleanup.** `agentirc.dev` is deprecated and folded into `culture.dev/agentirc` with a redirect. Phase 1's `cf-pages.sh` and `cf-workers-routes.sh` are the inventory tools for the removal plan; Phase 2 introduces the first write operations (delete endpoints).
3. **Later:** multi-domain support, mesh integration, expansion to R2 / Access / Zero Trust, and potentially mixed CloudFlare–AWS workflows.

## Conventions for adding code

- **Names, not IDs.** Scripts accept domain / project / script names and resolve to IDs internally (e.g. `cf-dns.sh culture.dev`, not a zone id). One extra API call is the price of ergonomics.
- **URL-encode any user-supplied argument** before interpolating into a URL (`jq -rn --arg v "$input" '$v|@uri'`).
- **Every list script uses `cf_api_paginated`.** Single-object endpoints (e.g. `/user/tokens/verify`) use `cf_api` directly.
- **Agent-readable default, `--json` opt-in.** Markdown tables for lists, markdown key-value for single objects, raw JSON only when explicitly requested.
- **Every new script ships with a bats file under `tests/bats/` and at least one fixture under `tests/fixtures/`.** CI runs them all on every PR.

## Active design context

Live design decisions (scope, auth shape, skill layout, phase-1 targets) are tracked in `/home/spark/.claude/projects/-home-spark-git-cloudflare/memory/` — read `MEMORY.md` there at the start of a session if you need the current state of the conversation's working agreements.
