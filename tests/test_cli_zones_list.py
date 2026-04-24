"""Tests for `cfafi zones list`."""

import json

from cfafi.cli import main


def test_zones_list_markdown(http_stub, capsys):
    http_stub.queue({
        "success": True, "errors": [], "messages": [],
        "result": [
            {"id": "z1", "name": "culture.dev", "status": "active", "plan": {"name": "Free Website"}},  # noqa: E501
            {"id": "z2", "name": "agentirc.dev", "status": "active", "plan": {"name": "Free Website"}},  # noqa: E501
        ],
        "result_info": {"page": 1, "total_pages": 1, "count": 2, "total_count": 2},
    })
    rc = main(["zones", "list"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "## Zones (2)" in out
    assert "| ID | NAME | STATUS | PLAN |" in out
    assert "| z1 | culture.dev | active | Free Website |" in out
    assert "| z2 | agentirc.dev | active | Free Website |" in out


def test_zones_list_json_wraps_paginated_result(http_stub, capsys):
    http_stub.queue(
        {
            "success": True, "errors": [], "messages": [],
            "result": [{"id": "z1", "name": "culture.dev", "status": "active", "plan": {"name": "Free"}}],  # noqa: E501
            "result_info": {"page": 1, "total_pages": 2, "count": 1, "total_count": 2},
        },
        {
            "success": True, "errors": [], "messages": [],
            "result": [{"id": "z2", "name": "agentirc.dev", "status": "active", "plan": {"name": "Free"}}],  # noqa: E501
            "result_info": {"page": 2, "total_pages": 2, "count": 1, "total_count": 2},
        },
    )
    rc = main(["zones", "list", "--json"])
    out = capsys.readouterr().out
    assert rc == 0
    payload = json.loads(out)
    assert payload["success"] is True
    assert [z["id"] for z in payload["result"]] == ["z1", "z2"]
    assert payload["result_info"]["total_count"] == 2


def test_zones_list_empty(http_stub, capsys):
    http_stub.queue({
        "success": True, "errors": [], "messages": [],
        "result": [],
        "result_info": {"page": 1, "total_pages": 1, "count": 0, "total_count": 0},
    })
    rc = main(["zones", "list"])
    out = capsys.readouterr().out
    assert rc == 0
    assert "## Zones (0)" in out


def test_zones_list_walks_pagination(http_stub):
    http_stub.queue(
        {"result": [{"id": "a"}], "result_info": {"page": 1, "total_pages": 2}},
        {"result": [{"id": "b"}], "result_info": {"page": 2, "total_pages": 2}},
    )
    main(["zones", "list", "--json"])
    pages = [call[3].get("page") for call in http_stub.calls]
    assert pages == [1, 2]
