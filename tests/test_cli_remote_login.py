"""End-to-end tests for `cfafi remote-login` via main([...])."""

import json

from cfafi.cli import main


def _zones_one(name="culture.dev", zid="zid-1"):
    return {
        "success": True, "errors": [], "messages": [],
        "result": [{"id": zid, "name": name}],
        "result_info": {"page": 1, "total_pages": 1},
    }


def _verify_alive(status="active"):
    """Mirror real `/user/tokens/verify`: id/status/not_before/expires_on only."""
    return {
        "success": True, "errors": [], "messages": [],
        "result": {
            "id": "tok-1",
            "status": status,
            "not_before": "2026-01-01T00:00:00Z",
            "expires_on": "2027-01-01T00:00:00Z",
        },
    }


def test_setup_dry_run_prints_plan_and_does_not_post(http_stub, capsys):
    http_stub.set("GET", "/user/tokens/verify", _verify_alive())
    http_stub.set("GET", "/zones", _zones_one())
    rc = main([
        "remote-login", "setup",
        "--hostname", "irc.culture.dev",
        "--allow", "me@example.com",
    ])
    out = capsys.readouterr().out
    assert rc == 0
    assert "Dry-run" in out
    assert "## Plan" in out
    assert "irc.culture.dev" in out
    posts = [c for c in http_stub.calls if c[0] == "POST"]
    assert posts == []


def test_setup_requires_at_least_one_allow(http_stub, capsys):
    http_stub.set("GET", "/user/tokens/verify", _verify_alive())
    http_stub.set("GET", "/zones", _zones_one())
    rc = main([
        "remote-login", "setup",
        "--hostname", "irc.culture.dev",
    ])
    assert rc != 0


def test_setup_preflight_blocks_when_token_inactive(http_stub, capsys):
    http_stub.set("GET", "/user/tokens/verify", _verify_alive(status="disabled"))
    rc = main([
        "remote-login", "setup",
        "--hostname", "irc.culture.dev",
        "--allow", "me@example.com",
    ])
    err = capsys.readouterr().err
    assert rc != 0
    assert "'disabled'" in err


def test_show_emits_json_when_flagged(http_stub, capsys):
    http_stub.set("GET", "/user/tokens/verify", _verify_alive())
    http_stub.set("GET", "/zones", _zones_one())
    http_stub.set("GET", "/accounts/test-account/access/organizations", {
        "success": True, "errors": [], "messages": [],
        "result": {"name": "AC", "auth_domain": "ac.cloudflareaccess.com"},
    })
    http_stub.set("GET", "/accounts/test-account/cfd_tunnel",
                  {"success": True, "errors": [], "messages": [], "result": [],
                   "result_info": {"page": 1, "total_pages": 1}})
    http_stub.set("GET", "/zones/zid-1/dns_records",
                  {"success": True, "errors": [], "messages": [], "result": [],
                   "result_info": {"page": 1, "total_pages": 1}})
    http_stub.set("GET", "/accounts/test-account/access/apps",
                  {"success": True, "errors": [], "messages": [], "result": [],
                   "result_info": {"page": 1, "total_pages": 1}})
    http_stub.set("GET", "/accounts/test-account/access/service_tokens",
                  {"success": True, "errors": [], "messages": [], "result": [],
                   "result_info": {"page": 1, "total_pages": 1}})
    rc = main([
        "remote-login", "show",
        "--hostname", "irc.culture.dev", "--json",
    ])
    out = capsys.readouterr().out
    assert rc == 0
    payload = json.loads(out)
    assert payload["success"] is True
    assert payload["result"]["team_domain"] == "ac.cloudflareaccess.com"
    assert payload["result"]["tunnel"] is None


def test_teardown_dry_run_does_not_delete(http_stub, capsys):
    http_stub.set("GET", "/user/tokens/verify", _verify_alive())
    http_stub.set("GET", "/zones", _zones_one())
    rc = main([
        "remote-login", "teardown",
        "--hostname", "irc.culture.dev",
    ])
    out = capsys.readouterr().out
    assert rc == 0
    assert "Dry-run" in out
    deletes = [c for c in http_stub.calls if c[0] == "DELETE"]
    assert deletes == []
