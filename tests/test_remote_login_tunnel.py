"""Tests for cultureflare._remote_login._tunnel."""

import pytest

from cultureflare._remote_login._tunnel import (
    delete_tunnel, ensure_tunnel, ensure_tunnel_config,
    find_tunnel, get_tunnel_config, get_tunnel_token,
)


def _list_envelope(*tunnels):
    return {
        "success": True, "errors": [], "messages": [],
        "result": list(tunnels),
        "result_info": {"page": 1, "total_pages": 1},
    }


def test_find_tunnel_returns_id_when_name_matches(http_stub):
    http_stub.queue(_list_envelope(
        {"id": "tun-a", "name": "other"},
        {"id": "tun-b", "name": "irc-culture-dev"},
    ))
    t = find_tunnel(account_id="acc-1", name="irc-culture-dev")
    assert t == {"id": "tun-b", "name": "irc-culture-dev"}


def test_find_tunnel_returns_none_when_no_match(http_stub):
    http_stub.queue(_list_envelope({"id": "tun-a", "name": "other"}))
    assert find_tunnel(account_id="acc-1", name="missing") is None


def test_find_tunnel_lists_with_is_deleted_false(http_stub):
    http_stub.queue(_list_envelope())
    find_tunnel(account_id="acc-1", name="x")
    method, path, _, query = http_stub.calls[0]
    assert method == "GET"
    assert path == "/accounts/acc-1/cfd_tunnel"
    assert query.get("is_deleted") == "false"


def test_ensure_tunnel_returns_existing(http_stub):
    http_stub.queue(_list_envelope({"id": "tun-b", "name": "irc-culture-dev"}))
    tid, created = ensure_tunnel(account_id="acc-1", name="irc-culture-dev")
    assert tid == "tun-b"
    assert created is False
    posts = [c for c in http_stub.calls if c[0] == "POST"]
    assert posts == []


def test_ensure_tunnel_posts_when_absent(http_stub):
    http_stub.queue(_list_envelope())
    http_stub.set("POST", "/accounts/acc-1/cfd_tunnel", {
        "success": True, "errors": [], "messages": [],
        "result": {"id": "tun-new", "name": "irc-culture-dev"},
    })
    tid, created = ensure_tunnel(account_id="acc-1", name="irc-culture-dev")
    assert tid == "tun-new"
    assert created is True
    posts = [c for c in http_stub.calls if c[0] == "POST"]
    assert len(posts) == 1
    assert posts[0][2] == {"name": "irc-culture-dev", "config_src": "cloudflare"}


def test_get_tunnel_token_returns_runtime_token(http_stub):
    http_stub.set(
        "GET", "/accounts/acc-1/cfd_tunnel/tun-b/token",
        {"success": True, "errors": [], "messages": [], "result": "eyJrIjoiZm9vIn0="},
    )
    assert get_tunnel_token(account_id="acc-1", tunnel_id="tun-b") == "eyJrIjoiZm9vIn0="


def test_delete_tunnel_passes_force_true(http_stub):
    http_stub.set(
        "DELETE", "/accounts/acc-1/cfd_tunnel/tun-b",
        {"success": True, "errors": [], "messages": [], "result": {"id": "tun-b"}},
    )
    delete_tunnel(account_id="acc-1", tunnel_id="tun-b")
    method, path, _, query = http_stub.calls[0]
    assert method == "DELETE"
    assert path == "/accounts/acc-1/cfd_tunnel/tun-b"
    assert query.get("force") == "true"


# ---------------------------------------------------------------------------
# Tunnel ingress configuration (#28)
# ---------------------------------------------------------------------------

_TUNNEL_CFG_PATH = "/accounts/acc-1/cfd_tunnel/tun-b/configurations"


def _config_envelope(ingress):
    return {
        "success": True, "errors": [], "messages": [],
        "result": {"config": {"ingress": ingress}},
    }


def test_get_tunnel_config_returns_result_envelope(http_stub):
    http_stub.set("GET", _TUNNEL_CFG_PATH, _config_envelope([
        {"hostname": "x.example.com", "service": "http://localhost:80"},
        {"service": "http_status:404"},
    ]))
    cfg = get_tunnel_config(account_id="acc-1", tunnel_id="tun-b")
    assert cfg is not None
    rules = cfg["config"]["ingress"]
    assert rules[0]["hostname"] == "x.example.com"


