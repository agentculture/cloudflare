---
name: cicd
description: >
  PR-review lane for cultureflare, layered on `agex pr`. Delegates
  lint / open / read / reply / delta to the agex CLI; adds two steward
  extensions — `status` (SonarCloud quality gate + hotspots +
  unresolved-thread tally) and `await` (read --wait + status, with
  non-zero exit on Sonar ERROR or unresolved threads). Use when:
  creating PRs in cultureflare, handling review feedback, polling CI
  status, or the user says "create PR", "review comments", "address
  feedback", "resolve threads", "/cicd". Vendored from steward 0.12.0;
  renamed from `pr-review` in steward 0.7.0; rebased on agex in 0.12.0.
---

# CI/CD — cultureflare edition

`agex pr` (in `agentculture/agex-cli`) is the upstream for the five
core PR-lifecycle verbs — `lint`, `open`, `read`, `reply`, `delta`.
This skill is a thin layer over `agex pr` plus two steward extensions
(`status`, `await`) for SonarCloud gating and triage flow.

cultureflare PRs touch CloudFlare automation scripts, Pages templates,
and skills. Two recurring bug classes need to be caught before they
ship in a PR — and `agex pr lint` is built to catch both:

- **Path leaks** — committing absolute home-directory paths that work
  only on the author's machine.
- **Per-user config dependencies** — referencing a dotfile under the
  user's home directory in repo guidance, breaking reproducibility for
  other contributors and CI.

The workflow is encapsulated in `scripts/workflow.sh` — follow that
(or call `agex pr` directly).

## Prerequisites

Hard requirements: `agex` (>=0.1), `gh` (GitHub CLI), `jq`, `bash`,
`python3` (stdlib only), `curl` (used by `pr-status.sh`).

Install agex once:

```bash
uv tool install agex-cli   # or: pip install --user agex-cli
```

Per-machine paths (sibling-project layout) live in
`.claude/skills.local.yaml`; see the committed `.example` for the
schema. `agex pr delta` reads the same file.

## How to run

`scripts/workflow.sh` is the entry point. Subcommands:

| Command | What it does |
|---------|--------------|
| `workflow.sh lint` | `agex pr lint --exit-on-violation` — portability + alignment-trigger check. |
| `workflow.sh open [gh-flags]` | `agex pr open --delayed-read`. Creates the PR, then polls 180s for an initial briefing. `--title TITLE` required; body via `--body-file PATH` or stdin. |
| `workflow.sh read [PR] [--wait N]` | `agex pr read`. One-shot briefing (CI checks, SonarCloud gate + new issues, all comments, next-step footer). Pass `--wait N` to poll up to N seconds for required reviewers. |
| `workflow.sh reply <PR>` | `agex pr reply <PR>` — batch JSONL replies (stdin) + thread resolve. agex auto-signs the nick (see below). |
| `workflow.sh delta` | `agex pr delta` — sibling alignment dump. |
| `workflow.sh status [--repo R] [--sonar-key K] <PR>` | **Steward extension.** Forwards all args to `pr-status.sh` — Sonar gate, OPEN issues, hotspots, unresolved-thread breakdown, deploy preview URL. Authoritative gate for `await`. |
| `workflow.sh await <PR>` | **Steward extension.** `agex pr read --wait` then `status`. Exits non-zero on Sonar ERROR or unresolved threads. Tunables: `CULTUREFLARE_PR_AWAIT_WAIT` (default 1800s, passed to `--wait`), `CULTUREFLARE_PR_AWAIT_SECONDS` (legacy fixed pre-sleep, deprecated). |
| `workflow.sh help` | Print the list. |

You can also call `agex pr <verb>` directly — `workflow.sh` is a
typing-saver around the same verbs. The `status` and `await`
extensions only have shell entry points.

The vendored single-comment helper `pr-reply.sh` (plus its
`_resolve-nick.sh` dependency) is still shipped — useful when a one-off
reply doesn't merit batch JSONL. It is not called by `workflow.sh`
anymore. `portability-lint.sh` is also still shipped — `agex pr lint`
runs the same rules, but the standalone script stays for direct
diff-time checks.

> **Local divergence:** every script in this skill carries repo-local
> hardening on top of the steward originals — shellcheck cleanliness
> (`printf '%s'` over `echo`, `[[ … ]]` over `[ … ]`,
> `shopt -s inherit_errexit`), a timeout/retry/URL-encoding `sonar_curl`
> helper in `pr-status.sh`, integer validation of PR / comment IDs in
> `pr-reply.sh`, and extra portability carve-outs in
> `portability-lint.sh`. `workflow.sh` follows the upstream
> agex-delegation structure but adds two cultureflare specifics: it
> defaults+exports `SONAR_PROJECT_KEY=agentculture_cloudflare` (see the
> SonarCloud note below) and forwards all `status` args to
> `pr-status.sh`. These are intentional improvements kept across
> re-syncs.

