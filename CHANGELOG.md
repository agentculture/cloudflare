# Changelog

All notable changes to this project will be documented here. The format
is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.7.0] - 2026-05-15

### Added

- New runtime dependency on the `agex` and `agtag` CLIs (uv tool install agex-cli / agtag) for the cicd and communicate skills.

### Changed

- skills/cicd: resynced from steward 0.12.0 — now a thin layer over the `agex pr` CLI (lint/open/read/reply/delta) plus the `status`/`await` steward extensions. Removed create-pr-and-wait.sh, poll-readiness.sh, pr-batch.sh, pr-comments.sh, wait-and-check.sh; workflow.sh delegates to agex. pr-status.sh, portability-lint.sh, pr-reply.sh, _resolve-nick.sh keep cultureflare-local hardening. Resolves #32.
- skills/communicate: resynced from steward 0.12.0 — GitHub issue I/O is now agtag-backed. post-issue.sh rewritten as an `agtag issue post` wrapper (no hardcoded signature literal); added post-comment.sh (agtag issue reply) and fetch-issues.sh (agtag issue fetch). Resolves #33.
- skills/poll: modernized to drive `agex pr read --wait` in its background subagent instead of looping the removed pr-comments.sh.
- CLAUDE.md: layout + PR-workflow sections updated for the agex/agtag delegation; SonarCloud-key note scoped to pr-status.sh / workflow.sh status.

## [0.6.0] - 2026-05-08

### Added

- skills/cicd: PR-review workflow with portability lint, reviewer-readiness loop, batch reply, alignment-delta — vendored from steward 0.7.0; replaces the old pr-review skill
- skills/communicate: cross-repo GitHub issue posts (auto-signed `- cultureflare (Claude)`) and Culture mesh channel messages — vendored from steward 0.8.0
- portability-lint carve-outs for ~/.claude/projects/ and ~/.config/

### Changed

- CLAUDE.md and poll/SKILL.md now reference cicd skill paths instead of pr-review

### Fixed

- Pre-existing portability hits in CLAUDE.md (a fictional home-dir example) and the v0.1.0 design spec (an absolute sibling-repo path) rewritten as portable workspace-relative references.

## [0.5.0] - 2026-05-08

### Added

- `cultureflare remote-login setup --service URL`: required flag wiring tunnel public-hostname ingress on the remote-managed tunnel
- `ensure_tunnel_config` / `get_tunnel_config` helpers for idempotent tunnel ingress configuration
- `ensure_service_token_policy` / `find_service_token_policy` helpers that attach a `non_identity` policy admitting the service token to its Access app
- `tunnel-config` and `service-token-policy` step records on `setup` / `teardown`; new `tunnel_config` and `service_token_policy` fields on `show`

### Changed

- `ensure_service_token` now returns a 4-tuple `(client_id, client_secret, created, token_id)` so callers can attach a non_identity policy without a second find
- `setup()` now uses `strict=False` for the service-token step — re-running setup against an already-provisioned deployment skips the token (secret not rotated) instead of erroring; an idempotent re-run is now the supported repair path

### Fixed

- #28: provisioning a hostname via `remote-login setup` left the tunnel without an ingress rule (cloudflared returns 503) and left the service token without a non_identity policy (programmatic clients 302 to SSO). Both gaps are now closed by the same `setup` invocation.

## [0.4.0] - 2026-05-08

### Added

- `cultureflare remote-login --shushu[=USER]` flag — pipes tunnel_token + service_token client_secret directly into a `shushu set --hidden` subprocess so the secrets never cross stdout, agent harness, or operator terminal. Cross-user deposit via sudo. Markdown / JSON output replaces secret-bearing fields with `<sealed: shushu/USER/NAME>` markers; show probes shushu for presence; teardown deletes the entries.

### Changed

- `SetupResult.tunnel_token` is now `str | None`; gains `sealed_in: dict[str, str]`. `ShowResult` gains `sealed_in_status: dict[str, dict | None]`. Defaults preserve existing behaviour.
- `probe()` parsing was corrected to match shushu 0.8.0 wire format (flat dict with `ok` sentinel, no nested `result`).

## [0.3.1] - 2026-05-08

### Changed

- Renamed Python module dir `cfafi/` → `cultureflare/`, and Claude skills `.claude/skills/cfafi*` → `.claude/skills/cultureflare*`.
- Added a `cfafi/__init__.py` shim package + `.claude/skills/cfafi*` symlinks so legacy paths and `import cfafi` consumers keep working.
- Updated User-Agent, DNS-record default `comment`, repo URLs, workflow filters, lint targets, and SKILL.md frontmatter.