def test_ensure_tunnel_config_skips_when_ingress_already_matches(http_stub):
    http_stub.set("GET", _TUNNEL_CFG_PATH, _config_envelope([
        {"hostname": "x.example.com", "service": "http://localhost:8080"},
        {"service": "http_status:404"},
    ]))
    changed = ensure_tunnel_config(
        account_id="acc-1", tunnel_id="tun-b",
        hostname="x.example.com", service="http://localhost:8080",
    )
    assert changed is False
    assert [c[0] for c in http_stub.calls] == ["GET"]


def test_ensure_tunnel_config_puts_when_no_ingress(http_stub):
    """The exact bug from issue #28 — tunnel created but no ingress rule."""
    http_stub.set("GET", _TUNNEL_CFG_PATH, _config_envelope([]))
    http_stub.set("PUT", _TUNNEL_CFG_PATH, _config_envelope([
        {"hostname": "x.example.com", "service": "http://localhost:8080"},
        {"service": "http_status:404"},
    ]))
    changed = ensure_tunnel_config(
        account_id="acc-1", tunnel_id="tun-b",
        hostname="x.example.com", service="http://localhost:8080",
    )
    assert changed is True
    puts = [c for c in http_stub.calls if c[0] == "PUT"]
    assert len(puts) == 1
    payload = puts[0][2]
    rules = payload["config"]["ingress"]
    assert rules[0] == {"hostname": "x.example.com", "service": "http://localhost:8080"}
    assert rules[-1] == {"service": "http_status:404"}


def test_ensure_tunnel_config_overwrites_stale_ingress(http_stub):
    """Existing ingress points at the wrong service — overwrite."""
    http_stub.set("GET", _TUNNEL_CFG_PATH, _config_envelope([
        {"hostname": "x.example.com", "service": "http://localhost:9999"},
        {"service": "http_status:404"},
    ]))
    http_stub.set("PUT", _TUNNEL_CFG_PATH, _config_envelope([
        {"hostname": "x.example.com", "service": "http://localhost:8080"},
        {"service": "http_status:404"},
    ]))
    changed = ensure_tunnel_config(
        account_id="acc-1", tunnel_id="tun-b",
        hostname="x.example.com", service="http://localhost:8080",
    )
    assert changed is True


def test_ensure_tunnel_config_preserves_other_config_keys(http_stub):
    """Don't clobber operator-set warp-routing / originRequest etc.

    The PUT endpoint is replace-not-merge — omitting a key resets it.
    Bug #28 follow-up from qodo review on PR #30.
    """
    http_stub.set("GET", _TUNNEL_CFG_PATH, {
        "success": True, "errors": [], "messages": [],
        "result": {
            "version": 7,
            "config": {
                "ingress": [{"service": "http_status:404"}],
                "warp-routing": {"enabled": True},
                "originRequest": {"connectTimeout": 30},
            },
        },
    })
    http_stub.set("PUT", _TUNNEL_CFG_PATH, _config_envelope([]))
    ensure_tunnel_config(
        account_id="acc-1", tunnel_id="tun-b",
        hostname="x.example.com", service="http://localhost:8080",
    )
    puts = [c for c in http_stub.calls if c[0] == "PUT"]
    payload = puts[0][2]
    cfg = payload["config"]
    # New ingress applied
    assert cfg["ingress"][0] == {
        "hostname": "x.example.com", "service": "http://localhost:8080",
    }
    # Other keys preserved verbatim
    assert cfg["warp-routing"] == {"enabled": True}
    assert cfg["originRequest"] == {"connectTimeout": 30}


def test_ensure_tunnel_config_overwrites_when_hostname_mismatch(http_stub):
    http_stub.set("GET", _TUNNEL_CFG_PATH, _config_envelope([
        {"hostname": "old.example.com", "service": "http://localhost:8080"},
        {"service": "http_status:404"},
    ]))
    http_stub.set("PUT", _TUNNEL_CFG_PATH, _config_envelope([]))
    changed = ensure_tunnel_config(
        account_id="acc-1", tunnel_id="tun-b",
        hostname="x.example.com", service="http://localhost:8080",
    )
    assert changed is True
