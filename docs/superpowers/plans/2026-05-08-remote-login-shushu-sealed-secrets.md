# `cultureflare remote-login --shushu` sealed-secret mode — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `--shushu[=USER]` flag to `cultureflare remote-login {setup,show,teardown}` so the two bearer credentials (`tunnel_token`, `service_token_client_secret`) are streamed directly into a `shushu set --hidden` subprocess and never cross stdout, agent harness, or operator terminal.

**Architecture:** A new `cultureflare/_secrets/` package owns the shushu-CLI adapter (`_shushu_sink.py`) and the data types (`_types.py`). A new pure-function module `cultureflare/_remote_login/_seal_plan.py` derives target names + metadata from the hostname. The orchestrator's `setup`/`show`/`teardown` accept a `SealPlan`; when `enabled`, they call into the sink and replace secret-bearing fields in the result dataclasses with sealed-name markers. The CLI module wires a `--shushu[=USER]` argparse flag through. When the flag is absent, behavior is bit-identical to today.

**Tech Stack:** Python 3.12 stdlib (`subprocess`, `dataclasses`), pytest, the `shushu` CLI as a subprocess dependency. No new pip deps.

**Spec:** `docs/superpowers/specs/2026-05-08-remote-login-shushu-sealed-secrets-design.md`

**Branch:** `feat/remote-login-shushu-sealed-secrets` (already created, has the spec commit).

---

## File structure

| Path | Status | Responsibility |
|---|---|---|
| `cultureflare/_secrets/__init__.py` | new | Package marker. Empty. |
| `cultureflare/_secrets/_types.py` | new | `ShushuTarget`, `SealMetadata` frozen dataclasses. No I/O. |
| `cultureflare/_secrets/_shushu_sink.py` | new | `seal`, `probe`, `delete` — subprocess.run wrappers around the shushu CLI. Maps shushu exit codes to `CfafiError`. |
| `cultureflare/_remote_login/_seal_plan.py` | new | `SealPlan` dataclass + `derive_seal_plan(hostname, shushu_arg)` pure function. Slug derivation + ASCII validation. |
| `cultureflare/_remote_login/_common.py` | modify | Add `sealed_in: dict[str, str]` to `SetupResult` and `ShowResult`; add `sealed_in_status: dict[str, dict | None]` to `ShowResult`; make `tunnel_token: str \| None` (was `str`). |
| `cultureflare/_remote_login/__init__.py` | modify | `setup`/`show`/`teardown` accept `seal: SealPlan`. Wire sink calls. |
| `cultureflare/_remote_login/_render.py` | modify | If `sealed_in[K]` set, render sealed marker in markdown / `null + sealed_in` in JSON. |
| `cultureflare/cli/_commands/remote_login.py` | modify | argparse `--shushu` flag (nargs=?, const=""). Build `SealPlan`. Thread through. |
| `cfafi/__init__.py` | modify | Add two `import cultureflare._secrets...` lines to the eager-import block (back-compat shim aliases new submodules into `cfafi.*`). |
| `tests/test_secrets_shushu_sink.py` | new | Unit tests for sink (subprocess mocked). |
| `tests/test_remote_login_seal_plan.py` | new | Unit tests for `derive_seal_plan`. |
| `tests/test_remote_login_common.py` | modify | Add coverage for new `sealed_in*` fields. |
| `tests/test_remote_login_orchestrator.py` | modify | Add seal-mode tests for setup/show/teardown. |
| `tests/test_remote_login_render.py` | modify | Add sealed-marker render tests. |
| `tests/test_cli_remote_login.py` | modify | argparse for `--shushu` (no flag → None; bare → ""; `=alice` → "alice"). |
| `tests/test_back_compat.py` | modify | Lock that `setup(...)` without `seal=` still returns secrets in clear. |
| `tests/test_secrets_shushu_integration.py` | new | Real-shushu round-trip (gated by `SHUSHU_INTEGRATION=1`). |
| `pyproject.toml`, `cultureflare/__init__.py`, `CHANGELOG.md` | modify (final task) | Version bump 0.3.1 → 0.4.0. |

---

## Tasks

### Task 1: New `_secrets` package + types

**Files:**
- Create: `cultureflare/_secrets/__init__.py` (empty)
- Create: `cultureflare/_secrets/_types.py`
- Test: `tests/test_secrets_types.py` (new)

- [ ] **Step 1: Write the failing test**

`tests/test_secrets_types.py`:

```python
"""Tests for cultureflare._secrets._types."""

import pytest

from cultureflare._secrets._types import SealMetadata, ShushuTarget


def test_shushu_target_immutable():
    t = ShushuTarget(user=None, name="MY_SECRET")
    with pytest.raises(Exception):  # FrozenInstanceError subclass of Exception
        t.name = "OTHER"  # type: ignore[misc]


def test_shushu_target_self_user_is_none():
    t = ShushuTarget(user=None, name="MY_SECRET")
    assert t.user is None
    assert t.name == "MY_SECRET"


def test_shushu_target_cross_user():
    t = ShushuTarget(user="alice", name="MY_SECRET")
    assert t.user == "alice"


def test_seal_metadata_holds_three_strings():
    m = SealMetadata(
        source="cultureflare/remote-login",
        purpose="remote-login app.example.com",
        rotate_howto="cultureflare remote-login teardown && setup --shushu --apply",
    )
    assert m.source == "cultureflare/remote-login"
    assert m.purpose == "remote-login app.example.com"
    assert "teardown" in m.rotate_howto
```

- [ ] **Step 2: Run test to verify it fails**

```bash
uv run pytest tests/test_secrets_types.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'cultureflare._secrets'`.

- [ ] **Step 3: Create the package marker**

`cultureflare/_secrets/__init__.py` — leave entirely empty (one trailing newline only).

- [ ] **Step 4: Create the types module**

`cultureflare/_secrets/_types.py`:

```python
"""Pure data types for the secrets-sink layer.

Lives outside ``_remote_login/`` because future verbs that mint
secrets (e.g. token rotation) reuse the same shape.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ShushuTarget:
    """Where a sealed secret lives in shushu.

    ``user=None`` means the invoking OS user (no sudo). A non-None
    value means cross-user: cultureflare will invoke ``sudo shushu``.
    """

    user: str | None
    name: str


@dataclass(frozen=True)
class SealMetadata:
    """Provenance + operator guidance stamped on every shushu entry.

    These map 1:1 to ``shushu set --source / --purpose / --rotate-howto``.
    Same metadata is used for both secrets in a remote-login seal — the
    rotate-howto command line tears down and re-creates both at once.
    """

    source: str
    purpose: str
    rotate_howto: str
```

- [ ] **Step 5: Run test to verify it passes**

```bash
uv run pytest tests/test_secrets_types.py -v
```

Expected: 4 passed.

- [ ] **Step 6: Commit**

```bash
git add cultureflare/_secrets/__init__.py cultureflare/_secrets/_types.py \
        tests/test_secrets_types.py
git commit -m "feat(secrets): add _secrets package with ShushuTarget + SealMetadata types"
```

---

### Task 2: `_seal_plan.py` — `derive_seal_plan` pure function

**Files:**
- Create: `cultureflare/_remote_login/_seal_plan.py`
- Test: `tests/test_remote_login_seal_plan.py`

- [ ] **Step 1: Write the failing test**

`tests/test_remote_login_seal_plan.py`:

```python
"""Tests for cultureflare._remote_login._seal_plan."""

import pytest

from cultureflare._remote_login._seal_plan import SealPlan, derive_seal_plan
from cultureflare._secrets._types import SealMetadata, ShushuTarget
from cultureflare.cli._errors import CfafiError, EXIT_USER_ERROR


def test_disabled_when_arg_is_none():
    p = derive_seal_plan(hostname="app.example.com", shushu_arg=None)
    assert p.enabled is False


def test_enabled_invoking_user_when_arg_is_empty():
    p = derive_seal_plan(hostname="app.example.com", shushu_arg="")
    assert p.enabled is True
    assert p.user is None
    assert p.tunnel_token_target.user is None


def test_enabled_cross_user_when_arg_is_username():
    p = derive_seal_plan(hostname="app.example.com", shushu_arg="alice")
    assert p.enabled is True
    assert p.user == "alice"
    assert p.tunnel_token_target.user == "alice"
    assert p.service_token_secret_target.user == "alice"


def test_slug_uppercases_and_replaces_dots_and_dashes():
    p = derive_seal_plan(hostname="app-svc.example.com", shushu_arg="")
    assert p.tunnel_token_target.name == \
        "CULTUREFLARE_APP_SVC_EXAMPLE_COM_TUNNEL_TOKEN"
    assert p.service_token_secret_target.name == \
        "CULTUREFLARE_APP_SVC_EXAMPLE_COM_SVC_SECRET"


def test_slug_handles_single_label():
    p = derive_seal_plan(hostname="localhost", shushu_arg="")
    assert p.tunnel_token_target.name == \
        "CULTUREFLARE_LOCALHOST_TUNNEL_TOKEN"


def test_metadata_includes_hostname_in_purpose():
    p = derive_seal_plan(hostname="app.example.com", shushu_arg="")
    assert p.metadata.source == "cultureflare/remote-login"
    assert "app.example.com" in p.metadata.purpose
    assert "teardown" in p.metadata.rotate_howto
    assert "setup" in p.metadata.rotate_howto


def test_metadata_rotate_howto_includes_user_when_cross_user():
    p = derive_seal_plan(hostname="app.example.com", shushu_arg="alice")
    assert "--shushu=alice" in p.metadata.rotate_howto


def test_metadata_rotate_howto_uses_bare_shushu_when_self():
    p = derive_seal_plan(hostname="app.example.com", shushu_arg="")
    # bare --shushu (no =USER) for the invoking-user case
    assert "--shushu " in p.metadata.rotate_howto or \
           p.metadata.rotate_howto.endswith("--shushu")
    assert "--shushu=" not in p.metadata.rotate_howto


def test_non_ascii_hostname_raises():
    with pytest.raises(CfafiError) as exc:
        derive_seal_plan(hostname="münich.example.com", shushu_arg="")
    assert exc.value.code == EXIT_USER_ERROR
    assert "ASCII" in exc.value.message


def test_returned_targets_are_immutable():
    p = derive_seal_plan(hostname="app.example.com", shushu_arg="alice")
    assert isinstance(p.tunnel_token_target, ShushuTarget)
    assert isinstance(p.service_token_secret_target, ShushuTarget)
    assert isinstance(p.metadata, SealMetadata)


def test_disabled_plan_still_has_targets():
    # Convenience: when disabled, targets are still computed (helpful
    # for dry-run rendering that wants to show "would seal as ...").
    p = derive_seal_plan(hostname="app.example.com", shushu_arg=None)
    assert p.tunnel_token_target.name == \
        "CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN"
    assert p.user is None
```

