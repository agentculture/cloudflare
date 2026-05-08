# `cultureflare remote-login` — sealed-secret mode via shushu

## Problem

`cultureflare remote-login setup --apply` mints two bearer credentials and
hands them to the operator on stdout:

- `service_token_client_secret` — one-shot from the Cloudflare API; if
  lost it cannot be recovered, only rotated.
- `tunnel_token` — refetchable from `/cfd_tunnel/{id}/token`, but still
  a bearer credential.

Today both values cross the CLI's stdout (markdown + `--json`), the
operator's terminal scrollback, and any harness that reads tool output
(including agent-driven harnesses like Claude Code). That last point is
the load-bearing one: an agent driving cultureflare to provision a
deployment ends up with the secret in its conversation log, and the
operator running the agent ends up reading it. Neither party should
ever see the value if the only consumer is downstream automation.

## Goal

Add a `--shushu[=USER]` flag to `cultureflare remote-login
{setup,show,teardown}` that pipes the two secrets directly into a
[shushu](https://github.com/agentculture/shushu) hidden record and
replaces every secret-bearing field in the rendered output with a
sealed-name marker. The secret value never leaves the cultureflare
process except through stdin to a `shushu set --hidden` subprocess.

When the flag is absent, behavior is bit-identical to today.

## Non-goals

- Sealing for any verb other than `remote-login` (no `cf-pages-project-create`,
  no bash skills). Python CLI only.
- A standalone `cultureflare secrets` subcommand. If the pattern proves
  useful elsewhere, that is a follow-up spec.
- Encryption at rest of the shushu vault. Tracked upstream in
  [shushu#8](https://github.com/agentculture/shushu/issues/8).
- Auto-rotation. The flag tells operators *how* to rotate via the
  `--rotate-howto` metadata stamp shushu surfaces; scheduling is the
  operator's job.
- Cross-user integration tests requiring sudo + a fixture user. Argv
  construction is unit-tested; release-gating is manual.

## Background — shushu primitives this design relies on

| Verb | Behavior |
|---|---|
| `shushu set --hidden NAME -` | Reads the secret from stdin. Stores `0600` plaintext in `~/.local/share/shushu/secrets.json` (the on-disk format is plaintext today; encryption-at-rest is shushu#8). `--hidden` makes the entry **immutable** — there is no un-hide path — and refused by every reader except `run --inject`. |
| `shushu show NAME --json` | Returns metadata (source, purpose, rotate-howto, hidden flag). For hidden entries, the JSON has no `value` field. |
| `shushu run --inject VAR=NAME -- cmd` | The only way to consume a hidden secret. Forks `cmd` with `VAR=<value>` injected into its environment; the value never appears in the parent shell, in `/proc/<pid>/environ` of any other process, or on any tty. |
| `shushu delete NAME` | Removes the entry. |
| `--user NAME` (sudo-required) | Operates on another OS user's vault via the setuid-fork chokepoint in shushu's `privilege.run_as_user`. The invoker is recorded in the entry's `source` field. |

The contract is a CLI contract, not encryption — root can `cat
~alice/.local/share/shushu/secrets.json` directly. cultureflare relies
on shushu's contract, not its on-disk shape.

## Architecture

```text
cultureflare remote-login                   CF API
    │                                            │
    ├── (1) /cfd_tunnel/.../token  ◄─────────────┤   tunnel_token (str in mem)
    │                                            │
    ├── (2) /access/service_tokens ◄─────────────┤   client_secret (str in mem)
    │
    ├── (3) for each {target, secret}:
    │     subprocess: [sudo?] shushu set --hidden \
    │                              --source cultureflare/remote-login \
    │                              --purpose "remote-login <hostname>" \
    │                              --rotate-howto "<command line>" \
    │                              [--user TARGET] NAME -
    │     stdin: <secret bytes> ; close ; wait()
    │     non-zero exit → CfafiError, abort, do NOT print secret
    │
    └── (4) render SetupResult — sealed fields → null + sealed_in marker;
            never the raw secret.
```

The sink module (`_secrets/_shushu_sink.py`) is independent of the
remote-login orchestrator: any future verb that produces a secret
re-uses the same `seal/probe/delete` triple.

## Components

### New module: `cultureflare/_secrets/_shushu_sink.py`

Single responsibility: write/probe/delete shushu records via
subprocess. Knows nothing about Cloudflare or remote-login.

```python
@dataclass(frozen=True)
class ShushuTarget:
    user: str | None              # None → invoking user (no sudo)
    name: str                     # entry name in shushu

@dataclass(frozen=True)
class SealMetadata:
    source: str                   # e.g. "cultureflare/remote-login"
    purpose: str                  # e.g. "remote-login app.example.com"
    rotate_howto: str             # one-line operator guidance


def seal(target: ShushuTarget, secret: bytes, meta: SealMetadata) -> None:
    """Pipe `secret` into `shushu set --hidden`.

    `secret` is bytes (not str) end-to-end so a stray repr() can't
    surface the value in a traceback or log. The secret is passed via
    `subprocess.run(input=...)`, never in argv. On non-zero exit,
    raises CfafiError mapped from the shushu exit code:
      0     → return None
      64    → CfafiError(EXIT_USER_ERROR)
      65/66/67/70 → CfafiError(EXIT_UPSTREAM)
    On `FileNotFoundError` (shushu binary missing): CfafiError with
    install remediation."""

def probe(target: ShushuTarget) -> dict | None:
    """Return shushu's metadata dict for the entry, or None when
    shushu reports EXIT_USER_ERROR(64) (record absent). Any other
    non-zero exit raises."""

def delete(target: ShushuTarget) -> bool:
    """True if the record was removed; False if it was already
    absent. Other shushu errors raise."""
```

### New module: `cultureflare/_remote_login/_seal_plan.py`

Pure function naming + plan derivation. No I/O. Same plan computable
for setup, show, and teardown.

```python
@dataclass(frozen=True)
class SealPlan:
    enabled: bool
    user: str | None
    tunnel_token_target: ShushuTarget
    service_token_secret_target: ShushuTarget
    metadata: SealMetadata        # same metadata for both secrets (rotate-howto
                                  # is the same command line for both seals;
                                  # purpose mentions the hostname, not the secret)

def derive_seal_plan(*, hostname: str, shushu_arg: str | None) -> SealPlan:
    """shushu_arg semantics:
       None     → enabled=False (flag not passed)
       ""       → enabled=True,  user=None (--shushu, invoking user)
       "alice"  → enabled=True,  user="alice" (--shushu=alice)
    Name slug:
       "CULTUREFLARE_" + hostname.upper().replace(".", "_").replace("-", "_")
    Per-secret suffix:
       <slug> + "_TUNNEL_TOKEN" | "_SVC_SECRET"
    Hostname must be ASCII (no IDN). Validated here; raises
    CfafiError on violation."""
```

Worked example (hostname `app.example.com`):

| Field | Value |
|---|---|
| slug | `CULTUREFLARE_APP_EXAMPLE_COM` |
| tunnel-token entry | `CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN` |
| service-token-secret entry | `CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET` |

### Wire-in points (existing files modified)

| File | Change |
|---|---|
| `cultureflare/_remote_login/__init__.py::setup` | Accepts `seal: SealPlan`. After `get_tunnel_token` and `ensure_service_token`, if `seal.enabled`, call `_shushu_sink.seal(...)` for each secret and **replace** the secret in the returned `SetupResult` with `None` plus a `sealed_in[K]` mapping entry. CF responses still hold the value in memory until the seal call returns; on seal failure abort before any printing. |
| `cultureflare/_remote_login/_common.py` | `SetupResult` and `ShowResult` gain `sealed_in: dict[str, str]` (`{"tunnel_token": "shushu/<user>/<NAME>"}`). Existing `tunnel_token` becomes `Optional[str]` (`service_token_client_secret` already is). `ShowResult` gains `sealed_in_status: dict[str, dict | None]` for the probe results. |
| `cultureflare/_remote_login/_render.py` | If `sealed_in[K]` set, render the sealed marker in markdown (`<sealed: shushu/<user>/<NAME>>`) and set value field to `null` in JSON; sibling `sealed_in.K` block exposes the marker for machine consumers. |
| `cultureflare/cli/_commands/remote_login.py` | argparse: `--shushu` with `nargs='?'`, `const=''`, `default=None`. Bare `--shushu` → invoking user; `--shushu=alice` → cross-user. Threaded into the orchestrator via `SealPlan`. |
| `cultureflare/_remote_login/__init__.py::show` | If `seal.enabled`, also call `_shushu_sink.probe(...)` for each derived target. Surface in `ShowResult.sealed_in_status` (per-target `{"present": bool, "name": str, "source": str | None}` or `None` when shushu is absent). |
| `cultureflare/_remote_login/__init__.py::teardown` | If `seal.enabled`, after CF-side deletion, call `_shushu_sink.delete(...)` for each target. Failures emit a `StepRecord(action="delete-failed", ...)` but do **not** abort — the CF resources are already gone. |

## Data flow — setup with `--shushu=alice --apply`

1. **Plan derivation** — `derive_seal_plan(hostname=H, shushu_arg="alice")`
   produces target names. Pure; no subprocess yet.
2. **CF calls** run normally. `tunnel_token` and `service_token_client_secret`
   exist as `bytes`/`str` in process memory.
3. **For each {target, secret}** (in fixed order: tunnel, then service-token):

   ```python
   subprocess.run(
       ["sudo", "shushu", "set", "--hidden",
        "--source", "cultureflare/remote-login",
        "--purpose", f"remote-login {hostname}",
        "--rotate-howto", rotate_howto_for(hostname, "alice"),
        "--user", "alice",
        target.name, "-"],
       input=secret_bytes,
       check=False,
       capture_output=True,
   )
   ```

   The secret is passed via `input=`, **never** in argv — it does not
   appear in `/proc/<pid>/cmdline`. `sudo` reads its password from
   `/dev/tty` by default, not stdin, so the secret pipe is unaffected
   in interactive sessions.

4. After both seals succeed, build `SetupResult` with:
   `tunnel_token = None`, `service_token_client_secret = None`,
   `sealed_in = {"tunnel_token": "shushu/alice/...", "service_token_client_secret": "shushu/alice/..."}`.
   The local secret variables go out of scope. Render. Done.

## Error handling

| Scenario | Behavior |
|---|---|
| `shushu` not on PATH | `CfafiError(EXIT_USER_ERROR, "shushu not installed", remediation="uv tool install shushu, or omit --shushu to print secrets to stdout (insecure)")`. Aborts before any CF write. |
| `--shushu=alice` but invoker lacks sudo | sudo `CalledProcessError` → `CfafiError(EXIT_USER_ERROR, "cannot deposit into alice's vault: sudo required", remediation="run with sudo, or use --shushu (self) instead")`. |
| `shushu set` exits 64 (entry name conflict — hidden is immutable) | `CfafiError(EXIT_USER_ERROR, "shushu entry NAME already exists; rotate or delete it first", remediation="`sudo shushu delete --user alice NAME`, then re-run setup")`. |
| First seal succeeds, second seal fails | **Critical path.** CF resources exist; one secret stored; one secret was minted by CF and is now lost (one-shot for service-token). Raise `CfafiError(EXIT_UPSTREAM, "partial seal — first secret stored, second failed; rotate immediately", remediation="cultureflare remote-login teardown ... --shushu=...; cultureflare remote-login setup ... --shushu=... --apply")`. The first sealed entry is left in shushu; teardown picks it up on rerun. |
| `--shushu` present but `--apply` absent (dry-run) | Plan output adds `7. seal tunnel_token into shushu/<user>/CULTUREFLARE_..._TUNNEL_TOKEN` and `8. seal service-token client_secret into shushu/<user>/CULTUREFLARE_..._SVC_SECRET`. No subprocess invocation. |
| `show --shushu=alice` and shushu missing | Render the sealed-in column as `?? (shushu not installed)`. CF-side state still rendered. `show` is read-only inventory and does not fail the whole command. |
| `teardown --shushu=alice` and a shushu entry is already absent | `delete()` returns False; emit `StepRecord(action="skipped", detail="shushu entry already absent")`. |

## Rendered output

### Markdown — setup `--shushu=alice --apply`

```text
- **service-token:** app.example.com-svc (id=...)
- **service-token-secret:** <sealed: shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET>
- **tunnel-token:** <sealed: shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN>
- **rotate:** cultureflare remote-login teardown --hostname app.example.com --shushu=alice && cultureflare remote-login setup --hostname app.example.com --shushu=alice --apply ...
```

### JSON — `--json --shushu=alice --apply`

```json
{
  "success": true,
  "result": {
    "tunnel_token": null,
    "service_token_client_secret": null,
    "sealed_in": {
      "tunnel_token": "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN",
      "service_token_client_secret": "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET"
    },
    "...": "..."
  }
}
```

### Markdown — show `--shushu=alice`

```text
- **service-token:** ... (id=..., secret not retrievable)
- **sealed-in:**
  - tunnel_token: shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN — present (source: cultureflare/remote-login)
  - service_token_client_secret: shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET — absent
```

## Testing

### Unit tests (offline, subprocess.run mocked)

| Test file | Coverage |
|---|---|
| `tests/test_secrets_shushu_sink.py` | (1) argv construction with/without `--user`, with/without `sudo`; (2) secret passed via `input=`, never in argv; (3) `seal()` with `str` raises `TypeError` (bytes-only discipline); (4) exit codes mapped — 0 → ok, 64 → `EXIT_USER_ERROR`, 65/66/67/70 → `EXIT_UPSTREAM`; (5) `FileNotFoundError` → CfafiError with install remediation. |
| `tests/test_remote_login_seal_plan.py` | `derive_seal_plan` — `None` → disabled; `""` → enabled, user=None; `"alice"` → enabled, user="alice"; expected name slug for several hostnames (hyphens, dots, mixed case); IDN/non-ASCII hostname → CfafiError. |
| `tests/test_remote_login_orchestrator.py` (extend) | (a) `setup` with `seal.enabled=True` calls `sink.seal` exactly twice with the right targets; (b) on first-success/second-failure, raises `CfafiError(EXIT_UPSTREAM)` with the rotate remediation; (c) `SetupResult.tunnel_token` and `service_token_client_secret` are `None` when sealed; `sealed_in` populated; (d) `setup` with `seal.enabled=False` is bit-identical to today (regression guard). |
| `tests/test_remote_login_render.py` (extend) | Markdown rendering replaces value rows with sealed markers; JSON has `null` value plus `sealed_in` block. Snapshot-style comparison against fixture strings. |
| `tests/test_cli_remote_login.py` (extend) | argparse for `--shushu` (nargs=?): no flag → None; bare `--shushu` → ""; `--shushu=alice` → "alice". Threading into `SealPlan` verified. |

### Integration test (gated, real shushu)

`tests/test_secrets_shushu_integration.py` — only runs when
`SHUSHU_INTEGRATION=1` is set and `shushu` is on PATH (skip
otherwise). Uses a temporary fake-XDG dir. Asserts:

- `seal()` of a known byte-string makes the name appear in `shushu list`.
- `shushu show NAME --json` returns `hidden=true` and no `value` field.
- `shushu run --inject VAR=NAME -- env` injects the *exact* original
  byte-string we sealed (round-trip).
- `delete()` removes the entry.

Cross-user (`--user`) paths are not integration-tested — would
require sudo and a fixture user. Argv construction is unit-covered;
release-gating is manual.

### No-regression guards

- `tests/test_back_compat.py` — add
  `test_setup_without_shushu_flag_returns_secrets_in_clear` to lock
  existing behavior. If a future refactor accidentally seals by
  default, this fails loudly.
- `tests/bats/` — no changes (Python-only feature; bash skills
  untouched).

### Manual smoke (post-merge, non-CI)

1. Local: `cultureflare remote-login setup --hostname app.example.com --allow ME --with-service-token --shushu --apply`
   → both secrets land in invoking user's shushu vault as hidden;
   output shows sealed markers; `shushu list` shows two new entries.
2. `cultureflare remote-login show --hostname app.example.com --shushu`
   → reports presence of both sealed entries.
3. Round-trip: `shushu run --inject TOK=CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN -- bash -c 'echo "${#TOK}"'`
   → prints expected token length (non-zero).
4. Teardown: `cultureflare remote-login teardown --hostname app.example.com --shushu --apply`
   → CF resources removed AND shushu entries removed.

## Migration & back-compat

- The flag is opt-in. No existing user is affected.
- The `cfafi` shim package keeps working — the new code paths live
  under `cultureflare._secrets` and `cultureflare._remote_login._seal_plan`,
  and are aliased into `cfafi._secrets` / `cfafi._remote_login._seal_plan`
  by the existing `sys.modules` sweep in `cfafi/__init__.py`. The eager-
  import block in that file gains two lines for the new submodules.
- Existing tests that call `setup(...)` without `seal=` keep passing —
  the parameter has a default of `SealPlan(enabled=False, ...)`.

## Version bump

`v0.3.1 → v0.4.0` (minor — new feature, no breaking changes).

## Open questions

None blocking. Bikeshed-grade choices already locked in:

- Sealed marker format `<sealed: shushu/<user>/<NAME>>` (markdown),
  separate `sealed_in` field (JSON).
- Slug derivation `hostname.upper().replace(".", "_").replace("-", "_")`.
- Both secrets always sealed together (no per-secret control).
- Hidden always (no `--visible` escape hatch).
