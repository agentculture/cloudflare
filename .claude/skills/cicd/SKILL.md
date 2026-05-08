---
name: cicd
description: >
  PR-review lane for cultureflare: open PR (auto-wait for Qodo/Copilot),
  push fixes (re-poll bots), triage feedback, reply, resolve. Adds a
  portability lint (no absolute /home paths, no per-user dotfile refs in
  committed docs), an alignment-delta check when CLAUDE.md, culture.yaml,
  or .claude/skills/ change, plus a synchronous reviewer-readiness loop.
  Use when: creating PRs in cultureflare, handling review feedback,
  polling CI status, or the user says "create PR", "review comments",
  "address feedback", "resolve threads", "/cicd". Vendored from steward
  0.7.0; renamed from `pr-review` to match the AgentCulture standard.
---

# CI/CD — cultureflare edition

cultureflare PRs touch CloudFlare automation scripts, Pages templates,
and skills. Two recurring bug classes need to be caught before they
ship in a PR:

- **Path leaks** — committing absolute home-directory paths that work
  only on the author's machine.
- **Per-user config dependencies** — referencing a dotfile under the
  user's home directory in repo guidance, breaking reproducibility for
  other contributors and CI.

This skill specializes the AgentCulture `pr-review` flow to catch both
up front, plus an alignment-delta step when sibling-affecting files
change. The workflow is encapsulated in `scripts/workflow.sh` — follow
that, not a manual checklist.

## Prerequisites

Hard requirements: `gh` (GitHub CLI), `jq`, `bash`, `python3` (stdlib only),
`curl` (used by `pr-status.sh`).

Per-machine paths (sibling-project layout) live in
`.claude/skills.local.yaml`; see the committed `.example` for the schema.

## How to run

`scripts/workflow.sh` is the entry point. Subcommands:

| Command | Purpose |
|---------|---------|
| `workflow.sh lint` | Portability lint on the current diff (staged + unstaged). |
| `workflow.sh open-pr --title T [--body-file F] [--wait SECS] [...]` | `gh pr create` then sleep 180s (or `--wait SECS`) and fetch reviewer comments in one shot. Use after pushing the initial branch. |
| `workflow.sh poll <PR>` | Fetch and display all review comments. |
| `workflow.sh poll-readiness <PR> [--max-iters N] [--interval SECS] [--require LIST]` | Loop until all required reviewers are ready (default `qodo`; pass `--require qodo,copilot` to also gate on Copilot) — or the PR closes / iteration cap hits. Headline on stdout, per-iteration diagnostics on stderr. Direct wrapper around `scripts/poll-readiness.sh`. |
| `workflow.sh wait-after-push <PR> [--wait SECS]` | Sleep 180s (or `--wait SECS`) then re-fetch comments. Use after pushing fixes. |
| `workflow.sh await <PR>` | Poll for reviewer readiness (default: 30 × 60s ≈ 30 min cap, requires qodo only; tune with `CULTUREFLARE_PR_AWAIT_ITERS`, `CULTUREFLARE_PR_AWAIT_INTERVAL`, and `CULTUREFLARE_PR_REVIEWERS`), then run `pr-status.sh` (CI checks + SonarCloud quality gate, OPEN issues, hotspots) and `pr-comments.sh` (inline / issue / top-level / SonarCloud-new-issues sections). Exits non-zero on SonarCloud `ERROR` or unresolved threads. |
| `workflow.sh delta` | Dump each sibling project's `CLAUDE.md` head + `culture.yaml`. |
| `workflow.sh reply <PR>` | Batch reply (JSONL on stdin) and resolve threads. |
| `workflow.sh help` | Print this list. |

The vendored single-comment helpers — `pr-reply.sh`, `pr-status.sh` — live
next to `workflow.sh` and are usable directly when batching isn't appropriate.

## Polling for reviewer readiness

`scripts/poll-readiness.sh` watches a PR until its required reviewers post
real (not placeholder) feedback, the PR closes, or an iteration cap fires.
It fetches `gh api` JSON directly — never `pr-comments.sh` output — so
truncation can't bias the gate. Default required set is qodo only
(see header comments and `--help` for tunables, env vars, and the `qodo` /
`copilot` heuristics; Copilot is detected but not required because its
review bot is silent on agentculture repos in 2026). Heartbeats stream to
stderr; the final headline is the only thing on stdout.

Two ways to drive it:

- **Synchronous** — `workflow.sh await <PR>` after `gh pr create`. The
  main session burns context during the wait; fine up to ~5 minutes.
- **Asynchronous** — for longer waits, use the project's `poll/` skill,
  which spawns a background subagent that owns the wait so the main
  session pays the cache cost only once. The subagent's only job is
  to poll and notify when reviewers finish; the parent triages with
  `workflow.sh await <PR>` (or just `pr-status.sh` + `pr-comments.sh`)
  when the notification arrives.

cultureflare keeps `poll/` as a first-class skill for the async path;
this skill ships only the synchronous looper for `workflow.sh await`.
Use `poll/` when you want the main session to free its context window;
use `workflow.sh await` for short, in-line waits.

## End-to-end flow