- [ ] **Step 2: Run test to verify it fails**

```bash
uv run pytest tests/test_remote_login_seal_plan.py -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'cultureflare._remote_login._seal_plan'`.

- [ ] **Step 3: Create `_seal_plan.py`**

`cultureflare/_remote_login/_seal_plan.py`:

```python
"""Derive shushu target names + metadata from a hostname.

Pure function — no I/O, no subprocess. Safe to call before any CF
API call so dry-run output can render the seal plan without side
effects.
"""

from __future__ import annotations

from dataclasses import dataclass

from cultureflare._secrets._types import SealMetadata, ShushuTarget
from cultureflare.cli._errors import EXIT_USER_ERROR, CfafiError


@dataclass(frozen=True)
class SealPlan:
    """Pre-computed shushu targets + metadata for a remote-login run."""

    enabled: bool
    user: str | None
    tunnel_token_target: ShushuTarget
    service_token_secret_target: ShushuTarget
    metadata: SealMetadata


def _slug(hostname: str) -> str:
    return (
        "CULTUREFLARE_"
        + hostname.upper().replace(".", "_").replace("-", "_")
    )


def _rotate_howto(hostname: str, user: str | None) -> str:
    flag = "--shushu" if user is None else f"--shushu={user}"
    return (
        f"cultureflare remote-login teardown --hostname {hostname} "
        f"{flag} --apply && cultureflare remote-login setup --hostname "
        f"{hostname} {flag} --apply ..."
    )


def derive_seal_plan(*, hostname: str, shushu_arg: str | None) -> SealPlan:
    """Translate the CLI ``--shushu[=USER]`` argument to a SealPlan.

    ``shushu_arg`` semantics:
      * ``None`` — flag not passed (sealed mode disabled).
      * ``""``   — bare ``--shushu`` (sealed mode, invoking user, no sudo).
      * ``"alice"`` — ``--shushu=alice`` (sealed mode, sudo to alice).

    Targets are computed even when ``enabled=False`` so dry-run
    rendering can preview the seal step. Hostname must be ASCII.
    """
    if not hostname.isascii():
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message=f"hostname must be ASCII (got {hostname!r})",
            remediation="use the punycode form for IDN hostnames",
        )

    enabled = shushu_arg is not None
    user = shushu_arg if shushu_arg else None

    slug = _slug(hostname)
    tunnel_target = ShushuTarget(user=user, name=f"{slug}_TUNNEL_TOKEN")
    svc_target = ShushuTarget(user=user, name=f"{slug}_SVC_SECRET")
    metadata = SealMetadata(
        source="cultureflare/remote-login",
        purpose=f"remote-login {hostname}",
        rotate_howto=_rotate_howto(hostname, user),
    )
    return SealPlan(
        enabled=enabled,
        user=user,
        tunnel_token_target=tunnel_target,
        service_token_secret_target=svc_target,
        metadata=metadata,
    )
```

- [ ] **Step 4: Run test to verify it passes**

```bash
uv run pytest tests/test_remote_login_seal_plan.py -v
```

Expected: 10 passed.

- [ ] **Step 5: Commit**

```bash
git add cultureflare/_remote_login/_seal_plan.py \
        tests/test_remote_login_seal_plan.py
git commit -m "feat(remote-login): add derive_seal_plan pure function for shushu target derivation"
```

---

### Task 3: `_shushu_sink.seal` — write a secret via subprocess

**Files:**
- Create: `cultureflare/_secrets/_shushu_sink.py`
- Test: `tests/test_secrets_shushu_sink.py`

- [ ] **Step 1: Write the failing test**

`tests/test_secrets_shushu_sink.py`:

```python
"""Tests for cultureflare._secrets._shushu_sink — subprocess.run mocked."""

import subprocess

import pytest

from cultureflare._secrets._shushu_sink import seal
from cultureflare._secrets._types import SealMetadata, ShushuTarget
from cultureflare.cli._errors import (
    CfafiError, EXIT_API, EXIT_USER_ERROR,
)


_META = SealMetadata(
    source="cultureflare/remote-login",
    purpose="remote-login app.example.com",
    rotate_howto="rotate me",
)


class _FakeRun:
    """Records subprocess.run call args + returns a programmable result."""

    def __init__(self, returncode=0, stderr=b""):
        self.returncode = returncode
        self.stderr = stderr
        self.calls: list[dict] = []

    def __call__(self, argv, **kwargs):
        self.calls.append({"argv": argv, "kwargs": kwargs})
        return subprocess.CompletedProcess(
            args=argv, returncode=self.returncode,
            stdout=b"", stderr=self.stderr,
        )


def test_seal_self_user_argv_no_sudo(monkeypatch):
    fake = _FakeRun(returncode=0)
    monkeypatch.setattr(subprocess, "run", fake)

    seal(
        ShushuTarget(user=None, name="MY_SECRET"),
        b"the-secret",
        _META,
    )

    assert len(fake.calls) == 1
    argv = fake.calls[0]["argv"]
    assert argv[0] == "shushu"
    assert "--user" not in argv
    assert "--hidden" in argv
    assert "set" in argv
    assert "MY_SECRET" in argv
    assert argv[-1] == "-"


def test_seal_cross_user_argv_uses_sudo(monkeypatch):
    fake = _FakeRun(returncode=0)
    monkeypatch.setattr(subprocess, "run", fake)

    seal(
        ShushuTarget(user="alice", name="MY_SECRET"),
        b"the-secret",
        _META,
    )

    argv = fake.calls[0]["argv"]
    assert argv[:2] == ["sudo", "shushu"]
    assert "--user" in argv
    assert argv[argv.index("--user") + 1] == "alice"


def test_seal_passes_metadata_flags(monkeypatch):
    fake = _FakeRun(returncode=0)
    monkeypatch.setattr(subprocess, "run", fake)

    seal(
        ShushuTarget(user=None, name="MY_SECRET"),
        b"x",
        _META,
    )

    argv = fake.calls[0]["argv"]
    src_idx = argv.index("--source")
    assert argv[src_idx + 1] == "cultureflare/remote-login"
    purpose_idx = argv.index("--purpose")
    assert argv[purpose_idx + 1] == "remote-login app.example.com"
    rh_idx = argv.index("--rotate-howto")
    assert argv[rh_idx + 1] == "rotate me"


def test_seal_secret_passed_via_stdin_not_argv(monkeypatch):
    fake = _FakeRun(returncode=0)
    monkeypatch.setattr(subprocess, "run", fake)

    seal(
        ShushuTarget(user=None, name="MY_SECRET"),
        b"super-secret-value",
        _META,
    )

    argv = fake.calls[0]["argv"]
    kwargs = fake.calls[0]["kwargs"]
    assert b"super-secret-value" not in str(argv).encode()
    assert "super-secret-value" not in str(argv)
    assert kwargs.get("input") == b"super-secret-value"


def test_seal_str_secret_raises_typeerror(monkeypatch):
    monkeypatch.setattr(subprocess, "run", _FakeRun())
    with pytest.raises(TypeError, match="bytes"):
        seal(
            ShushuTarget(user=None, name="MY_SECRET"),
            "this-is-a-str",  # type: ignore[arg-type]
            _META,
        )


def test_seal_exit_64_maps_to_user_error(monkeypatch):
    fake = _FakeRun(returncode=64, stderr=b"name already exists")
    monkeypatch.setattr(subprocess, "run", fake)

    with pytest.raises(CfafiError) as exc:
        seal(ShushuTarget(user=None, name="N"), b"x", _META)
    assert exc.value.code == EXIT_USER_ERROR
    assert "already exists" in (exc.value.message + exc.value.remediation).lower() \
        or "shushu" in exc.value.message.lower()


def test_seal_exit_65_maps_to_api(monkeypatch):
    fake = _FakeRun(returncode=65, stderr=b"store corrupt")
    monkeypatch.setattr(subprocess, "run", fake)

    with pytest.raises(CfafiError) as exc:
        seal(ShushuTarget(user=None, name="N"), b"x", _META)
    assert exc.value.code == EXIT_API


def test_seal_exit_66_root_required_maps_to_user_error(monkeypatch):
    fake = _FakeRun(returncode=66, stderr=b"requires root")
    monkeypatch.setattr(subprocess, "run", fake)

    with pytest.raises(CfafiError) as exc:
        seal(ShushuTarget(user="alice", name="N"), b"x", _META)
    assert exc.value.code == EXIT_USER_ERROR
    assert "sudo" in (exc.value.remediation + exc.value.message).lower()


def test_seal_filenotfound_returns_install_remediation(monkeypatch):
    def boom(*a, **kw):
        raise FileNotFoundError(2, "No such file or directory: 'shushu'")
    monkeypatch.setattr(subprocess, "run", boom)

    with pytest.raises(CfafiError) as exc:
        seal(ShushuTarget(user=None, name="N"), b"x", _META)
    assert exc.value.code == EXIT_USER_ERROR
    assert "uv tool install shushu" in exc.value.remediation
```

