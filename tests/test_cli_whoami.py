"""Tests for `cfafi whoami`."""

import json

from cfafi.cli import main
from cfafi.cli._errors import EXIT_AUTH, CfafiError


def test_whoami_markdown(http_stub, capsys):
    http_stub.set_fixture("GET", "/user/tokens/verify", "token_verify")
    rc = main(["whoami"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "**CloudFlare token**" in out
    assert "**id:** test-token-id-0123456789abcdef" in out
    assert "**status:** active" in out
    assert "**expires_on:** 2027-01-01T00:00:00Z" in out


def test_whoami_json(http_stub, capsys):
    http_stub.set_fixture("GET", "/user/tokens/verify", "token_verify")
    rc = main(["whoami", "--json"])
    out = capsys.readouterr().out
    assert rc == 0
    payload = json.loads(out)
    assert payload["success"] is True
    assert payload["result"]["status"] == "active"


def test_whoami_auth_error_exits_auth(http_stub, capsys):
    http_stub.set("GET", "/user/tokens/verify", CfafiError(
        code=EXIT_AUTH, message="CloudFlare API 6003: Invalid request headers",
        remediation="check token scopes against docs/SETUP.md",
    ))
    rc = main(["whoami"])
    err = capsys.readouterr().err
    assert rc == EXIT_AUTH
    assert "6003" in err or "Invalid request headers" in err
    assert "hint:" in err


def test_whoami_missing_env(monkeypatch, capsys):
    monkeypatch.delenv("CLOUDFLARE_API_TOKEN", raising=False)
    rc = main(["whoami"])
    err = capsys.readouterr().err
    assert rc != 0
    assert "CLOUDFLARE_API_TOKEN" in err
