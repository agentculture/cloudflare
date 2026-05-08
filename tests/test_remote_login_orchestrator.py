"""Tests for the cultureflare._remote_login orchestrator."""

import pytest

from cultureflare._remote_login import setup, show, teardown
from cultureflare._remote_login._common import (
    Context, derive_names, SetupResult, ShowResult, TeardownResult,
)
from cultureflare._remote_login._seal_plan import derive_seal_plan
from cultureflare._secrets._types import ShushuTarget
from cultureflare.cli._errors import CfafiError, EXIT_API, EXIT_USER_ERROR


def _ctx(hostname="irc.culture.dev"):
    return Context(
        account_id="acc-1",
        zone_id="zid-1",
        hostname=hostname,
        names=derive_names(hostname=hostname),
        service="http://localhost:8080",
    )


def _ctx_for(hostname):
    return Context(
        account_id="acc-1",
        zone_id="zid-1",
        hostname=hostname,
        names=derive_names(hostname=hostname),
        service="http://localhost:8080",
    )


def _program_setup_happy_path(
    http_stub,
    *,
    account_id="acc-1",
    zone_id="zid-1",
    hostname="app.example.com",
    tunnel_id="tun-1",
    app_id="app-1",
    policy_id="pol-1",
    svc_id="st-1",
    svc_client_id="CID",
    svc_client_secret="SEC",
):
    """Program all HTTP stubs for a happy-path setup() run."""
    tunnel_name = hostname.replace(".", "-")
    svc_name = f"{hostname}-svc"

    http_stub.set("GET", f"/accounts/{account_id}/access/organizations", {
        "success": True, "errors": [], "messages": [],
        "result": {"name": "AC", "auth_domain": "ac.cloudflareaccess.com"},
    })
    http_stub.set("GET", f"/accounts/{account_id}/cfd_tunnel", {
        "success": True, "errors": [], "messages": [],
        "result": [], "result_info": {"page": 1, "total_pages": 1},
    })
    http_stub.set("POST", f"/accounts/{account_id}/cfd_tunnel", {
        "success": True, "errors": [], "messages": [],
        "result": {"id": tunnel_id, "name": tunnel_name},
    })
    http_stub.set(
        "GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/token",
        {"success": True, "errors": [], "messages": [], "result": "TUN-TOK"},
    )
    http_stub.set(
        "GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations",
        {"success": True, "errors": [], "messages": [],
         "result": {"config": {"ingress": []}}},
    )
    http_stub.set(
        "PUT", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations",
        {"success": True, "errors": [], "messages": [],
         "result": {"config": {"ingress": [
             {"hostname": hostname, "service": "http://localhost:8080"},
             {"service": "http_status:404"},
         ]}}},
    )
    http_stub.set("GET", f"/zones/{zone_id}/dns_records", {
        "success": True, "errors": [], "messages": [],
        "result": [], "result_info": {"page": 1, "total_pages": 1},
    })
    http_stub.set("POST", f"/zones/{zone_id}/dns_records", {
        "success": True, "errors": [], "messages": [],
        "result": {"id": "rec-1"},
    })
    http_stub.set("GET", f"/accounts/{account_id}/access/apps", {
        "success": True, "errors": [], "messages": [],
        "result": [], "result_info": {"page": 1, "total_pages": 1},
    })
    http_stub.set("POST", f"/accounts/{account_id}/access/apps", {
        "success": True, "errors": [], "messages": [],
        "result": {"id": app_id},
    })
    http_stub.set("GET", f"/accounts/{account_id}/access/apps/{app_id}/policies", {
        "success": True, "errors": [], "messages": [],
        "result": [], "result_info": {"page": 1, "total_pages": 1},
    })
    http_stub.set(
        "POST", f"/accounts/{account_id}/access/apps/{app_id}/policies",
        {"success": True, "errors": [], "messages": [],
         "result": {"id": policy_id}},
    )
    http_stub.set("GET", f"/accounts/{account_id}/access/service_tokens", {
        "success": True, "errors": [], "messages": [],
        "result": [], "result_info": {"page": 1, "total_pages": 1},
    })
    http_stub.set("POST", f"/accounts/{account_id}/access/service_tokens", {
        "success": True, "errors": [], "messages": [],
        "result": {
            "id": svc_id, "name": svc_name,
            "client_id": svc_client_id, "client_secret": svc_client_secret,
        },
    })