- [ ] **Step 2: Run test to verify it fails**

```bash
uv run pytest tests/test_secrets_shushu_sink.py -v
```

Expected: FAIL — `cultureflare._secrets._shushu_sink` does not exist.

- [ ] **Step 3: Create `_shushu_sink.py` (seal only — probe/delete in later tasks)**

`cultureflare/_secrets/_shushu_sink.py`:

```python
"""Subprocess adapter for the shushu CLI.

Wraps ``shushu set / show / delete`` so the rest of cultureflare can
deposit secrets without ever touching their values in argv, logs, or
stdout. Secrets are passed as bytes via subprocess stdin only.

Maps shushu's documented exit codes (see shushu's README) to
CfafiError:

  0     → success
  64    → EXIT_USER_ERROR  (bad input, name conflict, hidden refusal)
  65    → EXIT_API         (store corrupt / unreadable)
  66    → EXIT_USER_ERROR  (requires root → use sudo / drop --user)
  67    → EXIT_API         (backend dep failed; e.g. unknown user)
  70    → EXIT_API         (shushu bug)

  FileNotFoundError → EXIT_USER_ERROR with install remediation
"""

from __future__ import annotations

import subprocess

from cultureflare._secrets._types import SealMetadata, ShushuTarget
from cultureflare.cli._errors import (
    EXIT_API, EXIT_USER_ERROR, CfafiError,
)


def _argv_for_set(target: ShushuTarget, meta: SealMetadata) -> list[str]:
    argv: list[str] = []
    if target.user is not None:
        argv.append("sudo")
    argv.extend([
        "shushu", "set", "--hidden",
        "--source", meta.source,
        "--purpose", meta.purpose,
        "--rotate-howto", meta.rotate_howto,
    ])
    if target.user is not None:
        argv.extend(["--user", target.user])
    argv.extend([target.name, "-"])
    return argv


def _map_exit_code(rc: int, stderr: bytes, target: ShushuTarget) -> CfafiError:
    msg = stderr.decode(errors="replace").strip() or f"shushu exit {rc}"
    if rc == 64:
        return CfafiError(
            code=EXIT_USER_ERROR,
            message=f"shushu rejected the request: {msg}",
            remediation=(
                f"`shushu show {target.name}` to inspect; "
                f"`shushu delete {target.name}` then retry to rotate"
            ),
        )
    if rc == 66:
        return CfafiError(
            code=EXIT_USER_ERROR,
            message=f"shushu requires root for cross-user write: {msg}",
            remediation=(
                "re-run cultureflare with sudo, or drop the --shushu=USER "
                "argument to deposit into the invoking user's vault"
            ),
        )
    return CfafiError(
        code=EXIT_API,
        message=f"shushu failed (exit {rc}): {msg}",
        remediation="`shushu doctor` for diagnostics",
    )


def seal(
    target: ShushuTarget,
    secret: bytes,
    meta: SealMetadata,
) -> None:
    """Pipe ``secret`` into ``shushu set --hidden`` for ``target``.

    ``secret`` must be ``bytes`` so a stray ``repr()`` in a traceback
    cannot reveal the value as a string. Passing a ``str`` raises
    ``TypeError`` before any subprocess call.
    """
    if not isinstance(secret, (bytes, bytearray)):
        raise TypeError("secret must be bytes; pass str.encode('utf-8')")

    argv = _argv_for_set(target, meta)
    try:
        result = subprocess.run(
            argv, input=bytes(secret), capture_output=True, check=False,
        )
    except FileNotFoundError as exc:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message="shushu binary not found",
            remediation=(
                "`uv tool install shushu`, or omit --shushu to print "
                "secrets to stdout (insecure)"
            ),
        ) from exc

    if result.returncode != 0:
        raise _map_exit_code(result.returncode, result.stderr, target)
```

- [ ] **Step 4: Run test to verify it passes**

```bash
uv run pytest tests/test_secrets_shushu_sink.py -v
```

Expected: 9 passed.

- [ ] **Step 5: Commit**

```bash
git add cultureflare/_secrets/_shushu_sink.py tests/test_secrets_shushu_sink.py
git commit -m "feat(secrets): add shushu_sink.seal — pipes secret via stdin to shushu set --hidden"
```

---

### Task 4: `_shushu_sink.probe` — read entry metadata

**Files:**
- Modify: `cultureflare/_secrets/_shushu_sink.py`
- Test: `tests/test_secrets_shushu_sink.py` (extend)

- [ ] **Step 1: Add failing tests to `tests/test_secrets_shushu_sink.py`**

Append to the existing test file:

```python
import json

from cultureflare._secrets._shushu_sink import probe


def test_probe_returns_metadata_dict_when_present(monkeypatch):
    payload = {"name": "MY_SECRET", "hidden": True,
               "source": "cultureflare/remote-login"}

    class _Run:
        def __call__(self, argv, **kwargs):
            assert "show" in argv
            assert "--json" in argv
            return subprocess.CompletedProcess(
                args=argv, returncode=0,
                stdout=json.dumps({"ok": True, "result": payload}).encode(),
                stderr=b"",
            )

    monkeypatch.setattr(subprocess, "run", _Run())
    out = probe(ShushuTarget(user=None, name="MY_SECRET"))
    assert out == payload


def test_probe_returns_none_when_record_absent(monkeypatch):
    err = json.dumps({"ok": False,
                      "error": {"code": "NOT_FOUND",
                                "message": "no such record"}}).encode()

    class _Run:
        def __call__(self, argv, **kwargs):
            return subprocess.CompletedProcess(
                args=argv, returncode=64, stdout=err, stderr=b"",
            )

    monkeypatch.setattr(subprocess, "run", _Run())
    out = probe(ShushuTarget(user=None, name="MISSING"))
    assert out is None


def test_probe_uses_sudo_for_cross_user(monkeypatch):
    captured: list[list[str]] = []

    class _Run:
        def __call__(self, argv, **kwargs):
            captured.append(argv)
            return subprocess.CompletedProcess(
                args=argv, returncode=0,
                stdout=b'{"ok": true, "result": {"name": "X"}}',
                stderr=b"",
            )

    monkeypatch.setattr(subprocess, "run", _Run())
    probe(ShushuTarget(user="alice", name="X"))
    assert captured[0][:2] == ["sudo", "shushu"]
    assert "--user" in captured[0]
    assert captured[0][captured[0].index("--user") + 1] == "alice"


def test_probe_other_error_raises(monkeypatch):
    class _Run:
        def __call__(self, argv, **kwargs):
            return subprocess.CompletedProcess(
                args=argv, returncode=65, stdout=b"", stderr=b"corrupt",
            )

    monkeypatch.setattr(subprocess, "run", _Run())
    with pytest.raises(CfafiError) as exc:
        probe(ShushuTarget(user=None, name="X"))
    assert exc.value.code == EXIT_API


def test_probe_filenotfound_raises(monkeypatch):
    def boom(*a, **kw):
        raise FileNotFoundError(2, "No such file: shushu")
    monkeypatch.setattr(subprocess, "run", boom)
    with pytest.raises(CfafiError) as exc:
        probe(ShushuTarget(user=None, name="X"))
    assert exc.value.code == EXIT_USER_ERROR
```

- [ ] **Step 2: Run failing tests**

```bash
uv run pytest tests/test_secrets_shushu_sink.py -v -k probe
```

Expected: FAIL — `probe` not defined.

- [ ] **Step 3: Add `probe` to `_shushu_sink.py`**

Append to `cultureflare/_secrets/_shushu_sink.py`:

```python
import json as _json


def _argv_for_show(target: ShushuTarget) -> list[str]:
    argv: list[str] = []
    if target.user is not None:
        argv.append("sudo")
    argv.extend(["shushu", "show", "--json"])
    if target.user is not None:
        argv.extend(["--user", target.user])
    argv.append(target.name)
    return argv


def probe(target: ShushuTarget) -> dict | None:
    """Return shushu's metadata dict for ``target.name``, or None when absent.

    Hidden entries return metadata with no ``value`` field, which is
    fine — cultureflare only cares about presence + provenance.
    Cross-user goes through sudo. Any non-64 non-zero exit is raised.
    """
    argv = _argv_for_show(target)
    try:
        result = subprocess.run(argv, capture_output=True, check=False)
    except FileNotFoundError as exc:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message="shushu binary not found",
            remediation="`uv tool install shushu`",
        ) from exc

    if result.returncode == 64:
        return None
    if result.returncode != 0:
        raise _map_exit_code(result.returncode, result.stderr, target)

    payload = _json.loads(result.stdout.decode("utf-8"))
    if not payload.get("ok"):
        return None
    return payload.get("result")
```

- [ ] **Step 4: Run all sink tests**

```bash
uv run pytest tests/test_secrets_shushu_sink.py -v
```

Expected: 14 passed (9 + 5 new).

- [ ] **Step 5: Commit**

```bash
git add cultureflare/_secrets/_shushu_sink.py tests/test_secrets_shushu_sink.py
git commit -m "feat(secrets): add shushu_sink.probe — read entry metadata, None on absent"
```

---

### Task 5: `_shushu_sink.delete` — remove an entry

**Files:**
- Modify: `cultureflare/_secrets/_shushu_sink.py`
- Test: `tests/test_secrets_shushu_sink.py` (extend)

- [ ] **Step 1: Add failing tests**

Append to `tests/test_secrets_shushu_sink.py`:

