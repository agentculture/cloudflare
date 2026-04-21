# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

CloudFlare management for the **AgentCulture OSS** organization, built as Claude Code **skills and subagents** ("ClaudeFlare"). Part of the Culture workspace (see `culture` CLI / <https://culture.dev>). Maintained jointly by agents and one human (Ori Nachum).

Parent workspace context lives in `../CLAUDE.md`. The global workspace uses uv for Python, but this repo is bash-based (see "Tooling choice" below).

## Current state

Phase 1 (read-only skills) is in progress. The repo contains one skill, `cloudflare`, with a verify script (`cf-whoami.sh`) and a bats test harness. Remaining Phase 1 scripts (`cf-zones`, `cf-dns`, `cf-workers`, `cf-pages`) and the CI workflow land in subsequent checkpoints. See `/home/spark/.claude/plans/ethereal-munching-porcupine.md` for the full plan (lives in the owning agent's workspace, not in this repo).

Layout:

```text
.claude/skills/cloudflare/        # one skill; read-only ops today, write ops will land here
  SKILL.md                        # (pending — Checkpoint C)
  scripts/
    _lib.sh                       # shared helpers: cf_api, cf_output, cf_output_kv, cf_require_account_id
    cf-whoami.sh                  # verify token status and expiry
.claude/skills/pr-review/         # vendored from ~/.claude/skills (PR #4)
tests/
  bats/                           # bats-core unit tests; PATH-injected curl stub for offline mocking
  fixtures/                       # canned API responses
```

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

1. **Phase 1 — read-only skills** for the `culture.dev` zone. Verify auth end-to-end by listing zones first (cheapest call). Then DNS records, Workers scripts/routes, Pages projects/deployments.
2. **Phase 2 — `agentirc.dev` Pages cleanup.** `agentirc.dev` is deprecated and folded into `culture.dev/agentirc` with a redirect. The orphaned Pages deployment needs a documented removal plan, then execution.
3. **Later:** write ops, multi-domain support, mesh integration, expansion to R2 / Access / Zero Trust and potentially mixed CloudFlare–AWS workflows.

## Active design context

Live design decisions (scope, auth shape, skill layout, phase-1 targets) are tracked in `/home/spark/.claude/projects/-home-spark-git-cloudflare/memory/` — read `MEMORY.md` there at the start of a session if you need the current state of the conversation's working agreements.