def _zt_existing():
    return {
        "success": True, "errors": [], "messages": [],
        "result": {"name": "AC", "auth_domain": "ac.cloudflareaccess.com"},
    }


def _empty_list():
    return {
        "success": True, "errors": [], "messages": [],
        "result": [], "result_info": {"page": 1, "total_pages": 1},
    }


def _list_envelope(*items):
    return {
        "success": True, "errors": [], "messages": [],
        "result": list(items),
        "result_info": {"page": 1, "total_pages": 1},
    }


def test_setup_runs_all_six_steps_in_order_when_nothing_exists(http_stub):
    # Program all responses via set() so method+path keying works
    # regardless of call order (avoids queue ordering pitfalls when
    # GETs and POSTs are interleaved).
    _program_setup_happy_path(http_stub, hostname="irc.culture.dev")

    result = setup(
        ctx=_ctx(),
        emails=["me@example.com"],
        domains=[],
        with_service_token=True,
        session_duration="24h",
    )
    assert isinstance(result, SetupResult)
    assert result.team_domain == "ac.cloudflareaccess.com"
    assert result.tunnel_id == "tun-1"
    assert result.tunnel_token == "TUN-TOK"
    assert result.dns_record_id == "rec-1"
    assert result.access_app_id == "app-1"
    assert result.policy_id == "pol-1"
    assert result.service_token_client_id == "CID"
    assert result.service_token_client_secret == "SEC"
    assert result.tunnel_service == "http://localhost:8080"
    assert result.service_token_policy_id is not None
    assert [s.name for s in result.steps] == [
        "zero-trust-org", "tunnel", "tunnel-config", "dns", "access-app",
        "allow-policy", "service-token", "service-token-policy",
    ]
    # The non_identity policy POST must reference the token's *resource id*,
    # not the (different) public client_id — otherwise CF accepts the
    # policy but service-token requests still fall through to SSO.
    posts = [c for c in http_stub.calls if c[0] == "POST"
             and c[1] == "/accounts/acc-1/access/apps/app-1/policies"]
    decisions = [(p[2] or {}).get("decision") for p in posts]
    assert "non_identity" in decisions
    non_identity_post = next(
        p for p in posts if (p[2] or {}).get("decision") == "non_identity"
    )
    include = (non_identity_post[2] or {}).get("include") or []
    assert any(
        (rule.get("service_token") or {}).get("token_id") == "st-1"
        for rule in include
    )


def test_setup_skips_service_token_step_when_not_requested(http_stub):
    http_stub.set("GET", "/accounts/acc-1/access/organizations", _zt_existing())
    http_stub.set("GET", "/accounts/acc-1/cfd_tunnel", _empty_list())
    http_stub.set("POST", "/accounts/acc-1/cfd_tunnel", {
        "success": True, "errors": [], "messages": [],
        "result": {"id": "tun-1"},
    })
    http_stub.set(
        "GET", "/accounts/acc-1/cfd_tunnel/tun-1/token",
        {"success": True, "errors": [], "messages": [], "result": "TUN-TOK"},
    )
    http_stub.set(
        "GET", "/accounts/acc-1/cfd_tunnel/tun-1/configurations",
        {"success": True, "errors": [], "messages": [],
         "result": {"config": {"ingress": []}}},
    )
    http_stub.set(
        "PUT", "/accounts/acc-1/cfd_tunnel/tun-1/configurations",
        {"success": True, "errors": [], "messages": [],
         "result": {"config": {"ingress": []}}},
    )
    http_stub.set("GET", "/zones/zid-1/dns_records", _empty_list())
    http_stub.set("POST", "/zones/zid-1/dns_records",
                  {"success": True, "errors": [], "messages": [],
                   "result": {"id": "rec-1"}})
    http_stub.set("GET", "/accounts/acc-1/access/apps", _empty_list())
    http_stub.set("POST", "/accounts/acc-1/access/apps",
                  {"success": True, "errors": [], "messages": [],
                   "result": {"id": "app-1"}})
    http_stub.set("GET", "/accounts/acc-1/access/apps/app-1/policies", _empty_list())
    http_stub.set("POST", "/accounts/acc-1/access/apps/app-1/policies",
                  {"success": True, "errors": [], "messages": [],
                   "result": {"id": "pol-1"}})

    result = setup(
        ctx=_ctx(), emails=["me@example.com"], domains=[],
        with_service_token=False, session_duration="24h",
    )
    assert result.service_token_client_id is None
    assert result.service_token_client_secret is None
    assert "service-token" not in [s.name for s in result.steps]
    paths = [c[1] for c in http_stub.calls]
    assert "/accounts/acc-1/access/service_tokens" not in paths