```python
from cultureflare._secrets._shushu_sink import delete


def test_delete_returns_true_on_success(monkeypatch):
    class _Run:
        def __call__(self, argv, **kwargs):
            assert "delete" in argv
            return subprocess.CompletedProcess(
                args=argv, returncode=0, stdout=b"", stderr=b"",
            )
    monkeypatch.setattr(subprocess, "run", _Run())
    assert delete(ShushuTarget(user=None, name="X")) is True


def test_delete_returns_false_when_already_absent(monkeypatch):
    class _Run:
        def __call__(self, argv, **kwargs):
            return subprocess.CompletedProcess(
                args=argv, returncode=64, stdout=b"", stderr=b"no such record",
            )
    monkeypatch.setattr(subprocess, "run", _Run())
    assert delete(ShushuTarget(user=None, name="X")) is False


def test_delete_uses_sudo_for_cross_user(monkeypatch):
    captured: list[list[str]] = []

    class _Run:
        def __call__(self, argv, **kwargs):
            captured.append(argv)
            return subprocess.CompletedProcess(
                args=argv, returncode=0, stdout=b"", stderr=b"",
            )

    monkeypatch.setattr(subprocess, "run", _Run())
    delete(ShushuTarget(user="alice", name="X"))
    assert captured[0][:2] == ["sudo", "shushu"]
    assert "--user" in captured[0]
    assert captured[0][captured[0].index("--user") + 1] == "alice"


def test_delete_other_error_raises(monkeypatch):
    class _Run:
        def __call__(self, argv, **kwargs):
            return subprocess.CompletedProcess(
                args=argv, returncode=70, stdout=b"", stderr=b"shushu bug",
            )
    monkeypatch.setattr(subprocess, "run", _Run())
    with pytest.raises(CfafiError) as exc:
        delete(ShushuTarget(user=None, name="X"))
    assert exc.value.code == EXIT_API
```

- [ ] **Step 2: Run failing tests**

```bash
uv run pytest tests/test_secrets_shushu_sink.py -v -k delete
```

Expected: FAIL — `delete` not defined.

- [ ] **Step 3: Add `delete` to `_shushu_sink.py`**

Append to `cultureflare/_secrets/_shushu_sink.py`:

```python
def _argv_for_delete(target: ShushuTarget) -> list[str]:
    argv: list[str] = []
    if target.user is not None:
        argv.append("sudo")
    argv.extend(["shushu", "delete"])
    if target.user is not None:
        argv.extend(["--user", target.user])
    argv.append(target.name)
    return argv


def delete(target: ShushuTarget) -> bool:
    """Remove ``target.name`` from shushu.

    Returns True on success, False when the record was already absent
    (shushu exit 64). Other non-zero exits raise CfafiError.
    """
    argv = _argv_for_delete(target)
    try:
        result = subprocess.run(argv, capture_output=True, check=False)
    except FileNotFoundError as exc:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message="shushu binary not found",
            remediation="`uv tool install shushu`",
        ) from exc

    if result.returncode == 0:
        return True
    if result.returncode == 64:
        return False
    raise _map_exit_code(result.returncode, result.stderr, target)
```

- [ ] **Step 4: Run all sink tests**

```bash
uv run pytest tests/test_secrets_shushu_sink.py -v
```

Expected: 18 passed (14 + 4 new).

- [ ] **Step 5: Commit**

```bash
git add cultureflare/_secrets/_shushu_sink.py tests/test_secrets_shushu_sink.py
git commit -m "feat(secrets): add shushu_sink.delete — remove entry, False when absent"
```

---

### Task 6: Extend `_common.py` result dataclasses

**Files:**
- Modify: `cultureflare/_remote_login/_common.py`
- Test: `tests/test_remote_login_common.py` (extend)

- [ ] **Step 1: Read current `_common.py` to find the dataclass definitions**

```bash
sed -n '40,140p' cultureflare/_remote_login/_common.py
```

- [ ] **Step 2: Write failing test**

Append to `tests/test_remote_login_common.py`:

```python
from cultureflare._remote_login._common import SetupResult, ShowResult


def test_setup_result_has_sealed_in_default_empty():
    r = SetupResult(
        team_domain="ex.cloudflareaccess.com",
        tunnel_id="t-1", tunnel_name="app-example-com",
        tunnel_token="raw-token",
        dns_record_id="d-1", dns_target="t-1.cfargotunnel.com",
        access_app_id="a-1",
        policy_id="p-1", policy_emails=["x@y"], policy_domains=[],
        service_token_client_id=None, service_token_client_secret=None,
        steps=[],
    )
    assert r.sealed_in == {}


def test_setup_result_accepts_sealed_in():
    r = SetupResult(
        team_domain="ex.cloudflareaccess.com",
        tunnel_id="t-1", tunnel_name="app-example-com",
        tunnel_token=None,
        dns_record_id="d-1", dns_target="t-1.cfargotunnel.com",
        access_app_id="a-1",
        policy_id="p-1", policy_emails=["x@y"], policy_domains=[],
        service_token_client_id="cid", service_token_client_secret=None,
        steps=[],
        sealed_in={
            "tunnel_token": "shushu/alice/CULTUREFLARE_X_TUNNEL_TOKEN",
            "service_token_client_secret": "shushu/alice/CULTUREFLARE_X_SVC_SECRET",
        },
    )
    assert r.tunnel_token is None
    assert r.sealed_in["tunnel_token"].startswith("shushu/alice/")


def test_show_result_has_sealed_in_status_default_empty():
    r = ShowResult(
        team_domain=None, tunnel=None, dns=None,
        access_app=None, policy=None, service_token=None,
    )
    assert r.sealed_in_status == {}
```

- [ ] **Step 3: Run failing test**

```bash
uv run pytest tests/test_remote_login_common.py -v
```

Expected: FAIL — `unexpected keyword argument 'sealed_in'`.

- [ ] **Step 4: Modify `cultureflare/_remote_login/_common.py`**

Find the existing `SetupResult` dataclass and apply two edits:

1. Change `tunnel_token: str` → `tunnel_token: str | None`.
2. Add `sealed_in: dict[str, str] = field(default_factory=dict)` as the last field.

For `ShowResult`, add `sealed_in_status: dict[str, dict | None] = field(default_factory=dict)` as the last field.

Make sure `field` is imported: `from dataclasses import dataclass, field`.

Concretely, the `SetupResult` block becomes:

```python
@dataclass(frozen=True)
class SetupResult:
    team_domain: str | None
    tunnel_id: str
    tunnel_name: str
    tunnel_token: str | None
    dns_record_id: str
    dns_target: str
    access_app_id: str
    policy_id: str
    policy_emails: list[str]
    policy_domains: list[str]
    service_token_client_id: str | None
    service_token_client_secret: str | None
    steps: list["StepRecord"]
    sealed_in: dict[str, str] = field(default_factory=dict)
```

And `ShowResult` becomes:

```python
@dataclass(frozen=True)
class ShowResult:
    team_domain: str | None
    tunnel: dict | None
    dns: dict | None
    access_app: dict | None
    policy: dict | None
    service_token: dict | None
    sealed_in_status: dict[str, dict | None] = field(default_factory=dict)
```

- [ ] **Step 5: Run all tests in `_remote_login`**

```bash
uv run pytest tests/test_remote_login_common.py tests/test_remote_login_orchestrator.py -v
```

Expected: existing tests still pass (defaults preserve behavior); 3 new tests pass.

- [ ] **Step 6: Commit**

```bash
git add cultureflare/_remote_login/_common.py tests/test_remote_login_common.py
git commit -m "feat(remote-login): add sealed_in fields to SetupResult and ShowResult"
```

---

### Task 7: Extend `_render.py` for sealed markers

**Files:**
- Modify: `cultureflare/_remote_login/_render.py`
- Test: `tests/test_remote_login_render.py` (extend)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_remote_login_render.py`:

```python
from cultureflare._remote_login._render import (
    render_setup_markdown, render_setup_json,
    render_show_markdown,
)
from cultureflare._remote_login._common import (
    SetupResult, ShowResult, StepRecord,
)


def _sealed_setup_result():
    return SetupResult(
        team_domain="ex.cloudflareaccess.com",
        tunnel_id="t-1",
        tunnel_name="app-example-com",
        tunnel_token=None,
        dns_record_id="d-1",
        dns_target="t-1.cfargotunnel.com",
        access_app_id="a-1",
        policy_id="p-1",
        policy_emails=["ori@example.com"],
        policy_domains=[],
        service_token_client_id="cid-1",
        service_token_client_secret=None,
        steps=[],
        sealed_in={
            "tunnel_token":
                "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN",
            "service_token_client_secret":
                "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET",
        },
    )


def test_setup_markdown_renders_sealed_marker_for_tunnel_token():
    md = render_setup_markdown(_sealed_setup_result(), hostname="app.example.com")
    assert "<sealed: shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN>" in md
    # raw value never appears (we never had one)
    assert "raw-token" not in md


def test_setup_markdown_renders_sealed_marker_for_service_token_secret():
    md = render_setup_markdown(_sealed_setup_result(), hostname="app.example.com")
    assert "<sealed: shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET>" in md


def test_setup_json_value_fields_are_null_when_sealed():
    js = render_setup_json(_sealed_setup_result(), hostname="app.example.com")
    assert js["result"]["tunnel_token"] is None
    assert js["result"]["service_token_client_secret"] is None
    assert js["result"]["sealed_in"] == {
        "tunnel_token":
            "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN",
        "service_token_client_secret":
            "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET",
    }


def test_show_markdown_renders_sealed_in_lines():
    r = ShowResult(
        team_domain="ex.cloudflareaccess.com",
        tunnel={"id": "t-1", "name": "app-example-com"},
        dns={"id": "d-1", "name": "app.example.com",
             "content": "t-1.cfargotunnel.com", "proxied": True},
        access_app={"id": "a-1"},
        policy={"id": "p-1"},
        service_token={"id": "st-1", "name": "app.example.com-svc",
                        "client_id": "cid-1"},
        sealed_in_status={
            "tunnel_token":
                {"present": True,
                 "name":
                     "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN",
                 "source": "cultureflare/remote-login"},
            "service_token_client_secret":
                {"present": False,
                 "name":
                     "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET",
                 "source": None},
        },
    )
    md = render_show_markdown(r, hostname="app.example.com")
    assert "**sealed-in:**" in md
    assert "tunnel_token" in md
    assert "present" in md
    assert "absent" in md


