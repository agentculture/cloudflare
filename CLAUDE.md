# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

CloudFlare management for the **AgentCulture OSS** organization, built as Claude Code **skills and subagents** ("ClaudeFlare"). Part of the Culture workspace (see `culture` CLI / <https://culture.dev>). Maintained jointly by agents and one human (Ori Nachum).

Parent workspace context lives in `../CLAUDE.md`. The global workspace uses uv for Python.

## Current state: pre-scaffold

As of now the repo contains only README, LICENSE, `.gitignore` (Python-flavored), and `.claude/settings.local.json`. There is no build system, test suite, or source tree yet — do not hallucinate commands. The expected layout, once scaffolded, is:

```text
.claude/skills/cf-dns/        # one skill per CloudFlare resource area
.claude/skills/cf-workers/
.claude/skills/cf-pages/
.claude/skills/cf-account/
.claude/agents/               # subagents
lib/                          # shared Python helpers (auth, HTTP, JSON formatting)
```

Skills start read-only. Write ops are added to the same per-resource skill when that area graduates.

## Hard constraints

- **Do not join the culture mesh from this repo.** Ori will signal when it's time. Until then, skills are invoked locally in Claude Code but must be designed as if a mesh peer will call them later: stable CLI interfaces, deterministic JSON output by default, `--human` flag for pretty-print.
- **Credentials never live in the repo.** The CloudFlare API token lives at `~/.config/cloudflare/token` (mode 600), owned by the dedicated OS user this agent runs as. Env var name is `CLOUDFLARE_API_TOKEN`. A `.env.example` may document the variable name, but `.env` is gitignored and unused for real tokens.
- **Ownership model:** CloudFlare responsibility is earned through work and can be split across multiple agents by domain or resource area. Skills must therefore be parameterized by zone/account — never hardcode `culture.dev` or a specific account ID in skill logic; take it as an arg or from config.

## Tooling choice

REST API via a thin Python wrapper (`httpx`, managed with `uv`). CLI (`wrangler`) and the official SDK are both acceptable for one-off cases, but the default skill implementation uses REST for a uniform surface across DNS/Workers/Pages/account and to avoid stateful `wrangler login` under a dedicated OS user.

## Roadmap

1. **Phase 1 — read-only skills** for the `culture.dev` zone. Verify auth end-to-end by listing zones first (cheapest call). Then DNS records, Workers scripts/routes, Pages projects/deployments.
2. **Phase 2 — agentirc.dev Pages cleanup.** `agentirc.dev` is deprecated and folded into `culture.dev/agentirc` with a redirect. The orphaned Pages deployment needs a documented removal plan, then execution.
3. **Later:** write ops, multi-domain support, mesh integration, expansion to R2 / Access / Zero Trust and potentially mixed CloudFlare–AWS workflows.

## Active design context

Live design decisions (scope, auth shape, skill layout, phase-1 targets) are tracked in `/home/spark/.claude/projects/-home-spark-git-cloudflare/memory/` — read `MEMORY.md` there at the start of a session if you need the current state of the conversation's working agreements.
