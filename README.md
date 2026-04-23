# cfafi

**C**loud**F**lare **A**gent **F**irst **I**nterface — CloudFlare management for the [AgentCulture OSS](https://culture.dev) organization, implemented as Claude Code skills and subagents. Part of the Culture workspace.

> Renamed from `cloudflare` → `cfafi`. The skill directories under `.claude/skills/` (`cloudflare/`, `cloudflare-write/`) still use the old names pending a follow-up renovation pass.

## Setup

Short version:

1. Copy the env template: `cp .env.example .env`
2. Provision a CloudFlare API token with the read-only scopes listed in `.env.example`, scoped to the AgentCulture account. Paste the token and your account ID into `.env`.
3. Verify: `bash .claude/skills/cloudflare/scripts/cf-whoami.sh` — should print a **CloudFlare token** section with the token id, `status: active`, `not_before`, and `expires_on`. (The `/user/tokens/verify` endpoint does not return granted scopes, so those are not printed.)
4. Full digest: `bash .claude/skills/cloudflare/scripts/cf-status.sh` — if this succeeds, all scopes are wired correctly.

Long version (dashboard walkthrough, scope-to-script mapping, common errors): see [`docs/SETUP.md`](docs/SETUP.md).

`.env` is gitignored. Do not commit it.

## Skills

- [`cloudflare`](.claude/skills/cloudflare/SKILL.md) — **read-only** visibility into DNS, Workers, and Pages for zones in the AgentCulture account.
- [`cloudflare-write`](.claude/skills/cloudflare-write/SKILL.md) — **create / update / delete** operations (e.g. Single Redirect rules). Dry-run by default; `--apply` is required to mutate. Needs a separate API token with Edit scopes (see [`docs/SETUP.md`](docs/SETUP.md) §1.5).

## Tests

```sh
bash tests/shellcheck.sh     # static analysis across all shell scripts
bash tests/markdownlint.sh   # lint every markdown file against .markdownlint-cli2.yaml
bats tests/bats/             # unit tests (mocked curl, real jq, no live token required)
```

All three run in CI on every PR (see `.github/workflows/test.yml`).

Required tools on the developer machine: `bash`, `curl`, `jq`, `shellcheck`, `bats`, `markdownlint-cli2`.

See `CLAUDE.md` for architecture, constraints, and the phase roadmap.