def _program_show_happy_path(
    http_stub,
    *,
    account_id="acc-1",
    zone_id="zid-1",
    hostname="app.example.com",
    tunnel_id="tun-1",
    app_id="app-1",
    policy_id="pol-1",
    svc_id="st-1",
):
    """Program all HTTP stubs for a happy-path show() run (all resources exist)."""
    tunnel_name = hostname.replace(".", "-")
    svc_name = f"{hostname}-svc"
    policy_name = f"{hostname}-allow"

    http_stub.set("GET", f"/accounts/{account_id}/access/organizations", {
        "success": True, "errors": [], "messages": [],
        "result": {"name": "AC", "auth_domain": "ac.cloudflareaccess.com"},
    })
    http_stub.set(
        "GET", f"/accounts/{account_id}/cfd_tunnel",
        _list_envelope({"id": tunnel_id, "name": tunnel_name}),
    )
    http_stub.set(
        "GET", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations",
        {"success": True, "errors": [], "messages": [],
         "result": {"config": {"ingress": [
             {"hostname": hostname, "service": "http://localhost:8080"},
             {"service": "http_status:404"},
         ]}}},
    )
    http_stub.set(
        "GET", f"/zones/{zone_id}/dns_records",
        _list_envelope({
            "id": "rec-1", "type": "CNAME", "name": hostname,
            "content": f"{tunnel_id}.cfargotunnel.com", "proxied": True,
        }),
    )
    http_stub.set(
        "GET", f"/accounts/{account_id}/access/apps",
        _list_envelope({"id": app_id, "domain": hostname}),
    )
    http_stub.set(
        "GET", f"/accounts/{account_id}/access/apps/{app_id}/policies",
        _list_envelope({"id": policy_id, "name": policy_name}),
    )
    http_stub.set(
        "GET", f"/accounts/{account_id}/access/service_tokens",
        _list_envelope({"id": svc_id, "name": svc_name, "client_id": "CID"}),
    )


def test_show_reports_partial_state(http_stub):
    # ZT exists, tunnel exists, DNS missing, app missing, no policies, no svc.
    http_stub.set("GET", "/accounts/acc-1/access/organizations", {
        "success": True, "errors": [], "messages": [],
        "result": {"name": "AC", "auth_domain": "ac.cloudflareaccess.com"},
    })
    http_stub.set(
        "GET", "/accounts/acc-1/cfd_tunnel",
        _list_envelope({"id": "tun-1", "name": "irc-culture-dev"}),
    )
    http_stub.set(
        "GET", "/accounts/acc-1/cfd_tunnel/tun-1/configurations",
        {"success": True, "errors": [], "messages": [],
         "result": {"config": {"ingress": []}}},
    )
    http_stub.set("GET", "/zones/zid-1/dns_records", _empty_list())
    http_stub.set("GET", "/accounts/acc-1/access/apps", _empty_list())
    # apps absent -> orchestrator skips listing policies
    http_stub.set("GET", "/accounts/acc-1/access/service_tokens", _empty_list())

    result = show(ctx=_ctx())
    assert isinstance(result, ShowResult)
    assert result.team_domain == "ac.cloudflareaccess.com"
    assert result.tunnel == {"id": "tun-1", "name": "irc-culture-dev"}
    assert result.dns is None
    assert result.access_app is None
    assert result.policy is None
    assert result.service_token is None


