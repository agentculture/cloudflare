"""Tests for `cfafi dns create`."""

import json

from cfafi.cli import main
from cfafi.cli._errors import EXIT_USER_ERROR


def _zones_envelope(*names_ids):
    return {
        "success": True, "errors": [], "messages": [],
        "result": [{"id": i, "name": n} for n, i in names_ids],
        "result_info": {"page": 1, "total_pages": 1},
    }


def _empty_dns_lookup():
    return {
        "success": True, "errors": [], "messages": [],
        "result": [],
        "result_info": {"page": 1, "total_pages": 1},
    }


def test_dns_create_dry_run_prints_preview_without_posting(http_stub, capsys):
    http_stub.queue(
        _zones_envelope(("culture.dev", "zid-1")),
        _empty_dns_lookup(),
    )
    rc = main(["dns", "create", "culture.dev", "TXT", "_cfafi-test", "hello"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "Dry-run" in out
    assert "would POST" in out and "/zones/zid-1/dns_records" in out
    assert '"type": "TXT"' in out
    assert '"name": "_cfafi-test"' in out
    assert '"content": "hello"' in out
    methods = [c[0] for c in http_stub.calls]
    assert "POST" not in methods  # never commits in dry-run


def test_dns_create_apply_posts_record(http_stub, capsys):
    http_stub.queue(
        _zones_envelope(("culture.dev", "zid-1")),
        _empty_dns_lookup(),
    )
    http_stub.set("POST", "/zones/zid-1/dns_records", {
        "success": True, "errors": [], "messages": [],
        "result": {"id": "rec-123", "type": "TXT", "name": "_cfafi-test", "content": "hello"},
    })
    rc = main(["dns", "create", "culture.dev", "TXT", "_cfafi-test", "hello", "--apply"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "DNS record created" in out
    assert "rec-123" in out
    posts = [c for c in http_stub.calls if c[0] == "POST"]
    assert len(posts) == 1
    assert posts[0][1] == "/zones/zid-1/dns_records"
    assert posts[0][2]["type"] == "TXT"
    assert posts[0][2]["name"] == "_cfafi-test"
    assert posts[0][2]["content"] == "hello"
    assert posts[0][2]["proxied"] is False
    assert posts[0][2]["ttl"] == 1


def test_dns_create_json_dry_run(http_stub, capsys):
    http_stub.queue(
        _zones_envelope(("culture.dev", "zid-1")),
        _empty_dns_lookup(),
    )
    rc = main(["dns", "create", "culture.dev", "A", "www", "192.0.2.1", "--json"])
    out = capsys.readouterr().out
    assert rc == 0
    payload = json.loads(out)
    assert payload["success"] is True
    assert payload["result"]["dry_run"] is True
    assert payload["result"]["zone_id"] == "zid-1"
    assert payload["result"]["would_post"]["type"] == "A"


def test_dns_create_zone_not_found(http_stub, capsys):
    http_stub.queue(_zones_envelope(("other.dev", "zid-9")))
    rc = main(["dns", "create", "culture.dev", "A", "www", "203.0.113.10"])
    err = capsys.readouterr().err
    assert rc != 0
    assert "culture.dev" in err and "not found" in err


def test_dns_create_idempotency_existing_record(http_stub, capsys):
    http_stub.queue(
        _zones_envelope(("culture.dev", "zid-1")),
        {
            "success": True, "errors": [], "messages": [],
            "result": [{"id": "rec-existing", "type": "A", "name": "www.culture.dev", "content": "203.0.113.10"}],  # noqa: E501
            "result_info": {"page": 1, "total_pages": 1},
        },
    )
    rc = main(["dns", "create", "culture.dev", "A", "www", "203.0.113.10"])
    err = capsys.readouterr().err
    assert rc != 0
    assert "already exists" in err
    assert "rec-existing" in err


def test_dns_create_unsupported_type_rejected(capsys):
    rc = main(["dns", "create", "culture.dev", "BOGUS", "name", "value"])
    err = capsys.readouterr().err
    assert rc == EXIT_USER_ERROR
    assert "unsupported record type" in err


def test_dns_create_passes_raw_lookup_fields_for_url_encoding(http_stub):
    """The command hands type/name/content to paginate() unencoded; the
    actual URL-encoding happens inside _api.http_request. Verify the
    lookup call carries the raw strings plus match=all.
    """
    http_stub.queue(
        _zones_envelope(("culture.dev", "zid-1")),
        _empty_dns_lookup(),
    )
    main(["dns", "create", "culture.dev", "TXT", "weird name", "a=b&c"])
    gets = [c for c in http_stub.calls if c[0] == "GET" and c[1] == "/zones/zid-1/dns_records"]
    assert len(gets) == 1
    q = gets[0][3]
    assert q["type"] == "TXT"
    assert q["name"] == "weird name"
    assert q["content"] == "a=b&c"
    assert q["match"] == "all"


def test_dns_create_proxied_flag(http_stub, capsys):
    http_stub.queue(
        _zones_envelope(("culture.dev", "zid-1")),
        _empty_dns_lookup(),
    )
    http_stub.set("POST", "/zones/zid-1/dns_records", {
        "success": True, "result": {"id": "rec-1"},
    })
    main(["dns", "create", "culture.dev", "A", "www", "192.0.2.1", "--proxied", "--apply"])
    posts = [c for c in http_stub.calls if c[0] == "POST"]
    assert posts[0][2]["proxied"] is True


def test_dns_create_proxied_with_manual_ttl_rejected(capsys):
    rc = main(["dns", "create", "culture.dev", "A", "x", "203.0.113.10", "--proxied", "--ttl=300"])
    err = capsys.readouterr().err
    assert rc == EXIT_USER_ERROR
    assert "proxied" in err and "ttl" in err.lower()
