"""Tests for cfafi.cli entry-point plumbing (argparse, error routing, --version)."""

import json
import sys

import pytest

from cfafi import __version__
from cfafi.cli import main


def test_main_prints_help_when_no_command(capsys):
    rc = main([])
    out = capsys.readouterr().out
    assert rc == 0
    assert "cfafi" in out
    assert "whoami" in out and "zones" in out and "dns" in out


def test_main_version_flag(capsys):
    with pytest.raises(SystemExit) as excinfo:
        main(["--version"])
    out = capsys.readouterr().out
    assert excinfo.value.code == 0
    assert __version__ in out


def test_main_unknown_command_exits_user_error(capsys):
    with pytest.raises(SystemExit) as excinfo:
        main(["bogus-noun"])
    err = capsys.readouterr().err
    # Argparse-level errors must route through our structured format:
    assert "error:" in err
    assert "hint:" in err
    assert excinfo.value.code != 0


def test_main_json_flag_routes_errors_as_json(capsys):
    with pytest.raises(SystemExit):
        main(["bogus-noun", "--json"])
    err = capsys.readouterr().err
    payload = json.loads(err.strip().splitlines()[-1])
    assert "code" in payload and "message" in payload


def test_main_help_uses_cultureflare_prog_under_pytest(capsys):
    """argparse's `prog` falls back to the canonical name when invoked
    from a non-canonical executable (here: pytest). Keeps help / usage /
    version output stable regardless of argv[0]."""
    rc = main([])
    out = capsys.readouterr().out
    assert rc == 0
    assert "usage: cultureflare" in out


def test_main_help_uses_alias_when_invoked_as_cfafi(monkeypatch, capsys):
    """When sys.argv[0] basename is one of the known aliases, that
    name is used. Simulates a real `cfafi` console-script invocation."""
    monkeypatch.setattr(sys, "argv", ["/usr/local/bin/cfafi"])
    rc = main([])
    out = capsys.readouterr().out
    assert rc == 0
    assert "usage: cfafi" in out


def test_main_help_uses_alias_when_invoked_as_cultureflare(monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["/usr/local/bin/cultureflare"])
    rc = main([])
    out = capsys.readouterr().out
    assert rc == 0
    assert "usage: cultureflare" in out


def test_main_help_falls_back_to_canonical_for_python_m(monkeypatch, capsys):
    """`python -m cfafi` makes sys.argv[0] something like
    `/.../cfafi/__main__.py`; argparse should NOT print
    `usage: __main__.py …`. Falls back to `cultureflare`."""
    monkeypatch.setattr(sys, "argv", ["/path/to/cfafi/__main__.py"])
    rc = main([])
    out = capsys.readouterr().out
    assert rc == 0
    assert "usage: cultureflare" in out
    assert "__main__.py" not in out