def _program_teardown_happy_path(
    http_stub,
    *,
    account_id="acc-1",
    zone_id="zid-1",
    hostname="app.example.com",
    tunnel_id="tun-1",
    app_id="app-1",
    policy_id="pol-1",
    svc_id="st-1",
):
    """Program all HTTP stubs for a happy-path teardown() run."""
    tunnel_name = hostname.replace(".", "-")
    svc_name = f"{hostname}-svc"
    policy_name = f"{hostname}-allow"

    http_stub.set(
        "GET", f"/accounts/{account_id}/access/service_tokens",
        _list_envelope({"id": svc_id, "name": svc_name, "client_id": "CID"}),
    )
    http_stub.set(
        "DELETE", f"/accounts/{account_id}/access/service_tokens/{svc_id}",
        {"success": True, "errors": [], "messages": [], "result": {"id": svc_id}},
    )
    http_stub.set(
        "GET", f"/accounts/{account_id}/access/apps",
        _list_envelope({"id": app_id, "domain": hostname}),
    )
    http_stub.set(
        "GET", f"/accounts/{account_id}/access/apps/{app_id}/policies",
        _list_envelope(
            {"id": policy_id, "name": policy_name},
            {
                "id": "pol-svc",
                "name": f"{hostname}-svc-allow",
                "decision": "non_identity",
                "include": [{"service_token": {"token_id": svc_id}}],
            },
        ),
    )
    http_stub.set(
        "DELETE", f"/accounts/{account_id}/access/apps/{app_id}/policies/{policy_id}",
        {"success": True, "errors": [], "messages": [], "result": {"id": policy_id}},
    )
    http_stub.set(
        "DELETE", f"/accounts/{account_id}/access/apps/{app_id}/policies/pol-svc",
        {"success": True, "errors": [], "messages": [], "result": {"id": "pol-svc"}},
    )
    http_stub.set(
        "DELETE", f"/accounts/{account_id}/access/apps/{app_id}",
        {"success": True, "errors": [], "messages": [], "result": {"id": app_id}},
    )
    http_stub.set(
        "GET", f"/zones/{zone_id}/dns_records",
        _list_envelope({
            "id": "rec-1", "type": "CNAME", "name": hostname,
            "content": f"{tunnel_id}.cfargotunnel.com", "proxied": True,
        }),
    )
    http_stub.set(
        "DELETE", f"/zones/{zone_id}/dns_records/rec-1",
        {"success": True, "errors": [], "messages": [], "result": {"id": "rec-1"}},
    )
    http_stub.set(
        "GET", f"/accounts/{account_id}/cfd_tunnel",
        _list_envelope({"id": tunnel_id, "name": tunnel_name}),
    )
    http_stub.set(
        "DELETE", f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}",
        {"success": True, "errors": [], "messages": [], "result": {"id": tunnel_id}},
    )


def test_teardown_reverses_setup_skipping_zt_org(http_stub):
    # Order of deletes: service-token, policy, app, dns, tunnel.
    _program_teardown_happy_path(http_stub, hostname="irc.culture.dev")
    result = teardown(ctx=_ctx(), keep_tunnel=False)
    assert isinstance(result, TeardownResult)
    assert [s.name for s in result.steps] == [
        "service-token", "service-token-policy",
        "allow-policy", "access-app", "dns", "tunnel",
    ]
    delete_paths = [c[1] for c in http_stub.calls if c[0] == "DELETE"]
    assert all("organizations" not in p for p in delete_paths)


def test_teardown_keep_tunnel_skips_tunnel_delete(http_stub):
    http_stub.set("GET", "/accounts/acc-1/access/service_tokens", _empty_list())
    http_stub.set("GET", "/accounts/acc-1/access/apps", _empty_list())
    http_stub.set("GET", "/zones/zid-1/dns_records", _empty_list())
    # tunnel listing is skipped entirely under keep_tunnel
    result = teardown(ctx=_ctx(), keep_tunnel=True)
    assert "tunnel" not in [s.name for s in result.steps]


def test_setup_raises_clean_error_when_zt_not_enabled(http_stub):
    # When Zero Trust isn't enabled, find_org swallows the CF 9999
    # error into None; setup() should then raise its friendlier
    # EXIT_USER_ERROR pointing at the dashboard URL rather than
    # bubbling CF's raw "Access is not enabled" message.
    from cultureflare.cli._errors import EXIT_API, EXIT_USER_ERROR, CfafiError

    http_stub.set(
        "GET", "/accounts/acc-1/access/organizations",
        CfafiError(
            code=EXIT_API,
            message=(
                "CloudFlare API 9999: access.api.error.not_enabled: "
                "Access is not enabled."
            ),
            remediation="HTTP 404 from CloudFlare; inspect the request body and retry",
            cf_error_code=9999,
        ),
    )
    with pytest.raises(CfafiError) as exc:
        setup(
            ctx=_ctx(), emails=["me@example.com"], domains=[],
            with_service_token=False, session_duration="24h",
        )
    assert exc.value.code == EXIT_USER_ERROR
    assert "Zero Trust is not enabled" in exc.value.message
    assert "one.dash.cloudflare.com" in (exc.value.remediation or "")


