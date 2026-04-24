"""Top-level CLI entry point.

Noun-based subcommands register here. All errors route through
:mod:`cfafi.cli._output` — no Python traceback ever reaches stderr.
Mirrors afi-cli's parser pattern (see /home/spark/git/afi-cli/afi/cli).
"""

from __future__ import annotations

import argparse
import sys

from cfafi import __version__
from cfafi.cli._errors import EXIT_USER_ERROR, CfafiError
from cfafi.cli._output import emit_error


class _CfafiArgumentParser(argparse.ArgumentParser):
    """ArgumentParser whose .error() routes through emit_error.

    Argparse's default error handler prints ``prog: error: <msg>`` to
    stderr with exit code 2 — bypassing our structured format. This
    subclass emits the canonical ``error:`` / ``hint:`` shape.

    The ``--json`` flag is recognised before ``parse_args`` runs by
    :func:`_argv_has_json` so that parse-time errors honour JSON mode.
    """

    _json_hint: bool = False

    def error(self, message: str) -> None:  # type: ignore[override]
        err = CfafiError(
            code=EXIT_USER_ERROR,
            message=message,
            remediation=f"run '{self.prog} --help' for valid arguments",
        )
        emit_error(err, json_mode=type(self)._json_hint)
        raise SystemExit(err.code)


def _argv_has_json(argv: list[str] | None) -> bool:
    tokens = argv if argv is not None else sys.argv[1:]
    return any(t == "--json" or t.startswith("--json=") for t in tokens)


def _build_parser() -> argparse.ArgumentParser:
    # Deferred imports keep cli import-side effects tight.
    from cfafi.cli._commands import dns as _dns
    from cfafi.cli._commands import explain as _explain
    from cfafi.cli._commands import learn as _learn
    from cfafi.cli._commands import whoami as _whoami
    from cfafi.cli._commands import zones as _zones

    parser = _CfafiArgumentParser(
        prog="cfafi",
        description="cfafi — CloudFlare Agent First Interface",
    )
    parser.add_argument(
        "--version",
        action="version",
        version=f"%(prog)s {__version__}",
    )
    sub = parser.add_subparsers(dest="command", parser_class=_CfafiArgumentParser)

    # Globals
    _learn.register(sub)
    _explain.register(sub)
    _whoami.register(sub)
    # Noun groups
    _zones.register(sub)
    _dns.register(sub)

    return parser


def _dispatch(args: argparse.Namespace) -> int:
    json_mode = bool(getattr(args, "json", False))
    try:
        rc = args.func(args)
    except CfafiError as err:
        emit_error(err, json_mode=json_mode)
        return err.code
    except Exception as err:  # noqa: BLE001 - wrap so no traceback leaks
        wrapped = CfafiError(
            code=EXIT_USER_ERROR,
            message=f"unexpected: {err.__class__.__name__}: {err}",
            remediation="file a bug at https://github.com/agentculture/cfafi/issues",
        )
        emit_error(wrapped, json_mode=json_mode)
        return wrapped.code
    return rc if rc is not None else 0


def main(argv: list[str] | None = None) -> int:
    _CfafiArgumentParser._json_hint = _argv_has_json(argv)
    parser = _build_parser()
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 0
    return _dispatch(args)


if __name__ == "__main__":
    sys.exit(main())