```text
git checkout -b <type>/<desc>
# ... edit ...
.claude/skills/cicd/scripts/workflow.sh lint
git commit -am "..." && git push -u origin <branch>
gh pr create --title "..." --body "..."   # title <70 chars, body signed "- cultureflare (Claude)"
.claude/skills/cicd/scripts/workflow.sh await <PR>   # readiness loop, then CI + SonarCloud + all comments
# triage; if CLAUDE.md/culture.yaml/.claude/skills changed:
.claude/skills/cicd/scripts/workflow.sh delta
# fix, re-lint, push
.claude/skills/cicd/scripts/workflow.sh reply <PR> < replies.jsonl
gh pr checks <PR>
# Wait for human merge — never merge yourself.
```

Branch naming: `fix/<desc>`, `feat/<desc>`, `docs/<desc>`, `skill/<name>`.
PR / comment signature: `- <nick> (Claude)`, where `<nick>` comes from
the agent's own `culture.yaml` — first agent's `suffix` — falling back
to the git-repo basename when no `culture.yaml` is present (currently
the case for cultureflare; the basename `cultureflare` is the right
literal). The reply script resolves this via `scripts/_resolve-nick.sh`
and auto-appends the signature only when the body isn't already signed,
so JSONL reply entries can include or omit it. Hand-rolled `gh pr
create` and `gh issue comment` calls should follow the same convention.

## Triage rules

For every comment, decide **FIX** or **PUSHBACK** with reasoning.

Default to **FIX** for: portability complaints (always valid here —
recurring bug class), test or doc requests, style nits aligned with
workspace conventions.

Default to **PUSHBACK** for: architecture opinions that conflict with
workspace `CLAUDE.md`; false-positives that misread the
dry-run-by-default / `--apply`-to-commit pattern; "add tests" demands
on greenfield areas where the convention is documented (defer to a
later PR, don't refuse).

### Alignment-delta rule

If the PR touches `CLAUDE.md`, `culture.yaml`, or anything under
`.claude/skills/`, run `workflow.sh delta` **before** declaring FIX or
PUSHBACK on each comment. The script dumps the head of every sibling
project's `CLAUDE.md` plus the full `culture.yaml`, using
`sibling_projects` from `skills.local.yaml`. Note any sibling that
needs a follow-up PR and mention it in your reply.

## Greenfield-aware steps

The lint and the workflow script are always-on. Stack-specific steps
remain conditional:

```bash
[ -d tests ] && [ -f tests/shellcheck.sh ] && bash tests/shellcheck.sh
[ -d tests/bats ] && bash tests/bats/_lib.bats     # one example; CI runs them all
[ -f .markdownlint-cli2.yaml ] && markdownlint-cli2 "$(git diff --name-only --cached '*.md')"
[ -f pyproject.toml ] && python3 .claude/skills/version-bump/scripts/bump.py patch < changes.json
```

cultureflare's CI already runs the full bats / shellcheck / markdownlint
suite on every PR; the local invocations above are for fast feedback
before pushing.

## Reply etiquette

Every comment must get a reply — no silent fixes. Always pass `--resolve`
when batch-replying so threads close automatically. Reference the
review-comment IDs in the fix-up commit message.

SonarCloud is queried in two places: `pr-status.sh` (quality gate, OPEN
issues, hotspots) and the Section-4 dump in `pr-comments.sh` (new-issue
list). Both derive the project key as `<owner>_<repo>`; for cultureflare
that resolves to `agentculture_cultureflare`. Override with
`SONAR_PROJECT_KEY=<key>` if the repo is moved or republished, and they
silently skip when the project isn't on SonarCloud. The post-merge IRC
ping is gated on cultureflare joining the Culture mesh — see CLAUDE.md
→ Hard constraints; until that lands, the post-merge mesh ping is
skipped.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/workflow.sh` | Single entry point wrapping every other script (lint / open-pr / poll / poll-readiness / wait-after-push / await / reply / delta / help). |
| `scripts/portability-lint.sh` | Catch path leaks and per-user dotfile refs in the current diff. Exits 1 on any hit. |
| `scripts/pr-comments.sh` | Fetch all PR feedback in one pass: inline review comments, issue comments, top-level reviews, SonarCloud new issues. |
| `scripts/pr-status.sh` | One-shot status: PR header + CI checks + review-bot pipeline + SonarCloud quality gate + inline-thread tally. |
| `scripts/poll-readiness.sh` | Sync looper: wait until required reviewers are ready, the PR closes, or the iteration cap hits. |
| `scripts/pr-reply.sh` | Reply to a single review comment, optionally resolve its thread. Auto-signs `- <nick> (Claude)` via `_resolve-nick.sh`. |
| `scripts/pr-batch.sh` | Batch reply (JSONL on stdin) over `pr-reply.sh`. |
| `scripts/_resolve-nick.sh` | Resolve the agent's nick: first `suffix` in `culture.yaml`, or git-repo basename. |
| `scripts/create-pr-and-wait.sh` | `gh pr create` + sleep + fetch comments, in one call. |
| `scripts/wait-and-check.sh` | Sleep N seconds (default 180) then re-fetch comments. |