def test_show_short_circuits_access_endpoints_when_zt_disabled(http_stub):
    # qodo Bug #2: when find_org returns None, show() must NOT call
    # /access/apps or /access/service_tokens — those would 9999 too.
    # Tunnel and DNS are still queried (not Access-scoped).
    from cultureflare.cli._errors import EXIT_API, CfafiError

    http_stub.set(
        "GET", "/accounts/acc-1/access/organizations",
        CfafiError(
            code=EXIT_API,
            message="CloudFlare API 9999: access.api.error.not_enabled: ...",
            remediation="...",
            cf_error_code=9999,
        ),
    )
    http_stub.set("GET", "/accounts/acc-1/cfd_tunnel", _empty_list())
    http_stub.set("GET", "/zones/zid-1/dns_records", _empty_list())

    result = show(ctx=_ctx())
    assert result.team_domain is None
    assert result.access_app is None
    assert result.policy is None
    assert result.service_token is None
    # Tunnel and DNS still queried.
    paths = [c[1] for c in http_stub.calls]
    assert "/accounts/acc-1/cfd_tunnel" in paths
    assert "/zones/zid-1/dns_records" in paths
    # Access endpoints MUST NOT appear.
    assert "/accounts/acc-1/access/apps" not in paths
    assert "/accounts/acc-1/access/service_tokens" not in paths


def test_setup_with_seal_calls_sink_twice_with_correct_targets(
    http_stub, monkeypatch,
):
    _program_setup_happy_path(http_stub, hostname="app.example.com")

    seal_calls: list[tuple[ShushuTarget, bytes]] = []

    def fake_seal(target, secret, meta):
        seal_calls.append((target, bytes(secret)))

    monkeypatch.setattr(
        "cultureflare._secrets._shushu_sink.seal", fake_seal
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
    assert all(c[0].user == "alice" for c in seal_calls)
    assert result.tunnel_token is None
    assert result.service_token_client_secret is None
    assert result.sealed_in["tunnel_token"] == \
        "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN"
    assert result.sealed_in["service_token_client_secret"] == \
        "shushu/alice/CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET"


def test_setup_with_seal_partial_failure_raises_rotate_remediation(
    http_stub, monkeypatch,
):
    _program_setup_happy_path(http_stub, hostname="app.example.com")

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
        "cultureflare._secrets._shushu_sink.seal", fake_seal
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
    # Regression guard: --shushu opt-in. Default behaviour unchanged.
    _program_setup_happy_path(http_stub, hostname="app.example.com")
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


def test_show_with_seal_probes_both_targets(http_stub, monkeypatch):
    _program_show_happy_path(http_stub, hostname="app.example.com")

    probed: list[ShushuTarget] = []

    def fake_probe(target):
        probed.append(target)
        if target.name.endswith("_TUNNEL_TOKEN"):
            return {"name": target.name, "hidden": True,
                    "source": "cultureflare/remote-login"}
        return None

    monkeypatch.setattr(
        "cultureflare._secrets._shushu_sink.probe", fake_probe
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="alice")
    ctx = _ctx_for("app.example.com")
    result = show(ctx=ctx, seal=plan)

    assert len(probed) == 2
    assert result.sealed_in_status["tunnel_token"]["present"] is True
    assert result.sealed_in_status["service_token_client_secret"]["present"] is False


def test_show_without_seal_does_not_probe(http_stub, monkeypatch):
    _program_show_happy_path(http_stub, hostname="app.example.com")

    def fake_probe(target):
        raise AssertionError("must not probe when seal disabled")

    monkeypatch.setattr(
        "cultureflare._secrets._shushu_sink.probe", fake_probe
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg=None)
    ctx = _ctx_for("app.example.com")
    result = show(ctx=ctx, seal=plan)
    assert result.sealed_in_status == {}


def test_show_with_seal_handles_shushu_missing(http_stub, monkeypatch):
    _program_show_happy_path(http_stub, hostname="app.example.com")

    def fake_probe(target):
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message="shushu binary not found",
            remediation="uv tool install shushu",
        )

    monkeypatch.setattr(
        "cultureflare._secrets._shushu_sink.probe", fake_probe
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="")
    ctx = _ctx_for("app.example.com")
    result = show(ctx=ctx, seal=plan)
    # show is non-fatal: render None for each entry
    assert result.sealed_in_status["tunnel_token"] is None
    assert result.sealed_in_status["service_token_client_secret"] is None


