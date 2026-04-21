# cloudflare

CloudFlare management for the [AgentCulture OSS](https://culture.dev) organization, implemented as Claude Code skills and subagents ("ClaudeFlare"). Part of the Culture workspace.

## Setup

1. Copy the env template: `cp .env.example .env`
2. Provision a CloudFlare API token with the read-only scopes listed in `.env.example`, scoped to the AgentCulture account. Paste the token and your account ID into `.env`.
3. Verify: `bash .claude/skills/cloudflare/scripts/cf-whoami.sh` — should print a **CloudFlare token** section with the token id, `status: active`, `not_before`, and `expires_on`. (The `/user/tokens/verify` endpoint does not return granted scopes, so those are not printed.)

`.env` is gitignored. Do not commit it.

## Skills

- [`cloudflare`](.claude/skills/cloudflare/SKILL.md) — read-only visibility into DNS, Workers, and Pages for zones in the AgentCulture account.

## Tests

Pipeline tests will run in CI on every PR once `.github/workflows/test.yml` lands (Checkpoint C). Today, run them locally:

```sh
bash tests/shellcheck.sh   # static analysis across all shell scripts
bats tests/bats/           # unit tests (mocked curl, real jq, no live token required)
```

Required tools on the developer machine: `bash`, `curl`, `jq`, `shellcheck`, `bats`.

See `CLAUDE.md` for architecture, constraints, and the phase roadmap.