def test_setup_markdown_unchanged_when_no_seal():
    # When sealed_in is empty, output must equal pre-feature output:
    # the tunnel-token row holds the raw value.
    r = SetupResult(
        team_domain="ex.cloudflareaccess.com",
        tunnel_id="t-1", tunnel_name="app-example-com",
        tunnel_token="visible-raw-token",
        dns_record_id="d-1", dns_target="t-1.cfargotunnel.com",
        access_app_id="a-1",
        policy_id="p-1", policy_emails=["x@y"], policy_domains=[],
        service_token_client_id=None, service_token_client_secret=None,
        steps=[],
    )
    md = render_setup_markdown(r, hostname="app.example.com")
    assert "visible-raw-token" in md
    assert "<sealed:" not in md
```

- [ ] **Step 2: Run failing tests**

```bash
uv run pytest tests/test_remote_login_render.py -v
```

Expected: FAIL on the new tests (sealed markers not yet rendered).

- [ ] **Step 3: Modify `cultureflare/_remote_login/_render.py`**

In `render_setup_markdown`, replace the line that emits `TUNNEL_TOKEN`:

```python
    # Old:
    # lines.append(f"- **TUNNEL_TOKEN:** {result.tunnel_token}")

    # New:
    if "tunnel_token" in result.sealed_in:
        lines.append(
            f"- **TUNNEL_TOKEN:** <sealed: {result.sealed_in['tunnel_token']}>"
        )
    else:
        lines.append(f"- **TUNNEL_TOKEN:** {result.tunnel_token}")
```

And the line that emits `SERVICE_TOKEN_CLIENT_SECRET` (find the existing block — it currently looks like `lines.append(f"- **SERVICE_TOKEN_CLIENT_SECRET:** {result.service_token_client_secret}")` inside the `if result.service_token_client_id is not None:` block):

```python
    if result.service_token_client_id is not None:
        lines.append(
            f"- **SERVICE_TOKEN_CLIENT_ID:** {result.service_token_client_id}"
        )
        if "service_token_client_secret" in result.sealed_in:
            lines.append(
                f"- **SERVICE_TOKEN_CLIENT_SECRET:** "
                f"<sealed: {result.sealed_in['service_token_client_secret']}>"
            )
        else:
            lines.append(
                f"- **SERVICE_TOKEN_CLIENT_SECRET:** "
                f"{result.service_token_client_secret}"
            )
```

For `render_setup_json`, locate the dict construction (currently builds `{"tunnel_token": result.tunnel_token, ...}`) and add `sealed_in` to it. The `tunnel_token` field already passes through `None` correctly when sealed; we just need the new `sealed_in` block:

```python
    payload = {
        "success": True, "errors": [], "messages": [],
        "result": {
            # ... existing keys ...
            "tunnel_token": result.tunnel_token,
            # ... existing keys ...
            "service_token_client_secret": result.service_token_client_secret,
            "sealed_in": dict(result.sealed_in),
            # ... existing keys ...
        },
    }
```

For `render_show_markdown`, after the existing `service-token` line, add:

```python
    if result.sealed_in_status:
        lines.append("- **sealed-in:**")
        for key, status in result.sealed_in_status.items():
            if status is None:
                lines.append(f"  - {key}: ?? (shushu not installed)")
                continue
            state = "present" if status.get("present") else "absent"
            src = status.get("source")
            tail = f" (source: {src})" if src else ""
            lines.append(f"  - {key}: {status.get('name')} — {state}{tail}")
```

- [ ] **Step 4: Run all render tests**

```bash
uv run pytest tests/test_remote_login_render.py -v
```

Expected: all existing + 5 new pass.

- [ ] **Step 5: Commit**

```bash
git add cultureflare/_remote_login/_render.py tests/test_remote_login_render.py
git commit -m "feat(remote-login): render <sealed: ...> markers when sealed_in is set"
```

---

### Task 8: Wire `setup()` to call `seal` for both secrets

**Files:**
- Modify: `cultureflare/_remote_login/__init__.py`
- Test: `tests/test_remote_login_orchestrator.py` (extend)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_remote_login_orchestrator.py`:

```python
from cultureflare._remote_login._seal_plan import derive_seal_plan
from cultureflare._secrets._types import ShushuTarget


def test_setup_with_seal_calls_sink_twice_with_correct_targets(
    http_stub, monkeypatch,
):
    # Program CF stubs as the existing setup-happy-path test does;
    # see test_setup_happy_path for the canonical fixture set.
    _program_setup_happy_path(http_stub)

    seal_calls: list[tuple[ShushuTarget, bytes]] = []

    def fake_seal(target, secret, meta):
        seal_calls.append((target, bytes(secret)))

    monkeypatch.setattr(
        "cultureflare._remote_login._shushu_sink.seal", fake_seal
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="alice")
    ctx = _ctx_for("app.example.com")
    result = setup(
        ctx=ctx, emails=["x@y"], domains=[],
        with_service_token=True, session_duration="24h",
        seal=plan,
    )

    assert len(seal_calls) == 2
    targets = [c[0].name for c in seal_calls]
    assert "CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN" in targets
    assert "CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET" in targets
    # All targets routed to the cross-user vault
    assert all(c[0].user == "alice" for c in seal_calls)
    # Result fields are sealed
    assert result.tunnel_token is None
    assert result.service_token_client_secret is None
    assert result.sealed_in["tunnel_token"] == \
        "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN"
    assert result.sealed_in["service_token_client_secret"] == \
        "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET"


def test_setup_with_seal_partial_failure_raises_rotate_remediation(
    http_stub, monkeypatch,
):
    _program_setup_happy_path(http_stub)

    state = {"calls": 0}

    def fake_seal(target, secret, meta):
        state["calls"] += 1
        if state["calls"] == 2:
            raise CfafiError(
                code=EXIT_API,
                message="shushu store unreadable",
                remediation="shushu doctor",
            )

    monkeypatch.setattr(
        "cultureflare._remote_login._shushu_sink.seal", fake_seal
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="")
    ctx = _ctx_for("app.example.com")
    with pytest.raises(CfafiError) as exc:
        setup(
            ctx=ctx, emails=["x@y"], domains=[],
            with_service_token=True, session_duration="24h",
            seal=plan,
        )
    assert exc.value.code == EXIT_API
    assert "rotate" in (exc.value.remediation + exc.value.message).lower()
    assert "teardown" in exc.value.remediation


def test_setup_without_seal_returns_secrets_in_clear(http_stub):
    # Regression guard: --shushu opt-in. Default behaviour
    # unchanged.
    _program_setup_happy_path(http_stub)
    plan = derive_seal_plan(hostname="app.example.com", shushu_arg=None)
    ctx = _ctx_for("app.example.com")
    result = setup(
        ctx=ctx, emails=["x@y"], domains=[],
        with_service_token=True, session_duration="24h",
        seal=plan,
    )
    assert result.tunnel_token is not None
    assert result.tunnel_token != ""
    assert result.service_token_client_secret is not None
    assert result.sealed_in == {}
```

> Note for the implementer: `_program_setup_happy_path` and `_ctx_for` are
> already used by the existing setup-happy-path test in
> `test_remote_login_orchestrator.py` (look for the fixture-stub pattern
> a few tests up in the same file). Reuse them directly. If they aren't
> module-level helpers in the existing file, lift the inline programming
> into a top-level helper before adding these tests so all three new
> tests share the same baseline.

- [ ] **Step 2: Run failing tests**

```bash
uv run pytest tests/test_remote_login_orchestrator.py -v -k seal
```

Expected: FAIL — `setup()` doesn't accept `seal=`.

- [ ] **Step 3: Modify `cultureflare/_remote_login/__init__.py`**

Add to imports:

```python
from cultureflare._remote_login._seal_plan import SealPlan, derive_seal_plan
from cultureflare._secrets import _shushu_sink
```

Change `setup` signature and body:

```python
def setup(
    *,
    ctx: Context,
    emails: list[str],
    domains: list[str],
    with_service_token: bool,
    session_duration: str,
    seal: SealPlan | None = None,
) -> SetupResult:
    if seal is None:
        seal = derive_seal_plan(hostname=ctx.hostname, shushu_arg=None)

    # ... existing CF-side logic unchanged through step 6 ...

    # NEW: after step 6 (service-token mint), seal both secrets.
    sealed_in: dict[str, str] = {}
    if seal.enabled:
        # Order: tunnel first, service-token second. If the second
        # fails, the first is already in shushu — teardown will pick
        # it up. The service-token secret is one-shot from CF; if we
        # fail to seal it, it is lost and must be rotated.
        try:
            _shushu_sink.seal(
                seal.tunnel_token_target,
                tunnel_token.encode("utf-8"),
                seal.metadata,
            )
            sealed_in["tunnel_token"] = (
                f"shushu/{seal.user or _whoami()}/"
                f"{seal.tunnel_token_target.name}"
            )
            tunnel_token = None  # type: ignore[assignment]
        except CfafiError:
            raise

        if with_service_token and svc_secret is not None:
            try:
                _shushu_sink.seal(
                    seal.service_token_secret_target,
                    svc_secret.encode("utf-8"),
                    seal.metadata,
                )
                sealed_in["service_token_client_secret"] = (
                    f"shushu/{seal.user or _whoami()}/"
                    f"{seal.service_token_secret_target.name}"
                )
                svc_secret = None  # type: ignore[assignment]
            except CfafiError as exc:
                raise CfafiError(
                    code=exc.code,
                    message=(
                        "partial seal — tunnel-token stored, "
                        f"service-token secret failed: {exc.message}"
                    ),
                    remediation=(
                        f"cultureflare remote-login teardown "
                        f"--hostname {ctx.hostname} "
                        f"--shushu{'=' + seal.user if seal.user else ''} "
                        "--apply, then re-run setup; the service-token "
                        "secret was one-shot and must be rotated."
                    ),
                ) from exc

    return SetupResult(
        # ... existing fields ...
        tunnel_token=tunnel_token,
        # ...
        service_token_client_secret=svc_secret,
        steps=steps,
        sealed_in=sealed_in,
    )
```