## [0.3.0] - 2026-05-08

### Changed

- Distribution name on PyPI is now `cultureflare` only. `cfafi` 0.2.2 was the final release on the legacy name; install `cultureflare` for ongoing updates. The `cfafi` console-script alias stays. The Python module `cfafi` stays.

## [0.2.2] - 2026-05-07

### Added

- `cultureflare` console-script alongside `cfafi` (same entry point). Future versions publish under the `cultureflare` PyPI name; this is the final `cfafi` release.
- README — scope/limitations/credential/migration sections (closes #21).

### Changed

- Publish workflow now dual-publishes the same source as both `cfafi` (final) and `cultureflare` (going forward) on PyPI / TestPyPI.

## [0.2.1] - 2026-05-07

### Fixed

- `find_org` now swallows CF error 9999 (`access.api.error.not_enabled`) into `None` so `setup` raises a curated "Zero Trust is not enabled" message with a dashboard link, and `show` renders the org as `(not found)`, instead of bubbling CF's raw 4xx.

## [0.2.0] - 2026-05-07

### Added

- `cfafi remote-login` action: setup, show, teardown a hostname behind Cloudflare Access via Tunnel.
- Operator token scopes section in docs/SETUP.md (§9).

## [0.1.2] - 2026-04-24

### Fixed

- SonarCloud `python:S3516` BLOCKER on `cmd_whoami`, `cmd_zones_list`, `cmd_dns_create` — handlers now return `None` (implicit) instead of explicit `return 0`; `_dispatch` already coerces `None` to exit 0
- SonarCloud `shelldre:S7688` MAJOR on `scripts/lint-md.sh` — use `[[` instead of `[` for conditional tests

## [0.1.1] - 2026-04-24

### Changed

- replace 1.2.3.4 IP in tests with RFC 5737 TEST-NET-3 203.0.113.10 (SonarCloud hotspot)

### Fixed

- docstring path in dns.py after skill rename (Copilot #1)
- version-check CI runs incorrectly on push events (qodo bug #3)
- version-bump SKILL.md misdescribed version-sync (Copilot #2)
- spec JSON error contract drifted from actual implementation (Copilot #3)

## [0.1.0] - 2026-04-24

### Added

- Python package `cfafi` published to PyPI via OIDC Trusted Publishing.
- `cfafi whoami` — verify the configured CloudFlare API token.
- `cfafi zones list` — list zones accessible to the token (paginated).
- `cfafi dns create ZONE TYPE NAME CONTENT` — create a DNS record;
  dry-run by default, `--apply` to commit, with `--proxied` / `--ttl` /
  `--comment` flags.
- `cfafi learn` — self-teaching prompt for agent consumers; `--json`
  emits a structured payload.
- `cfafi explain <path>...` — markdown docs by noun/verb path.
- `--json` opt-in on every verb; markdown (table or key-value) as the
  default output.
- Structured error envelope (`error: <msg>` / `hint: <remediation>`,
  or `{code, message, remediation}` under `--json`) — no Python
  tracebacks leak to stderr.
- Exit-code policy: 0 success; 1 user error; 2 env error; 3 auth; 4
  upstream CloudFlare API error.
- Vendored `version-bump` skill from `afi-cli` — the `version-check` CI
  job enforces a version bump on every PR.
- CI workflows: `tests.yml` (pytest + bats + shellcheck + markdownlint +
  version check), `publish.yml` (TestPyPI on PR, PyPI on push-to-main),
  `security-checks.yml` (weekly bandit + pylint).

### Changed

- `.claude/skills/cloudflare/` renamed to `.claude/skills/cfafi/`;
  `.claude/skills/cloudflare-write/` renamed to
  `.claude/skills/cfafi-write/`. Symlink updated.
- `CLAUDE.md` — lifted the "do not join the culture mesh from this
  repo" constraint (the actual mesh join lands in a follow-up PR).
- `README.md` — leads with `uv tool install cfafi`; bash skills are
  now the secondary "also available" path.
- `docs/SETUP.md` — credential guidance rewritten around env vars, 0600
  files, and `set -a; .; set +a`; added maintainer Trusted Publisher
  setup checklist.

### Notes

- Bash scripts under `.claude/skills/cfafi{,-write}/scripts/` are
  unchanged. Coexistence is intentional — each verb ports in its own
  follow-up PR with a patch bump. See
  `docs/superpowers/specs/2026-04-24-cfafi-v0.1.0-python-cli-design.md`
  § "Subsequent PRs".
