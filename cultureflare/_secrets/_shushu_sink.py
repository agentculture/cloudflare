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

import json as _json
import subprocess

from cultureflare._secrets._types import SealMetadata, ShushuTarget
from cultureflare.cli._errors import (
    EXIT_API, EXIT_USER_ERROR, CfafiError,
)


def _sudo_prefix(target: ShushuTarget) -> list[str]:
    """argv prefix that lifts the call to sudo when target.user is set."""
    return ["sudo"] if target.user is not None else []


def _user_flag(target: ShushuTarget) -> list[str]:
    """``--user NAME`` flag pair when cross-user, else empty."""
    return ["--user", target.user] if target.user is not None else []


def _argv_for_set(target: ShushuTarget, meta: SealMetadata) -> list[str]:
    return [
        *_sudo_prefix(target),
        "shushu", "set", "--hidden",
        "--source", meta.source,
        "--purpose", meta.purpose,
        "--rotate-howto", meta.rotate_howto,
        *_user_flag(target),
        target.name, "-",
    ]


def _argv_for_show(target: ShushuTarget) -> list[str]:
    return [
        *_sudo_prefix(target),
        "shushu", "show", "--json",
        *_user_flag(target),
        target.name,
    ]


def _argv_for_delete(target: ShushuTarget) -> list[str]:
    return [
        *_sudo_prefix(target),
        "shushu", "delete",
        *_user_flag(target),
        target.name,
    ]


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
