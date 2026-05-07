"""Tests for cfafi._remote_login._dns."""

import pytest

from cfafi._remote_login._dns import find_cname, ensure_cname, delete_cname
from cfafi.cli._errors import CfafiError, EXIT_USER_ERROR


def _list_envelope(*records):
    return {
        "success": True, "errors": [], "messages": [],
        "result": list(records),
        "result_info": {"page": 1, "total_pages": 1},
    }


def test_find_cname_returns_record_when_present(http_stub):
    http_stub.queue(_list_envelope({
        "id": "rec-1", "type": "CNAME", "name": "irc.culture.dev",
        "content": "tun-b.cfargotunnel.com", "proxied": True,
    }))
    rec = find_cname(zone_id="zid-1", hostname="irc.culture.dev")
    assert rec == {
        "id": "rec-1", "type": "CNAME", "name": "irc.culture.dev",
        "content": "tun-b.cfargotunnel.com", "proxied": True,
    }


def test_find_cname_returns_none_when_no_record(http_stub):
    http_stub.queue(_list_envelope())
    assert find_cname(zone_id="zid-1", hostname="irc.culture.dev") is None


def test_ensure_cname_returns_existing_when_target_matches(http_stub):
    http_stub.queue(_list_envelope({
        "id": "rec-1", "type": "CNAME", "name": "irc.culture.dev",
        "content": "tun-b.cfargotunnel.com", "proxied": True,
    }))
    rid, created = ensure_cname(
        zone_id="zid-1", hostname="irc.culture.dev", tunnel_id="tun-b",
    )
    assert rid == "rec-1"
    assert created is False
    assert [c for c in http_stub.calls if c[0] == "POST"] == []


def test_ensure_cname_raises_when_existing_points_at_tunnel_but_unproxied(http_stub):
    http_stub.queue(_list_envelope({
        "id": "rec-1", "type": "CNAME", "name": "irc.culture.dev",
        "content": "tun-b.cfargotunnel.com", "proxied": False,
    }))
    with pytest.raises(CfafiError) as exc:
        ensure_cname(
            zone_id="zid-1", hostname="irc.culture.dev", tunnel_id="tun-b",
        )
    assert exc.value.code == EXIT_USER_ERROR
    assert "unproxied" in exc.value.message
    assert "Access" in exc.value.message


def test_ensure_cname_raises_when_existing_points_elsewhere(http_stub):
    http_stub.queue(_list_envelope({
        "id": "rec-1", "type": "CNAME", "name": "irc.culture.dev",
        "content": "other.example.com", "proxied": True,
    }))
    with pytest.raises(CfafiError) as exc:
        ensure_cname(
            zone_id="zid-1", hostname="irc.culture.dev", tunnel_id="tun-b",
        )
    assert exc.value.code == EXIT_USER_ERROR
    assert "other.example.com" in exc.value.message


def test_ensure_cname_posts_when_absent(http_stub):
    http_stub.queue(_list_envelope())
    http_stub.set("POST", "/zones/zid-1/dns_records", {
        "success": True, "errors": [], "messages": [],
        "result": {
            "id": "rec-new", "type": "CNAME", "name": "irc.culture.dev",
            "content": "tun-b.cfargotunnel.com", "proxied": True,
        },
    })
    rid, created = ensure_cname(
        zone_id="zid-1", hostname="irc.culture.dev", tunnel_id="tun-b",
    )
    assert rid == "rec-new"
    assert created is True
    posts = [c for c in http_stub.calls if c[0] == "POST"]
    assert len(posts) == 1
    assert posts[0][2]["type"] == "CNAME"
    assert posts[0][2]["name"] == "irc.culture.dev"
    assert posts[0][2]["content"] == "tun-b.cfargotunnel.com"
    assert posts[0][2]["proxied"] is True
    assert posts[0][2]["ttl"] == 1


def test_delete_cname_calls_delete_with_record_id(http_stub):
    http_stub.set(
        "DELETE", "/zones/zid-1/dns_records/rec-1",
        {"success": True, "errors": [], "messages": [], "result": {"id": "rec-1"}},
    )
    delete_cname(zone_id="zid-1", record_id="rec-1")
    assert http_stub.calls == [("DELETE", "/zones/zid-1/dns_records/rec-1", None, {})]
