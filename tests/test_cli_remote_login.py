"""End-to-end tests for `cfafi remote-login` via main([...])."""

import json

from cfafi.cli import main


def _zones_one(name="culture.dev", zid="zid-1"):
    return {
        "success": True, "errors": [], "messages": [],
        "result": [{"id": zid, "name": name}],
        "result_info": {"page": 1, "total_pages": 1},
    }


def _verify_full_scopes(with_st=False):
    pgs = [
        "Cloudflare Tunnel Write",
        "Access: Apps and Policies Write",
        "Access: Organizations Write",
        "DNS Write",
    ]
    if with_st:
        pgs.append("Access: Service Tokens Write")
    return {
        "success": True, "errors": [], "messages": [],
        "result": {
            "id": "tok-1", "status": "active",
            "policies": [{"permission_groups": [{"name": p} for p in pgs],
                          "resources": {}}],
        },
    }


def test_setup_dry_run_prints_plan_and_does_not_post(http_stub, capsys):
    http_stub.set("GET", "/user/tokens/verify", _verify_full_scopes())
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
    http_stub.set("GET", "/user/tokens/verify", _verify_full_scopes())
    http_stub.set("GET", "/zones", _zones_one())
    rc = main([
        "remote-login", "setup",
        "--hostname", "irc.culture.dev",
    ])
    assert rc != 0


def test_setup_preflight_blocks_when_token_lacks_scope(http_stub, capsys):
    http_stub.set("GET", "/user/tokens/verify", {
        "success": True, "errors": [], "messages": [],
        "result": {"id": "tok-1", "status": "active",
                   "policies": [{"permission_groups": [{"name": "DNS Read"}],
                                 "resources": {}}]},
    })
    rc = main([
        "remote-login", "setup",
        "--hostname", "irc.culture.dev",
        "--allow", "me@example.com",
    ])
    err = capsys.readouterr().err
    assert rc != 0
    assert "missing required scopes" in err


def test_show_emits_json_when_flagged(http_stub, capsys):
    http_stub.set("GET", "/user/tokens/verify", {
        "success": True, "errors": [], "messages": [],
        "result": {"id": "tok-1", "status": "active",
                   "policies": [{"permission_groups": [
                       {"name": "Cloudflare Tunnel Read"},
                       {"name": "Access: Apps and Policies Read"},
                       {"name": "DNS Read"},
                   ], "resources": {}}]},
    })
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
    http_stub.set("GET", "/user/tokens/verify", _verify_full_scopes())
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