def test_teardown_with_seal_deletes_both_entries(http_stub, monkeypatch):
    _program_teardown_happy_path(http_stub, hostname="app.example.com")

    deleted: list[ShushuTarget] = []

    def fake_delete(target):
        deleted.append(target)
        return True

    monkeypatch.setattr(
        "cultureflare._secrets._shushu_sink.delete", fake_delete
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="alice")
    ctx = _ctx_for("app.example.com")
    result = teardown(ctx=ctx, keep_tunnel=False, seal=plan)

    names = [t.name for t in deleted]
    assert "CULTUREFLARE_APP_EXAMPLE_COM_TUNNEL_TOKEN" in names
    assert "CULTUREFLARE_APP_EXAMPLE_COM_SVC_SECRET" in names
    seal_steps = [s for s in result.steps if "shushu" in s.name]
    assert len(seal_steps) == 2


def test_teardown_with_seal_records_failed_delete_but_does_not_abort(
    http_stub, monkeypatch,
):
    _program_teardown_happy_path(http_stub, hostname="app.example.com")

    def fake_delete(target):
        if target.name.endswith("_SVC_SECRET"):
            raise CfafiError(
                code=EXIT_API,
                message="shushu store unreadable",
                remediation="shushu doctor",
            )
        return True

    monkeypatch.setattr(
        "cultureflare._secrets._shushu_sink.delete", fake_delete
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="")
    ctx = _ctx_for("app.example.com")
    result = teardown(ctx=ctx, keep_tunnel=False, seal=plan)

    actions = {s.name: s.action for s in result.steps if "shushu" in s.name}
    assert actions == {
        "shushu-tunnel-token": "deleted",
        "shushu-svc-secret": "delete-failed",
    }


def test_teardown_without_seal_does_not_call_delete(http_stub, monkeypatch):
    _program_teardown_happy_path(http_stub, hostname="app.example.com")

    def fake_delete(target):
        raise AssertionError("must not delete when seal disabled")

    monkeypatch.setattr(
        "cultureflare._secrets._shushu_sink.delete", fake_delete
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg=None)
    ctx = _ctx_for("app.example.com")
    teardown(ctx=ctx, keep_tunnel=False, seal=plan)


def test_show_with_seal_probes_even_when_zt_disabled(http_stub, monkeypatch):
    """Bug fix: shushu probe must run even when find_org returns None."""
    from cultureflare.cli._errors import EXIT_API, CfafiError

    # Program /access/organizations to return 9999 (Zero Trust not enabled).
    http_stub.set(
        "GET", "/accounts/acc-1/access/organizations",
        CfafiError(
            code=EXIT_API,
            message="CloudFlare API 9999: access.api.error.not_enabled: ...",
            remediation="...",
            cf_error_code=9999,
        ),
    )
    # Tunnel + DNS endpoints return empty — show is non-fatal.
    http_stub.set("GET", "/accounts/acc-1/cfd_tunnel", _empty_list())
    http_stub.set("GET", "/zones/zid-1/dns_records", _empty_list())

    probed: list = []

    def fake_probe(target):
        probed.append(target)
        return {"name": target.name, "hidden": True,
                "source": "cultureflare/remote-login"}

    monkeypatch.setattr(
        "cultureflare._secrets._shushu_sink.probe", fake_probe
    )

    plan = derive_seal_plan(hostname="app.example.com", shushu_arg="alice")
    ctx = _ctx_for("app.example.com")
    result = show(ctx=ctx, seal=plan)

    # ZT-side state is empty.
    assert result.team_domain is None
    # But shushu probe DID run for both targets.
    assert len(probed) == 2
    assert result.sealed_in_status["tunnel_token"]["present"] is True
    assert result.sealed_in_status["service_token_client_secret"]["present"] is True