Add a small helper at module bottom (or in `_common.py` if you prefer):

```python
def _whoami() -> str:
    """OS username for sealed_in path rendering when --shushu (self).

    Used only for the user-facing marker string. Failure to resolve
    (very rare on Linux) falls back to literal '-' to avoid a crash."""
    import getpass
    try:
        return getpass.getuser()
    except Exception:
        return "-"
```

- [ ] **Step 4: Run orchestrator tests**

```bash
uv run pytest tests/test_remote_login_orchestrator.py -v
```

Expected: all existing + 3 new pass.

- [ ] **Step 5: Commit**

```bash
git add cultureflare/_remote_login/__init__.py \
        tests/test_remote_login_orchestrator.py
git commit -m "feat(remote-login): wire setup() to seal tunnel_token + service_token via shushu"
```

---

### Task 9: Wire `show()` to probe shushu

**Files:**
- Modify: `cultureflare/_remote_login/__init__.py::show`
- Test: `tests/test_remote_login_orchestrator.py` (extend)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_remote_login_orchestrator.py`:

```python
def test_show_with_seal_probes_both_targets(http_stub, monkeypatch):
    _program_show_happy_path(http_stub)

    probed: list[ShushuTarget] = []

    def fake_probe(target):
        probed.append(target)
        if target.name.endswith("_TUNNEL_TOKEN"):
            return {"name": target.name, "hidden": True,
                    "source": "cultureflare/remote-login"}
        return None

    monkeypatch.setattr(
        "cultureflare._remote_login._shushu_sink.probe", fake_probe
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="alice")
    ctx = _ctx_for("app.example.com")
    result = show(ctx=ctx, seal=plan)

    assert len(probed) == 2
    assert result.sealed_in_status["tunnel_token"]["present"] is True
    assert result.sealed_in_status["service_token_client_secret"]["present"] is False


def test_show_without_seal_does_not_probe(http_stub, monkeypatch):
    _program_show_happy_path(http_stub)

    def fake_probe(target):
        raise AssertionError("must not probe when seal disabled")

    monkeypatch.setattr(
        "cultureflare._remote_login._shushu_sink.probe", fake_probe
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg=None)
    ctx = _ctx_for("app.example.com")
    result = show(ctx=ctx, seal=plan)
    assert result.sealed_in_status == {}


def test_show_with_seal_handles_shushu_missing(http_stub, monkeypatch):
    _program_show_happy_path(http_stub)

    def fake_probe(target):
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message="shushu binary not found",
            remediation="uv tool install shushu",
        )

    monkeypatch.setattr(
        "cultureflare._remote_login._shushu_sink.probe", fake_probe
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="")
    ctx = _ctx_for("app.example.com")
    result = show(ctx=ctx, seal=plan)
    # show is non-fatal: render None for each entry
    assert result.sealed_in_status["tunnel_token"] is None
    assert result.sealed_in_status["service_token_client_secret"] is None
```

> Note: `_program_show_happy_path` mirrors `_program_setup_happy_path`
> for the show endpoints. If it does not exist as a helper yet, add it
> alongside `_program_setup_happy_path` first, then write these tests.

- [ ] **Step 2: Run failing tests**

```bash
uv run pytest tests/test_remote_login_orchestrator.py -v -k 'show and seal'
```

Expected: FAIL — `show` doesn't accept `seal=`.

- [ ] **Step 3: Modify `show()` in `cultureflare/_remote_login/__init__.py`**

```python
def show(*, ctx: Context, seal: SealPlan | None = None) -> ShowResult:
    if seal is None:
        seal = derive_seal_plan(hostname=ctx.hostname, shushu_arg=None)

    # ... existing CF-side probes ...

    sealed_status: dict[str, dict | None] = {}
    if seal.enabled:
        for key, target in (
            ("tunnel_token", seal.tunnel_token_target),
            ("service_token_client_secret", seal.service_token_secret_target),
        ):
            try:
                meta = _shushu_sink.probe(target)
            except CfafiError as exc:
                if "not found" in exc.message.lower():
                    sealed_status[key] = None
                    continue
                raise
            if meta is None:
                sealed_status[key] = {
                    "present": False,
                    "name": f"shushu/{seal.user or _whoami()}/{target.name}",
                    "source": None,
                }
            else:
                sealed_status[key] = {
                    "present": True,
                    "name": f"shushu/{seal.user or _whoami()}/{target.name}",
                    "source": meta.get("source"),
                }

    return ShowResult(
        # ... existing fields ...
        sealed_in_status=sealed_status,
    )
```

- [ ] **Step 4: Run tests**

```bash
uv run pytest tests/test_remote_login_orchestrator.py -v -k show
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add cultureflare/_remote_login/__init__.py \
        tests/test_remote_login_orchestrator.py
git commit -m "feat(remote-login): wire show() to probe shushu when --shushu is set"
```

---

### Task 10: Wire `teardown()` to delete shushu entries

**Files:**
- Modify: `cultureflare/_remote_login/__init__.py::teardown`
- Test: `tests/test_remote_login_orchestrator.py` (extend)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_remote_login_orchestrator.py`:

```python
def test_teardown_with_seal_deletes_both_entries(http_stub, monkeypatch):
    _program_teardown_happy_path(http_stub)

    deleted: list[ShushuTarget] = []

    def fake_delete(target):
        deleted.append(target)
        return True

    monkeypatch.setattr(
        "cultureflare._remote_login._shushu_sink.delete", fake_delete
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="alice")
    ctx = _ctx_for("app.example.com")
    result = teardown(ctx=ctx, keep_tunnel=False, seal=plan)

    names = [t.name for t in deleted]
    assert "CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN" in names
    assert "CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET" in names
    # Steps include deletion records
    seal_steps = [s for s in result.steps if "shushu" in s.name]
    assert len(seal_steps) == 2


def test_teardown_with_seal_records_failed_delete_but_does_not_abort(
    http_stub, monkeypatch,
):
    _program_teardown_happy_path(http_stub)

    def fake_delete(target):
        if target.name.endswith("_SVC_SECRET"):
            raise CfafiError(
                code=EXIT_API, message="shushu store unreadable",
                remediation="shushu doctor",
            )
        return True

    monkeypatch.setattr(
        "cultureflare._remote_login._shushu_sink.delete", fake_delete
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="")
    ctx = _ctx_for("app.example.com")
    result = teardown(ctx=ctx, keep_tunnel=False, seal=plan)

    # CF resources are gone, both shushu actions are recorded as
    # steps (one ok, one failed).
    actions = {s.name: s.action for s in result.steps if "shushu" in s.name}
    assert actions == {
        "shushu-tunnel-token": "deleted",
        "shushu-svc-secret": "delete-failed",
    }


def test_teardown_without_seal_does_not_call_delete(http_stub, monkeypatch):
    _program_teardown_happy_path(http_stub)

    def fake_delete(target):
        raise AssertionError("must not delete when seal disabled")

    monkeypatch.setattr(
        "cultureflare._remote_login._shushu_sink.delete", fake_delete
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg=None)
    ctx = _ctx_for("app.example.com")
    teardown(ctx=ctx, keep_tunnel=False, seal=plan)
```

- [ ] **Step 2: Run failing tests**

```bash
uv run pytest tests/test_remote_login_orchestrator.py -v -k 'teardown and seal'
```

Expected: FAIL — `teardown` doesn't accept `seal=`.

- [ ] **Step 3: Modify `teardown()` in `cultureflare/_remote_login/__init__.py`**

```python
def teardown(
    *,
    ctx: Context,
    keep_tunnel: bool,
    seal: SealPlan | None = None,
) -> TeardownResult:
    if seal is None:
        seal = derive_seal_plan(hostname=ctx.hostname, shushu_arg=None)

    # ... existing CF-side deletion logic unchanged ...

    if seal.enabled:
        for step_name, target in (
            ("shushu-tunnel-token", seal.tunnel_token_target),
            ("shushu-svc-secret", seal.service_token_secret_target),
        ):
            try:
                ok = _shushu_sink.delete(target)
                steps.append(StepRecord(
                    name=step_name,
                    action="deleted" if ok else "skipped",
                    detail=target.name,
                ))
            except CfafiError as exc:
                steps.append(StepRecord(
                    name=step_name,
                    action="delete-failed",
                    detail=f"{target.name}: {exc.message}",
                ))

    return TeardownResult(steps=steps)
```

- [ ] **Step 4: Run tests**

```bash
uv run pytest tests/test_remote_login_orchestrator.py -v -k teardown
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add cultureflare/_remote_login/__init__.py \
        tests/test_remote_login_orchestrator.py
git commit -m "feat(remote-login): wire teardown() to delete shushu entries when --shushu is set"
```

---

### Task 11: CLI argparse — add `--shushu[=USER]` flag

**Files:**
- Modify: `cultureflare/cli/_commands/remote_login.py`
- Test: `tests/test_cli_remote_login.py` (extend)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_cli_remote_login.py`:

```python
def test_setup_argparse_accepts_no_shushu_flag(remote_login_parser):
    args = remote_login_parser.parse_args([
        "setup", "--hostname", "app.example.com", "--allow", "x@y",
    ])
    assert args.shushu is None


def test_setup_argparse_bare_shushu_yields_empty_string(remote_login_parser):
    args = remote_login_parser.parse_args([
        "setup", "--hostname", "app.example.com",
        "--allow", "x@y", "--shushu",
    ])
    assert args.shushu == ""


