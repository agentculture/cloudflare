"""Tests for cfafi._api."""

import io
import json
import urllib.error
from unittest.mock import MagicMock, patch

import pytest

from cfafi._api import CF_API_BASE, http_request, paginate
from cfafi.cli._errors import EXIT_API, EXIT_AUTH, CfafiError


@pytest.fixture(autouse=True)
def _token_env(monkeypatch):
    monkeypatch.setenv("CLOUDFLARE_API_TOKEN", "test-token")


def _ok_resp(payload):
    resp = MagicMock()
    resp.read.return_value = json.dumps(payload).encode("utf-8")
    resp.__enter__.return_value = resp
    resp.__exit__.return_value = False
    return resp


def test_http_request_sends_bearer_token_and_parses_json():
    payload = {"success": True, "result": {"id": "abc"}}
    with patch("cfafi._api.urllib.request.urlopen", return_value=_ok_resp(payload)) as mock:
        out = http_request("GET", "/user/tokens/verify")
    assert out == payload
    req = mock.call_args[0][0]
    assert req.full_url == f"{CF_API_BASE}/user/tokens/verify"
    assert req.get_header("Authorization") == "Bearer test-token"
    assert req.get_method() == "GET"


def test_http_request_encodes_query_string():
    with patch("cfafi._api.urllib.request.urlopen", return_value=_ok_resp({"success": True})) as mock:  # noqa: E501
        http_request("GET", "/zones", query={"name": "culture.dev", "page": 2})
    url = mock.call_args[0][0].full_url
    assert "name=culture.dev" in url and "page=2" in url


def test_http_request_sends_json_payload_on_post():
    with patch("cfafi._api.urllib.request.urlopen", return_value=_ok_resp({"success": True})) as mock:  # noqa: E501
        http_request("POST", "/zones/zid/dns_records", payload={"type": "A", "name": "x"})
    req = mock.call_args[0][0]
    assert req.get_method() == "POST"
    assert req.get_header("Content-type") == "application/json"
    assert json.loads(req.data.decode("utf-8")) == {"type": "A", "name": "x"}


def test_http_request_raises_cfafi_auth_error_on_401():
    err_body = json.dumps({"success": False, "errors": [{"code": 10000, "message": "bad token"}]})
    http_err = urllib.error.HTTPError(
        url="x", code=401, msg="Unauthorized", hdrs=None, fp=io.BytesIO(err_body.encode()),
    )
    with patch("cfafi._api.urllib.request.urlopen", side_effect=http_err):
        with pytest.raises(CfafiError) as excinfo:
            http_request("GET", "/zones")
    assert excinfo.value.code == EXIT_AUTH
    assert "10000" in excinfo.value.message or "bad token" in excinfo.value.message


def test_http_request_raises_cfafi_api_error_on_400():
    err_body = json.dumps({"success": False, "errors": [{"code": 1004, "message": "invalid"}]})
    http_err = urllib.error.HTTPError(
        url="x", code=400, msg="Bad Request", hdrs=None, fp=io.BytesIO(err_body.encode()),
    )
    with patch("cfafi._api.urllib.request.urlopen", side_effect=http_err):
        with pytest.raises(CfafiError) as excinfo:
            http_request("GET", "/zones")
    assert excinfo.value.code == EXIT_API
    assert "1004" in excinfo.value.message or "invalid" in excinfo.value.message


def test_paginate_walks_until_total_pages():
    calls = []

    def fake(method, path, *, payload=None, query=None):
        calls.append(dict(query or {}))
        if query.get("page") == 1:
            return {
                "result": [{"id": "a"}, {"id": "b"}],
                "result_info": {"page": 1, "total_pages": 2},
            }
        return {
            "result": [{"id": "c"}],
            "result_info": {"page": 2, "total_pages": 2},
        }

    with patch("cfafi._api.http_request", side_effect=fake):
        rows = list(paginate("/zones"))
    assert [r["id"] for r in rows] == ["a", "b", "c"]
    assert [c.get("page") for c in calls] == [1, 2]


def test_paginate_single_page():
    def fake(method, path, *, payload=None, query=None):
        return {"result": [{"id": "only"}], "result_info": {"page": 1, "total_pages": 1}}

    with patch("cfafi._api.http_request", side_effect=fake):
        rows = list(paginate("/zones"))
    assert [r["id"] for r in rows] == ["only"]


def test_paginate_empty_result():
    def fake(method, path, *, payload=None, query=None):
        return {"result": [], "result_info": {"page": 1, "total_pages": 1}}

    with patch("cfafi._api.http_request", side_effect=fake):
        assert list(paginate("/zones")) == []


def test_paginate_preserves_caller_query():
    calls = []

    def fake(method, path, *, payload=None, query=None):
        calls.append(dict(query or {}))
        return {"result": [], "result_info": {"page": 1, "total_pages": 1}}

    with patch("cfafi._api.http_request", side_effect=fake):
        list(paginate("/zones/z/dns_records", query={"type": "A"}))
    assert calls[0]["type"] == "A"
    assert calls[0]["page"] == 1


def test_http_request_wraps_transport_failure_as_api_error():
    """A urllib.error.URLError (DNS, TLS, timeout) becomes EXIT_API with a
    transport-failure message — agents should see a remediation pointing
    at network connectivity, not an auth error or a python traceback.
    """
    transport_err = urllib.error.URLError("Name or service not known")
    with patch("cfafi._api.urllib.request.urlopen", side_effect=transport_err):
        with pytest.raises(CfafiError) as excinfo:
            http_request("GET", "/zones")
    assert excinfo.value.code == EXIT_API
    assert "transport failure" in excinfo.value.message
    assert "Name or service not known" in excinfo.value.message
    assert "network" in excinfo.value.remediation.lower()


def test_http_request_handles_non_json_error_body():
    """If CloudFlare's CDN returns an HTML 503 page instead of the usual
    JSON envelope, we still raise CfafiError with EXIT_API rather than
    crashing in json.loads.
    """
    html_body = b"<html><body>503 Service Unavailable</body></html>"
    http_err = urllib.error.HTTPError(
        url="x", code=503, msg="Service Unavailable", hdrs=None, fp=io.BytesIO(html_body),
    )
    with patch("cfafi._api.urllib.request.urlopen", side_effect=http_err):
        with pytest.raises(CfafiError) as excinfo:
            http_request("GET", "/zones")
    assert excinfo.value.code == EXIT_API
    assert "503" in excinfo.value.message
