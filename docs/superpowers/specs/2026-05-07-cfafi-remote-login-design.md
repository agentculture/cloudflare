# `cfafi remote-login` — design

**Status:** approved 2026-05-07
**Issue:** [agentculture/cfafi#22](https://github.com/agentculture/cfafi/issues/22)
**Author:** Claude (with Ori Nachum)

## What this is

A new noun on the `cfafi` Python CLI: `cfafi remote-login`, with verbs `setup`,
`show`, and `teardown`. It is the first **action-oriented** command in cfafi
— it expresses an operator intent ("set up a subdomain for remote login")
rather than wrapping a single CloudFlare REST endpoint. Everything below
follows from that framing.

cfafi will own the full sequence of CloudFlare-side resources required to put
a hostname behind Cloudflare Access via a Tunnel:

1. Zero Trust org (account-wide; ensured once)
2. Tunnel
3. DNS CNAME → tunnel
4. Access application on the hostname
5. Allow-policy on the application
6. (Optional) service token for non-interactive callers

This supersedes the per-deployment provisioning that lives in
[`agentculture/irc-lens` `scripts/cf-roundtrip/setup.sh`][irclens-setup].
After this PR ships, irc-lens (and any other consumer) calls `cfafi
remote-login setup` instead of duplicating the orchestration. The CLI is
**agnostic to irc-lens** — every name is flag-driven; the code carries no
deployment-specific literals.

[irclens-setup]: https://github.com/agentculture/irc-lens/blob/main/scripts/cf-roundtrip/setup.sh

## What this is *not*

- **Not an API-token mint.** Issue #22's "mint a scoped API token" step is
  out of scope. The operator mints their own token in the CloudFlare
  dashboard. cfafi never calls `POST /user/tokens`. Reasoning: token
  minting is a sensitive credential operation that benefits from human
  in-the-loop review of the scopes; automating it without operator
  oversight is exactly the wrong place to optimise.
- **Not a 1-to-1 wrapper around CloudFlare endpoints.** For raw REST,
  there's `curl`, `wrangler`, and the SDK. cfafi's value is the
  composition.
- **Not a primitive surface.** `cfafi tunnel create`, `cfafi access-app
  create` etc. are *not* shipped as user-facing commands. They live as
  internal helpers and may be promoted later if a second consumer
  appears.
- **Not a token-runtime.** cfafi does not run `cloudflared`. The tunnel
  token is printed; the operator runs the daemon on their own host.

## Architecture

```
cfafi/
├── _api.py                          # existing — http_request, paginate
├── _env.py                          # existing
├── _remote_login/                   # NEW — internal orchestration helpers
│   ├── __init__.py                  # public: setup(), show(), teardown()
│   ├── _access_org.py               # ensure_org()
│   ├── _tunnel.py                   # ensure_tunnel(), get_tunnel_token(),
│   │                                #   delete_tunnel()
│   ├── _dns.py                      # ensure_cname(), delete_cname()
│   ├── _access_app.py               # ensure_app(), delete_app()
│   ├── _access_policy.py            # ensure_allow_policy(), delete_policy()
│   └── _service_token.py            # ensure_service_token(),
│                                    #   delete_service_token()
└── cli/_commands/
    └── remote_login.py              # NEW — argparse wiring + render
```

Each `_remote_login/_*.py` exports `ensure_<thing>(...)` and (where
applicable) `delete_<thing>(...)`. The shape of `ensure_*` is:

```python
def ensure_thing(...) -> tuple[str, bool]:
    """Returns (resource_id, created_now)."""
```

That's the idempotency primitive. `setup` calls them in order; `show`
calls a parallel `find_*` (lookup-only, never creates); `teardown`
calls the matching `delete_*` in reverse.

The CLI command file (`cli/_commands/remote_login.py`) is thin: it
parses args, builds a context dict (account_id, zone_id, derived names),
runs the orchestrator, and renders output.

## Command surface

```
cfafi remote-login setup    --hostname HOST [--allow EMAIL]... [--allow-domain @DOM]...
                            [--tunnel-name NAME] [--app-name NAME]
                            [--service-token-name NAME] [--with-service-token]
                            [--session-duration DURATION]
                            [--apply] [--json]

cfafi remote-login show     --hostname HOST [--json]

cfafi remote-login teardown --hostname HOST [--keep-tunnel]
                            [--apply] [--json]
```

### `setup`

- `--hostname HOST` (required) — fully-qualified hostname. Must end in a
  zone the token can edit. cfafi resolves the zone from the hostname
  (`irc.culture.dev` → zone `culture.dev`); error early if no match.
- `--allow EMAIL` (repeatable) — email addresses included in the policy.
- `--allow-domain @example.com` (repeatable) — email-domain include rule
  ("anyone with an email at `@example.com`"). Stored as the
  `email_domain` Access include shape.
- At least one of `--allow` / `--allow-domain` must be given. An app
  with no policy that allows somebody is a misconfiguration; we refuse it.
- `--tunnel-name NAME` — defaults to slug of host (`irc.culture.dev` →
  `irc-culture-dev`).
- `--app-name NAME` — defaults to the hostname literal.
- `--service-token-name NAME` — defaults to `<host>-svc`.
- `--with-service-token` — opt-in. Without it, `setup` skips step 6.
  Many deployments authenticate users only and don't need a service
  token.
- `--session-duration DURATION` — passed through to the Access app
  (`session_duration`). Default: `24h`.
- `--apply` — without it, dry-run only. With it, executes.
- `--json` — emits the canonical envelope instead of markdown.

### `show`

- `--hostname HOST` (required).
- Read-only; does not accept `--apply`.
- Reports presence/absence of every resource a `setup` for the same
  hostname would create. Missing resources render as `(not found)`.

### `teardown`

- `--hostname HOST` (required).
- `--keep-tunnel` — skip tunnel deletion (useful when re-pointing a
  tunnel at a different hostname; uncommon).
- The Zero Trust org is **never** deleted by `teardown`. It's
  account-wide; other apps may depend on it. (No `--keep-zt-org` flag
  exists; documenting the absence here so it doesn't get added by
  reflex.)
- `--apply` — same dry-run-by-default semantics as `setup`.

## State & idempotency

Each `ensure_*` helper:

1. **Looks up by stable key (name only):**
   - tunnel: name == `--tunnel-name`
   - DNS: type=CNAME AND name=hostname
   - access-app: domain == hostname (CF-enforced unique)
   - allow-policy: name == `<app-name>-allow`, attached to the app
   - service-token: name == `--service-token-name` (account-scoped)
   - ZT org: presence/absence (at most one per account)
2. **If found:** return `(id, created=False)`. We do **not** reconcile
   drift on most fields — if the operator hand-edited a non-conflicting
   field in the dashboard (e.g. the access-app's `session_duration`),
   we leave it alone. Fighting drift would surprise more often than it
   would help.
3. **If found but in a state that *blocks* the operation:** error with
   a clear conflict message and remediation. The two cases that warrant
   this:
   - **DNS CNAME exists at the hostname pointing somewhere other than
     our tunnel.** CF rejects duplicate CNAMEs at the same name, so
     creating would fail with an opaque API error anyway. We surface a
     readable conflict message: `DNS CNAME at <hostname> already
     points to <other> — refusing to repoint. Run \`cfafi remote-login
     teardown --hostname <hostname>\` first, or change the record in
     the dashboard.`
   - **Service token of the same name exists** when `--with-service-token`
     was passed (covered in the secrets section below — secret is not
     retrievable, so we refuse rather than silently produce a
     half-printed output).
4. **If absent:** POST, return `(id, created=True)`.

**Naming is the contract.** `setup`/`show`/`teardown` agree on the same
names from the same flags. If the operator passed `--tunnel-name foo` to
`setup`, they pass it again to `teardown`.

### One-shot vs. refetchable secrets

| Secret | One-shot? | Re-run behavior |
|---|---|---|
| `TUNNEL_TOKEN` (runtime) | No — refetchable from `GET /accounts/{id}/cfd_tunnel/{id}/token` | Always re-fetched on every `setup` invocation; always present in `setup` output. |
| `SERVICE_TOKEN_CLIENT_SECRET` | **Yes** — only returned by the original `POST .../service_tokens` | If `setup` finds an existing service token by name, the secret is unrecoverable. Print a warning + `client_id` only. `--with-service-token` paired with an existing token of the same name → error with remediation: `--service-token-name=<other>` or run `teardown` first. |

`show` reports the service-token's secret status as `secret: <not
retrievable; rotate or recreate>`.

### Partial-failure recovery

If step N fails, steps 1..N-1 stay applied. The operator either
re-runs `setup` (idempotent — picks up where it stopped) or runs
`teardown` to clean up. We print partial output on failure so they can
see what landed and what didn't.

## Output

Markdown by default; JSON envelope under `--json`.

### `setup --apply` success

```
## Remote login set up — <hostname>

- **CF_TEAM_DOMAIN:** <auth_domain>
- **TUNNEL_NAME:** <name>
- **TUNNEL_ID:** <id>
- **TUNNEL_TOKEN:** <token>
- **DNS:** CNAME <hostname> → <tunnel-id>.cfargotunnel.com (proxied)
- **ACCESS_APP_ID:** <id>
- **POLICY:** allow [<emails>], allow-domain [<domains>]
- **SERVICE_TOKEN_CLIENT_ID:** <id>            # only with --with-service-token
- **SERVICE_TOKEN_CLIENT_SECRET:** <secret>    # one-shot, save now

## Steps
1. ✓ ensured Zero Trust org (existing | created)
2. ✓ ensured tunnel <name> (existing | created)
3. ✓ ensured DNS CNAME (existing | created)
4. ✓ ensured Access app (existing | created)
5. ✓ ensured allow-policy (existing | created)
6. ✓ ensured service token (existing | created)    # only with --with-service-token
```

The section keys (e.g. `**CF_TEAM_DOMAIN:**`, `**TUNNEL_TOKEN:**`) are
stable so downstream agents can grep / parse without a full markdown
parser.

### `setup` dry-run

Same shape but the body is a "Plan" section instead of "Steps", no IDs,
no secrets, marked clearly as **Dry-run — no changes applied**.

### `show`

```
## Remote login state — <hostname>
- **zero-trust-org:** <auth_domain>
- **tunnel:** <name> (id=<id>)
- **dns:** CNAME <hostname> → <tunnel-id>.cfargotunnel.com (proxied) ✓
- **access-app:** id=<id>
- **policies:** 1 allow rule
- **service-token:** <name> (id=<id>, secret not retrievable)
```

Missing resources render as `(not found)` in place of the value.

### `teardown --apply`

Numbered list of what was deleted, mirrors `setup` in reverse.

### `--json` envelope

Same `{success, errors, messages, result}` shape as the rest of the CLI.
`result` for `setup` is a dict with keys matching the markdown sections:
`team_domain`, `tunnel_name`, `tunnel_id`, `tunnel_token`, `dns`,
`access_app_id`, `policy`, `service_token_client_id`,
`service_token_client_secret`. Deterministic shape so an agent can `jq`
it.

### Secret handling

Secrets land on stdout exactly as printed. cfafi does not redact. The
help text says: "secrets land on stdout — redirect to a file, don't
paste into chat." That's the operator's responsibility.

## Auth scopes

The operator's `CLOUDFLARE_API_TOKEN` (loaded from `.env` by `_env.py`)
needs broader scope than read-only cfafi has today. For `remote-login
setup` to actually run, the token must carry:

- **Account → Cloudflare Tunnel: Edit** — tunnel create/delete/get-token
- **Account → Access: Apps and Policies: Edit** — access-app, policy
- **Account → Access: Service Tokens: Edit** — service-token (only when
  `--with-service-token`)
- **Account → Access: Organizations: Edit** — onboard ZT org (only on
  first run; can be downgraded to Read afterwards)
- **Zone → DNS: Edit** on the zone(s) hosting target hostnames

The operator mints this token themselves (issue #22 deliverable from the
operator side, not from cfafi).

### Pre-flight

Before any orchestration, `setup` calls `GET /user/tokens/verify` and
validates that `policies[].permission_groups[].name` covers the
required scopes for the requested operation. If a scope is missing,
error early with a remediation pointing at the dashboard token-create
UI and listing the missing scopes by exact name. The operator sees a
clean "your token is missing X" message instead of a 403 mid-orchestration.

### Documentation

`docs/SETUP.md` already lists token scopes for the read-only cfafi
token. This PR adds a second section for the write-capable "remote-login
operator" token, including the dashboard URL and the exact scope names
to tick.

## Testing

### Unit (CI, offline)

`tests/unit/test_remote_login_*.py`. Each `ensure_*` helper has its own
test using a fake `_api.http_request` injected via `monkeypatch`. Cases
per helper:

- Resource absent → POST issued → returns `(id, True)`
- Resource present (matched by name) → no POST → returns `(id, False)`
- Resource present but a field drifted → no mutation; existing id returned
- API error → `CfafiError` raised with helpful message

Orchestrator tests for `setup` / `show` / `teardown` assert the **call
sequence** against a recording fake — six steps in the right order;
dry-run skips the POSTs; partial failure leaves earlier IDs in the
output dict.

Markdown rendering tests — small, against fixed input dicts,
golden-file style under `tests/unit/golden/`.

### Live smoke (manual, gated)

Operator provides a throwaway hostname they control, runs:

```
cfafi remote-login setup --hostname <yours> --allow <you> --apply
cfafi remote-login show --hostname <yours>
cfafi remote-login teardown --hostname <yours> --apply
cfafi remote-login show --hostname <yours>     # all (not found)
```

Round-trip output gets pasted into the PR description with the hostname
redacted to `<example>`. The throwaway hostname is never written to
the repo, never to a fixture, never to a test.

The PR can ship before live smoke; smoke is a manual gate before merge.

### No live tests in CI

Anything that hits the live API stays out of `pytest`.

## Out of scope (follow-ups)

- API-token minting (deliberately out — operator-driven).
- Promoting `_remote_login/_*.py` helpers to public CLI nouns
  (`cfafi tunnel create`, etc.). Will land if/when a second consumer
  needs them.
- Multiple hostnames per Access app. CF supports it; v1 is 1:1.
- IdP selection / `require` / `exclude` policy rules. v1 is allow-only,
  default IdP only. Sufficient for the initial use case; richer policy
  shapes follow demand.
- Reconciling drift on existing resources (we deliberately don't).
- Mesh-agent integration (a peer agent driving cfafi via stable CLI
  output). The deterministic markdown / JSON shape is designed for it,
  but the wiring lives in a later PR.

## Open questions

None at design-approval time. Implementation may surface specifics
(e.g. exact CF API field names for some Access app params) — those
get resolved during implementation, not here.