def test_setup_argparse_shushu_with_user(remote_login_parser):
    args = remote_login_parser.parse_args([
        "setup", "--hostname", "app.example.com",
        "--allow", "x@y", "--shushu=alice",
    ])
    assert args.shushu == "alice"


def test_show_argparse_accepts_shushu(remote_login_parser):
    args = remote_login_parser.parse_args([
        "show", "--hostname", "app.example.com", "--shushu=alice",
    ])
    assert args.shushu == "alice"


def test_teardown_argparse_accepts_shushu(remote_login_parser):
    args = remote_login_parser.parse_args([
        "teardown", "--hostname", "app.example.com", "--shushu",
    ])
    assert args.shushu == ""
```

> The `remote_login_parser` fixture should already exist — it returns
> the `argparse.ArgumentParser` after the remote-login subcommands are
> attached. If not, add a fixture in `tests/conftest.py` or
> `tests/test_cli_remote_login.py` that imports the CLI builder
> directly.

- [ ] **Step 2: Run failing tests**

```bash
uv run pytest tests/test_cli_remote_login.py -v -k shushu
```

Expected: FAIL — `args.shushu` does not exist.

- [ ] **Step 3: Modify `cultureflare/cli/_commands/remote_login.py`**

Find the function that builds the `setup` subparser (look for
`add_argument("--with-service-token", ...)` — they're added together).
Add for **all three subcommands** (`setup`, `show`, `teardown`):

```python
sub.add_argument(
    "--shushu",
    nargs="?", const="", default=None, metavar="USER",
    help=(
        "seal tunnel_token + service_token client_secret into shushu "
        "instead of printing them. Bare --shushu = invoking user; "
        "--shushu=USER deposits into another user's vault via sudo. "
        "When set, value fields render as <sealed: shushu/USER/NAME> "
        "markers."
    ),
)
```

Then in `cmd_setup`, `cmd_show`, `cmd_teardown`, build the seal plan
from `args.shushu` and thread it through:

```python
from cultureflare._remote_login._seal_plan import derive_seal_plan

def cmd_setup(args):
    # ... existing checks ...
    seal = derive_seal_plan(hostname=args.hostname, shushu_arg=args.shushu)
    # ... existing dry-run branch (extend in next task) ...
    # ... existing apply branch:
    result = setup(
        ctx=ctx, emails=list(args.allow), domains=list(args.allow_domain),
        with_service_token=args.with_service_token,
        session_duration=args.session_duration,
        seal=seal,
    )
    # ... rest unchanged ...

def cmd_show(args):
    # ...
    seal = derive_seal_plan(hostname=args.hostname, shushu_arg=args.shushu)
    result = show(ctx=ctx, seal=seal)
    # ...

def cmd_teardown(args):
    # ...
    seal = derive_seal_plan(hostname=args.hostname, shushu_arg=args.shushu)
    # only run on apply, same as today:
    result = teardown(ctx=ctx, keep_tunnel=args.keep_tunnel, seal=seal)
    # ...
```

- [ ] **Step 4: Run all CLI tests**

```bash
uv run pytest tests/test_cli_remote_login.py -v
```

Expected: all existing + 5 new pass.

- [ ] **Step 5: Commit**

```bash
git add cultureflare/cli/_commands/remote_login.py \
        tests/test_cli_remote_login.py
git commit -m "feat(cli): add --shushu[=USER] flag to remote-login setup/show/teardown"
```

---

### Task 12: Dry-run plan output includes seal steps

**Files:**
- Modify: `cultureflare/_remote_login/_render.py::render_setup_dryrun_markdown`
- Modify: `cultureflare/cli/_commands/remote_login.py::cmd_setup` (JSON dry-run path)
- Test: `tests/test_remote_login_render.py` (extend)
- Test: `tests/test_cli_remote_login.py` (extend)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_remote_login_render.py`:

```python
from cultureflare._remote_login._render import render_setup_dryrun_markdown


def test_dryrun_markdown_lists_seal_steps_when_shushu_set():
    md = render_setup_dryrun_markdown(
        hostname="app.example.com",
        tunnel_name="app-example-com",
        app_name="app.example.com",
        emails=["x@y"], domains=[],
        with_service_token=True,
        session_duration="24h",
        seal_user="alice",
        seal_tunnel_name="CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN",
        seal_svc_name="CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET",
    )
    assert "seal tunnel_token" in md
    assert "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN" in md
    assert "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET" in md


def test_dryrun_markdown_omits_seal_when_shushu_unset():
    md = render_setup_dryrun_markdown(
        hostname="app.example.com",
        tunnel_name="app-example-com",
        app_name="app.example.com",
        emails=["x@y"], domains=[],
        with_service_token=True,
        session_duration="24h",
        seal_user=None,
        seal_tunnel_name=None,
        seal_svc_name=None,
    )
    assert "seal" not in md.lower()
```

- [ ] **Step 2: Run failing tests**

```bash
uv run pytest tests/test_remote_login_render.py -v -k dryrun
```

Expected: FAIL — function doesn't accept seal-related kwargs.

- [ ] **Step 3: Extend `render_setup_dryrun_markdown` signature + body**

In `cultureflare/_remote_login/_render.py`, add three keyword-only
params and append seal steps when set:

```python
def render_setup_dryrun_markdown(
    *,
    hostname: str,
    tunnel_name: str,
    app_name: str,
    emails: list[str],
    domains: list[str],
    with_service_token: bool,
    session_duration: str,
    seal_user: str | None = None,
    seal_tunnel_name: str | None = None,
    seal_svc_name: str | None = None,
) -> str:
    # ... existing body ...
    if seal_tunnel_name is not None:
        u = seal_user or "<self>"
        lines.append(f"7. seal tunnel_token into shushu/{u}/{seal_tunnel_name}")
        if with_service_token and seal_svc_name is not None:
            lines.append(
                f"8. seal service-token client_secret into shushu/{u}/{seal_svc_name}"
            )
    # ... rest unchanged ...
    return "\n".join(lines)
```

- [ ] **Step 4: Update `cmd_setup` dry-run branch to pass seal kwargs + add a CLI test**

In `cultureflare/cli/_commands/remote_login.py`, dry-run branch:

```python
seal = derive_seal_plan(hostname=args.hostname, shushu_arg=args.shushu)
seal_user_for_render = (
    seal.user if seal.enabled and seal.user else
    (None if not seal.enabled else _whoami_for_marker())
)
# ...
emit_result(render_setup_dryrun_markdown(
    hostname=args.hostname,
    tunnel_name=ctx.names.tunnel_name,
    app_name=ctx.names.app_name,
    emails=list(args.allow), domains=list(args.allow_domain),
    with_service_token=args.with_service_token,
    session_duration=args.session_duration,
    seal_user=seal.user if seal.enabled else None,
    seal_tunnel_name=
        seal.tunnel_token_target.name if seal.enabled else None,
    seal_svc_name=
        seal.service_token_secret_target.name if seal.enabled else None,
))
```

Add a CLI integration test in `tests/test_cli_remote_login.py`:

```python
def test_cmd_setup_dryrun_with_shushu_lists_seal_steps(capsys, monkeypatch):
    monkeypatch.setenv("CLOUDFLARE_API_TOKEN", "tok")
    monkeypatch.setenv("CLOUDFLARE_ACCOUNT_ID", "acc-1")
    # Stub the zone resolver and token-alive check; the dry-run path
    # does not hit CF for setup itself but does call check_token_alive.
    monkeypatch.setattr(
        "cultureflare._remote_login._preflight.check_token_alive",
        lambda: None,
    )
    monkeypatch.setattr(
        "cultureflare._remote_login._common.resolve_zone",
        lambda hostname: ("zone-1", "example.com"),
    )

    ns = argparse.Namespace(
        hostname="app.example.com", allow=["x@y"], allow_domain=[],
        with_service_token=True, session_duration="24h",
        tunnel_name=None, app_name=None, service_token_name=None,
        json=False, apply=False, shushu="alice",
    )
    cmd_setup(ns)
    out = capsys.readouterr().out
    assert "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN" in out
    assert "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET" in out
```

- [ ] **Step 5: Run all dryrun tests**

```bash
uv run pytest tests/test_remote_login_render.py tests/test_cli_remote_login.py -v -k dryrun
```

Expected: 3 passed.

- [ ] **Step 6: Commit**

```bash
git add cultureflare/_remote_login/_render.py \
        cultureflare/cli/_commands/remote_login.py \
        tests/test_remote_login_render.py tests/test_cli_remote_login.py
git commit -m "feat(remote-login): include seal steps in dry-run output when --shushu is set"
```

---

### Task 13: Back-compat shim — alias `cfafi._secrets.*` and `cfafi._remote_login._seal_plan`

**Files:**
- Modify: `cfafi/__init__.py`
- Test: `tests/test_back_compat.py` (extend)

- [ ] **Step 1: Write failing tests**

Append to `tests/test_back_compat.py`:

```python
def test_cfafi_secrets_types_aliased_to_cultureflare():
    import cfafi._secrets._types as legacy
    import cultureflare._secrets._types as canonical
    assert legacy is canonical
    assert legacy.ShushuTarget is canonical.ShushuTarget


def test_cfafi_secrets_shushu_sink_aliased():
    import cfafi._secrets._shushu_sink as legacy
    import cultureflare._secrets._shushu_sink as canonical
    assert legacy is canonical


def test_cfafi_remote_login_seal_plan_aliased():
    from cfafi._remote_login._seal_plan import derive_seal_plan as legacy
    from cultureflare._remote_login._seal_plan import derive_seal_plan as canonical
    assert legacy is canonical


def test_setup_without_shushu_flag_returns_secrets_in_clear():
    """Regression guard: opt-in only. Default never seals."""
    from cultureflare._remote_login._seal_plan import derive_seal_plan
    plan = derive_seal_plan(hostname="app.example.com", shushu_arg=None)
    assert plan.enabled is False
```

