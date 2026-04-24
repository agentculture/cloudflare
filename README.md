# cfafi — CloudFlare Agent First Interface

Agent-first CLI for managing CloudFlare state in the AgentCulture OSS org.

## Install

```bash
uv tool install cfafi
cfafi --version
```

## Quick start

```bash
# Export credentials securely (see docs/SETUP.md)
export CLOUDFLARE_API_TOKEN=...
export CLOUDFLARE_ACCOUNT_ID=...

# Inspect
cfafi whoami
cfafi zones list
cfafi learn              # full self-teaching prompt
cfafi explain dns create # per-verb docs

# Mutate — dry-run by default
cfafi dns create culture.dev TXT _cfafi-test "hello"           # preview
cfafi dns create culture.dev TXT _cfafi-test "hello" --apply   # commit
```

## Commands (v0.1.0)

| Command | Description |
|---|---|
| `cfafi whoami` | Verify the configured API token |
| `cfafi zones list` | List zones in the token's account |
| `cfafi dns create ZONE TYPE NAME CONTENT` | Create a DNS record (dry-run; `--apply` to commit) |
| `cfafi learn` | Self-teaching prompt for agents |
| `cfafi explain <path>` | Markdown docs for any noun/verb path |

Every command supports `--json`. Run `cfafi learn` for the full rundown.

## Also available: bash skills

Every verb has a bash counterpart under `.claude/skills/cfafi/scripts/`
(read) and `.claude/skills/cfafi-write/scripts/` (write). The Python CLI
is the preferred surface for verbs that have been ported; bash scripts
remain supported for everything else until each verb is migrated
(tracked in `docs/superpowers/specs/2026-04-24-cfafi-v0.1.0-python-cli-design.md`
§ "Subsequent PRs").

## Tests

```sh
bash tests/shellcheck.sh     # static analysis across all shell scripts
bash tests/markdownlint.sh   # lint every markdown file against .markdownlint-cli2.yaml
bats tests/bats/             # unit tests (mocked curl, real jq, no live token required)
uv run pytest -v             # Python CLI unit tests
```

All four run in CI on every PR (see `.github/workflows/test.yml`).

Required tools on the developer machine: `bash`, `curl`, `jq`, `shellcheck`, `bats`, `markdownlint-cli2`, `uv`.

## Development

See `CLAUDE.md` for repo conventions and `docs/SETUP.md` for the token
scope requirements + Trusted Publisher setup.
