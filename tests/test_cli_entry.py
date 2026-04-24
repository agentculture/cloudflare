"""Tests for cfafi.cli entry-point plumbing (argparse, error routing, --version)."""

import json

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