- [ ] **Step 2: Run failing tests**

```bash
uv run pytest tests/test_back_compat.py -v -k secrets
```

Expected: FAIL — `cfafi._secrets` does not exist.

- [ ] **Step 3: Modify `cfafi/__init__.py`**

Locate the eager-import block and add three lines:

```python
import cultureflare._secrets  # noqa: F401
import cultureflare._secrets._shushu_sink  # noqa: F401
import cultureflare._secrets._types  # noqa: F401
import cultureflare._remote_login._seal_plan  # noqa: F401
```

The existing `for _name, _mod in list(_sys.modules.items()): ...` loop
picks them up automatically — no other change needed.

- [ ] **Step 4: Run all back-compat tests**

```bash
uv run pytest tests/test_back_compat.py -v
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add cfafi/__init__.py tests/test_back_compat.py
git commit -m "fix(cfafi-shim): alias cultureflare._secrets and _seal_plan into cfafi.*"
```

---

### Task 14: Gated integration test against the real shushu binary

**Files:**
- Create: `tests/test_secrets_shushu_integration.py`

- [ ] **Step 1: Write the test (skip-by-default)**

`tests/test_secrets_shushu_integration.py`:

```python
"""Integration tests against the real shushu binary.

Skipped unless ``SHUSHU_INTEGRATION=1`` and ``shushu`` is on PATH.
The test owns the lifecycle of one entry name per test function so
parallel runs don't collide."""

import os
import shutil
import subprocess
import uuid

import pytest

from cultureflare._secrets._shushu_sink import delete, probe, seal
from cultureflare._secrets._types import SealMetadata, ShushuTarget


pytestmark = pytest.mark.skipif(
    os.environ.get("SHUSHU_INTEGRATION") != "1"
    or shutil.which("shushu") is None,
    reason="set SHUSHU_INTEGRATION=1 and install shushu to run",
)


_META = SealMetadata(
    source="cultureflare/remote-login",
    purpose="integration test",
    rotate_howto="not for production",
)


@pytest.fixture
def unique_name():
    name = f"CULTUREFLARE_TEST_{uuid.uuid4().hex.upper()}"
    yield name
    # best-effort cleanup
    delete(ShushuTarget(user=None, name=name))


def test_round_trip_seal_and_run_inject(unique_name):
    secret = b"the-quick-brown-fox-9382"
    seal(ShushuTarget(user=None, name=unique_name), secret, _META)

    # probe returns metadata without value
    meta = probe(ShushuTarget(user=None, name=unique_name))
    assert meta is not None
    assert meta.get("hidden") is True
    assert meta.get("value") is None or "value" not in meta

    # consume via run --inject; capture the injected env var
    out = subprocess.run(
        ["shushu", "run", "--inject", f"S={unique_name}",
         "--", "bash", "-c", "printf %s \"$S\""],
        capture_output=True, check=True,
    )
    assert out.stdout == secret


def test_delete_removes_entry(unique_name):
    seal(ShushuTarget(user=None, name=unique_name), b"x", _META)
    assert delete(ShushuTarget(user=None, name=unique_name)) is True
    assert probe(ShushuTarget(user=None, name=unique_name)) is None


def test_delete_returns_false_on_missing():
    name = f"CULTUREFLARE_NOPE_{uuid.uuid4().hex.upper()}"
    assert delete(ShushuTarget(user=None, name=name)) is False
```

- [ ] **Step 2: Run unit suite (integration must skip cleanly)**

```bash
uv run pytest tests/test_secrets_shushu_integration.py -v
```

Expected: 3 skipped (SHUSHU_INTEGRATION not set).

- [ ] **Step 3: Run integration suite locally with shushu installed**

```bash
SHUSHU_INTEGRATION=1 uv run pytest tests/test_secrets_shushu_integration.py -v
```

Expected: 3 passed.

- [ ] **Step 4: Commit**

```bash
git add tests/test_secrets_shushu_integration.py
git commit -m "test(secrets): add gated integration suite against the real shushu binary"
```

---

### Task 15: Version bump 0.3.1 → 0.4.0

**Files:**
- Modify: `pyproject.toml`, `cultureflare/__init__.py`, `CHANGELOG.md`

- [ ] **Step 1: Run version-bump skill in minor mode**

```bash
echo '{"added":["`cultureflare remote-login --shushu[=USER]` flag — pipes tunnel_token + service_token client_secret directly into a `shushu set --hidden` subprocess so the secrets never cross stdout, agent harness, or operator terminal. Cross-user deposit via sudo. Markdown / JSON output replaces secret-bearing fields with `<sealed: shushu/USER/NAME>` markers; show probes shushu for presence; teardown deletes the entries."],"changed":["`SetupResult.tunnel_token` is now `str | None`; gains `sealed_in: dict[str, str]`. `ShowResult` gains `sealed_in_status: dict[str, dict | None]`. Defaults preserve existing behaviour."]}' \
  | python3 .claude/skills/version-bump/scripts/bump.py minor
```

- [ ] **Step 2: Verify the bump landed in all three places**

```bash
grep -n '0.4.0' pyproject.toml cultureflare/__init__.py CHANGELOG.md
```

Expected: a hit in each file.

- [ ] **Step 3: Run the full test suite**

```bash
uv run pytest -v
```

Expected: all pass.

- [ ] **Step 4: Run shellcheck + markdownlint guards**

```bash
bash tests/shellcheck.sh && bash tests/markdownlint.sh
```

Expected: no violations.

- [ ] **Step 5: Commit**

```bash
git add pyproject.toml cultureflare/__init__.py CHANGELOG.md uv.lock
git commit -m "chore: bump version 0.3.1 → 0.4.0 for shushu sealed-secret mode"
```

- [ ] **Step 6: Push + open PR**

```bash
git push -u origin feat/remote-login-shushu-sealed-secrets
gh pr create --title "feat(remote-login): --shushu[=USER] sealed-secret mode" --body "$(cat <<'EOF'
## Summary
- Adds `--shushu[=USER]` to `cultureflare remote-login {setup,show,teardown}`. Secrets stream straight into `shushu set --hidden` via stdin and never appear on stdout, in JSON output, or in the agent's tool result.
- Cross-user deposit via `sudo shushu --user USER`. Same flag mirrored on show (probe) and teardown (delete).
- Output replaces secret fields with `<sealed: shushu/USER/NAME>` markers (markdown) or `null` + `sealed_in: {...}` block (JSON).
- New `cultureflare/_secrets/` package owns the sink; pure-function `_seal_plan` derives target names + metadata from the hostname.

## Test plan
- [ ] `uv run pytest -v` (unit + back-compat regression — ~20 new tests)
- [ ] `SHUSHU_INTEGRATION=1 uv run pytest tests/test_secrets_shushu_integration.py -v` (real-shushu round-trip)
- [ ] Manual: `cultureflare remote-login setup --hostname app.example.com --allow ME --with-service-token --shushu --apply` → both secrets land hidden in shushu; output shows sealed markers.
- [ ] Manual: `shushu run --inject T=CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN -- bash -c 'echo "${#T}"'` → prints non-zero length.
- [ ] Manual: `cultureflare remote-login teardown --hostname app.example.com --shushu --apply` → CF resources gone AND shushu entries gone.

Spec: docs/superpowers/specs/2026-05-08-remote-login-shushu-sealed-secrets-design.md
Plan: docs/superpowers/plans/2026-05-08-remote-login-shushu-sealed-secrets.md

- Claude

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

After PR creation, invoke the `poll` skill with the new PR number.

---

## Self-review

**1. Spec coverage:**

| Spec section | Task(s) |
|---|---|
| Module `_secrets/_shushu_sink.py` (`seal/probe/delete`) | 3, 4, 5 |
| `derive_seal_plan` pure function | 2 |
| `SetupResult` / `ShowResult` field changes | 6 |
| `setup` orchestrator wires sink + sealed_in | 8 |
| `show` orchestrator probes sealed entries | 9 |
| `teardown` orchestrator deletes sealed entries | 10 |
| `_render.py` markdown + JSON sealed markers | 7 |
| CLI `--shushu[=USER]` argparse | 11 |
| Dry-run plan output includes seal steps | 12 |
| `cfafi/__init__.py` shim aliases | 13 |
| Integration test against real shushu | 14 |
| Back-compat regression (no-flag → secrets in clear) | 13 |
| Version bump 0.3.1 → 0.4.0 | 15 |

All sections covered.

**2. Placeholder scan:** no "TBD", no "implement later", no "similar to Task N". Each step has either real code, a real shell command, or a deterministic edit description.

**3. Type consistency:**
- `ShushuTarget(user, name)` — Task 1 defines, Tasks 2/3/4/5/8/9/10 use the same field names.
- `SealMetadata(source, purpose, rotate_howto)` — Task 1 defines, Task 2 constructs, Task 3 reads via `meta.source / meta.purpose / meta.rotate_howto`.
- `SealPlan(enabled, user, tunnel_token_target, service_token_secret_target, metadata)` — Task 2 defines, Tasks 8/9/10/11/12 use those exact field names.
- `seal(target, secret, meta)` — signature consistent across Tasks 3 and 8.
- `probe(target) -> dict | None` — Tasks 4 and 9.
- `delete(target) -> bool` — Tasks 5 and 10.
- `sealed_in: dict[str, str]` keys are `"tunnel_token"` and `"service_token_client_secret"` everywhere (Tasks 6, 7, 8, 13).
- `sealed_in_status: dict[str, dict | None]` value shape is `{"present": bool, "name": str, "source": str | None}` everywhere (Tasks 6, 7, 9).
- Step names in teardown (`shushu-tunnel-token`, `shushu-svc-secret`) are consistent between Task 10 implementation and tests.