## Polling for reviewer readiness

`agex pr read --wait N` polls in-session for up to N seconds. The
Anthropic prompt cache has a 5-minute TTL; sleeping past it burns
context every cache miss. Two ways to drive the wait:

- **Synchronous** — `workflow.sh await <PR>` after `gh pr create` /
  `workflow.sh open`. Fine when readiness is expected within ~5
  minutes. The main session burns context during the wait.
- **Asynchronous** — for longer waits, use the project's `poll/`
  skill, which spawns a background subagent that owns the wait so the
  main session pays the cache cost only once. The subagent's only job
  is to run `agex pr read --wait` and echo its headline back; the
  parent triages with `workflow.sh await <PR>` when the notification
  arrives.

cultureflare keeps `poll/` as a first-class skill for the async path;
this skill ships only the synchronous `workflow.sh await` path.

## End-to-end flow

```text
git checkout -b <type>/<desc>
# ... edit ...
.claude/skills/cicd/scripts/workflow.sh lint
git commit -am "..." && git push -u origin <branch>
.claude/skills/cicd/scripts/workflow.sh open --title "..." --body-file body.md
# title <70 chars; agex signs the body if it isn't already signed
.claude/skills/cicd/scripts/workflow.sh await <PR>   # readiness loop, then CI + SonarCloud + threads
# triage; if CLAUDE.md/culture.yaml/.claude/skills changed:
.claude/skills/cicd/scripts/workflow.sh delta
# fix, re-lint, push
.claude/skills/cicd/scripts/workflow.sh reply <PR> < replies.jsonl
gh pr checks <PR>
# Wait for human merge — never merge yourself.
```

Branch naming: `fix/<desc>`, `feat/<desc>`, `docs/<desc>`,
`skill/<name>`. PR / comment signature: `- <nick> (Claude)`, where
`<nick>` is resolved by `agex` from the agent's own `culture.yaml`
(first agent's `suffix`), falling back to the git-repo basename —
currently `cultureflare`, since this repo has no `culture.yaml` yet.
agex auto-appends the signature on `open` and `reply` only when the
body isn't already signed. Hand-rolled `gh pr create` / `gh issue
comment` calls should follow the same convention.

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
PUSHBACK on each comment. `agex pr delta` dumps each sibling project's
`CLAUDE.md` head + `culture.yaml`, using `sibling_projects` from
`.claude/skills.local.yaml`. Note any sibling that needs a follow-up
PR and mention it in your reply.

## Greenfield-aware steps

The lint and the workflow script are always-on. Stack-specific steps
are conditional:

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

Every comment must get a reply — no silent fixes. `agex pr reply`
includes thread-resolve by default. Reference the review-comment IDs
in the fix-up commit message.

SonarCloud is queried by the `status` extension (`pr-status.sh` —
quality gate, OPEN issues, hotspots) and by `agex pr read`. The
default project-key derivation is `<owner>_<repo>` — but
cultureflare's **registered SonarCloud project is
`agentculture_cloudflare`** (it predates the cultureflare rename), not
the derived `agentculture_cultureflare`. `workflow.sh` defaults and
exports `SONAR_PROJECT_KEY=agentculture_cloudflare`, so `workflow.sh
status` / `workflow.sh await` already target the right project. Only
when calling `pr-status.sh` **directly** (not through `workflow.sh`)
do you need to export `SONAR_PROJECT_KEY=agentculture_cloudflare` or
pass `--sonar-key` yourself.

The post-merge IRC ping is gated on cultureflare joining the Culture
mesh — see CLAUDE.md → Hard constraints; until that lands, the
post-merge mesh ping is skipped.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/workflow.sh` | Entry point. Delegates `lint / open / read / reply / delta` to `agex pr`; runs the `status` / `await` steward extensions directly. |
| `scripts/pr-status.sh` | **Steward extension.** One-shot status: PR header + CI checks + review-bot pipeline + SonarCloud quality gate + inline-thread tally. cultureflare-hardened (`sonar_curl` timeout/retry/URL-encoding). |
| `scripts/pr-reply.sh` | Reply to a single review comment, optionally resolve its thread. Auto-signs `- <nick> (Claude)` via `_resolve-nick.sh`. Not called by `workflow.sh` — direct use only. |
| `scripts/portability-lint.sh` | Catch path leaks and per-user dotfile refs in the current diff. Exits 1 on any hit. `agex pr lint` runs the same rules; this stays for direct diff-time checks. |
| `scripts/_resolve-nick.sh` | Resolve the agent's nick: first `suffix` in `culture.yaml`, or git-repo basename. Dependency of `pr-reply.sh`. |
