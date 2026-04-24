"""Tests for `cfafi explain`."""

import json

from cfafi.cli import main
from cfafi.cli._errors import EXIT_USER_ERROR


def test_explain_whoami_renders_markdown(capsys):
    rc = main(["explain", "whoami"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "# cfafi whoami" in out
    assert "/user/tokens/verify" in out
    assert "--json" in out


def test_explain_dns_create_renders_markdown(capsys):
    rc = main(["explain", "dns", "create"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "# cfafi dns create" in out
    assert "--apply" in out
    assert "dry-run" in out.lower()


def test_explain_zones_list(capsys):
    rc = main(["explain", "zones", "list"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "# cfafi zones list" in out


def test_explain_empty_path_prints_index(capsys):
    rc = main(["explain"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "cfafi" in out
    assert "whoami" in out and "zones list" in out and "dns create" in out


def test_explain_unknown_path_errors(capsys):
    rc = main(["explain", "bogus"])
    err = capsys.readouterr().err
    assert rc == EXIT_USER_ERROR
    assert "bogus" in err
    assert "hint:" in err


def test_explain_json_wraps_markdown(capsys):
    rc = main(["explain", "whoami", "--json"])
    out = capsys.readouterr().out
    assert rc == 0
    payload = json.loads(out)
    assert payload["path"] == ["whoami"]
    assert "whoami" in payload["markdown"]
