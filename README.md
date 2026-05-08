# cfafi → cultureflare

> ⚠️ **`cfafi` is being renamed to `cultureflare`.** This is the last
> release on the `cfafi` PyPI name (v0.2.2). Future versions ship as
> [`cultureflare`](https://pypi.org/project/cultureflare/) from the
> same source — install either name to get the same package, and the
> CLI exposes both `cfafi` and `cultureflare` commands as aliases.

Agent-first CLI for managing CloudFlare state in the AgentCulture OSS
org. Action-oriented (commands describe operator intent, not REST
endpoints), idempotent, dry-run by default, agent-readable markdown +
`--json` output on every verb.

## Install

```bash
# Preferred (canonical name going forward):
uv tool install cultureflare

# Equivalent — installs the same package, deprecated:
uv tool install cfafi
```

Either install gives you both `cultureflare` and `cfafi` on the PATH;
they're aliases for the same entry point.

```bash
cultureflare --version
cfafi --version       # same version, same code
```

## Quick start

```bash
# Export credentials securely (see docs/SETUP.md)
export CLOUDFLARE_API_TOKEN=...
export CLOUDFLARE_ACCOUNT_ID=...

# Inspect
cultureflare whoami
cultureflare zones list
cultureflare learn              # full self-teaching prompt
cultureflare explain dns create # per-verb docs

# Mutate — dry-run by default; --apply to commit
cultureflare dns create culture.dev TXT _cfafi-test "hello"
cultureflare dns create culture.dev TXT _cfafi-test "hello" --apply

# Higher-level orchestration
cultureflare remote-login setup --hostname irc.culture.dev --allow you@example.com --apply
```

`cfafi <verb>` works identically as a backward-compat alias.

## Scope (current)

| Resource | Read | Write | Notes |
|---|---|---|---|
| Zones | ✓ `zones list` | — | All zones in the token's account |
| DNS records | ✓ via `dns create` lookup | ✓ `dns create` (with `--apply`) | Idempotent; conflict-aware |
| Cloudflare Access (Zero Trust) | ✓ `remote-login show` | ✓ `remote-login setup` / `teardown` (with `--apply`) | Per-hostname Tunnel + Access app + allow-policy + optional service token |
| Token verify | ✓ `whoami` | — | Status only (no scope inspection — CF doesn't expose) |
| Workers scripts / routes | bash skills only | — | Python port pending |
| Pages projects / deployments | bash skills only | bash `cf-pages-project-create.sh` / `cf-pages-deployments-purge.sh` | Python port pending |
| API tokens | — | — | Operator-driven by design (out of scope) |
| Zero Trust org onboarding | — | — | Dashboard only for now |

## Commands (v0.2.2)

| Command | Description |
|---|---|
| `cultureflare whoami` | Verify the configured API token is alive |
| `cultureflare zones list` | List zones in the token's account |
| `cultureflare dns create ZONE TYPE NAME CONTENT` | Create a DNS record (dry-run; `--apply` to commit) |
| `cultureflare remote-login setup --hostname H --allow EMAIL` | Provision the full Tunnel + DNS + Access stack for `H` (dry-run; `--apply` to commit) |
| `cultureflare remote-login show --hostname H` | Inspect what's currently provisioned for `H` |
| `cultureflare remote-login teardown --hostname H` | Reverse `setup` (dry-run; `--apply` to commit) |
| `cultureflare learn` | Self-teaching prompt for agents |
| `cultureflare explain <path>` | Markdown docs for any noun/verb path |

Every command supports `--json` for raw envelope output suitable for
`jq` pipelines and downstream agents. Run `cultureflare learn` for the
full rundown.

## `--json` output

Every command emits the canonical CloudFlare envelope shape
(`{success, errors, messages, result}`) under `--json`. Examples
(IDs and tokens elided as `…`):

```text
$ cultureflare whoami --json
{"success":true,"errors":[],"messages":[{"code":10000,"message":"This API Token is valid and active"}],"result":{"id":"…","status":"active","not_before":null,"expires_on":null}}

$ cultureflare zones list --json
{"success":true,"errors":[],"messages":[],"result":[{"id":"…","name":"culture.dev","status":"active","plan":{"name":"Free Website"}}],"result_info":{"page":1,"total_pages":1,"count":1,"total_count":1}}

$ cultureflare dns create culture.dev TXT _cfafi-test "hello" --json
{"success":true,"errors":[],"messages":["dry-run: no changes applied"],"result":{"dry_run":true,"zone_id":"…","would_post":{"type":"TXT","name":"_cfafi-test","content":"hello","ttl":1,"proxied":false,"comment":"Managed by cfafi in agentculture/cfafi"}}}

$ cultureflare remote-login show --hostname irc.culture.dev --json
{"success":true,"errors":[],"messages":[],"result":{"hostname":"irc.culture.dev","team_domain":"agentculture.cloudflareaccess.com","tunnel":null,"dns":null,"access_app":null,"policy":null,"service_token":null}}
```

Errors emit on stderr with the same envelope plus `code`,
`message`, and `remediation` fields.

## Credentials

Two environment variables, no `.env` walking by the installed CLI:

```bash
export CLOUDFLARE_API_TOKEN=...
export CLOUDFLARE_ACCOUNT_ID=...
```

Two-token pattern is recommended:

- **Read-only token** — for `whoami`, `zones list`, `dns create`
  (lookup), `remote-login show`. Account Settings + Zone Read.
- **Operator token** — adds Tunnel Edit, Access Apps & Policies Edit,
  Access Organizations Read, Access Service Tokens Edit (when using
  `--with-service-token`), Zone DNS Edit. Required for any verb that
  takes `--apply`.

Full token-scope tables, the secure-loading pattern, and dashboard
walkthrough live in [`docs/SETUP.md`](docs/SETUP.md). Scope correctness
is **not** preflight-validated (CF's `/user/tokens/verify` doesn't
expose granted scopes); a missing scope surfaces as a 403 mid-run with
remediation pointing back at the docs.

## Dry-run vs `--apply`

Every mutating verb is **dry-run by default**. Without `--apply`,
the command:

- Validates inputs (e.g. `--allow user@example.com` is required for
  `remote-login setup`).
- Runs read-side preflight (`whoami`, zone resolution).
- Prints the plan (or the body it would `POST`) and exits cleanly.
- Performs no `POST` / `PUT` / `DELETE` against CloudFlare.

Pass `--apply` to commit. The same command otherwise — same args, same
output shape, plus the resource IDs that got created.

`teardown` is also dry-run by default; the destructive path requires
`--apply`.

## Hybrid Python CLI / bash skills

The Python CLI is the preferred surface for verbs that have been
ported. Bash counterparts under `.claude/skills/cfafi/scripts/` (read)
and `.claude/skills/cfafi-write/scripts/` (write) remain supported for
verbs not yet migrated:

- **Python today:** `whoami`, `zones list`, `dns create`,
  `remote-login {setup,show,teardown}`, `learn`, `explain`.
- **Bash only today:** `cf-pages*.sh`, `cf-workers*.sh`,
  `cf-redirect-create.sh`. See each skill's `SKILL.md` for the full
  inventory.

Migration tracker:
[`docs/superpowers/specs/2026-04-24-cfafi-v0.1.0-python-cli-design.md`](docs/superpowers/specs/2026-04-24-cfafi-v0.1.0-python-cli-design.md)
§ "Subsequent PRs".

## Limitations

- No broad CloudFlare coverage — only the resources in the scope table
  above. Anything else needs the bash skills or a direct CF API call.
- No destructive verbs beyond `remote-login teardown`. There's no
  generic `dns delete`, `zone delete`, etc. yet.
- No auto-discovery beyond listed verbs (no fuzzy zone/account
  matching, no "find me the zone for this hostname" outside of
  `remote-login`).
- No API-token minting (`POST /user/tokens`) — operator-driven by
  design; cfafi never creates tokens for you.
- No Zero Trust org onboarding via API in v0.2; if the account
  doesn't have ZT enabled, `remote-login setup` errors with a
  dashboard link.
- `remote-login` orchestration assumes one hostname per Access app
  and a single allow-policy. Richer Access policy shapes (require /
  exclude / IdP selection) are a future PR.

## Roadmap

The two design docs that drive current and near-term work:

- [Python CLI v0.1 design](docs/superpowers/specs/2026-04-24-cfafi-v0.1.0-python-cli-design.md)
  — initial ports, command surface conventions.
- [`remote-login` action design](docs/superpowers/specs/2026-05-07-cfafi-remote-login-design.md)
  — orchestration model, idempotency, one-shot-secret handling.

Out-of-scope-for-now items are listed in each spec's "Out of scope" /
"Future" section. Repo rename `agentculture/cfafi` →
`agentculture/cultureflare` and the corresponding `cfafi/` Python
module rename are deferred — the dual-distribution shim and CLI alias
mean both names work simultaneously.

## Tests

```sh
bash tests/shellcheck.sh     # static analysis across all shell scripts
bash tests/markdownlint.sh   # lint every markdown file against .markdownlint-cli2.yaml
bats tests/bats/             # bash skill unit tests (mocked curl, real jq, no live token required)
uv run pytest -v             # Python CLI unit tests (~140 tests)
```

All four run in CI on every PR (see `.github/workflows/tests.yml`).
Required tools on the developer machine: `bash`, `curl`, `jq`,
`shellcheck`, `bats`, `markdownlint-cli2`, `uv`.

## Development

See [`CLAUDE.md`](CLAUDE.md) for repo conventions and
[`docs/SETUP.md`](docs/SETUP.md) for the token scope requirements +
Trusted Publisher setup.
