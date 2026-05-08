"""Tests for cultureflare._remote_login._service_token."""

import pytest

from cultureflare._remote_login._service_token import (
    find_service_token, ensure_service_token, delete_service_token,
)
from cultureflare.cli._errors import CfafiError, EXIT_USER_ERROR


def _list_envelope(*tokens):
    return {
        "success": True, "errors": [], "messages": [],
        "result": list(tokens),
        "result_info": {"page": 1, "total_pages": 1},
    }


def test_find_service_token_returns_record_when_present(http_stub):
    http_stub.queue(_list_envelope(
        {"id": "st-a", "name": "other-svc", "client_id": "cid-a"},
        {"id": "st-b", "name": "irc-svc", "client_id": "cid-b"},
    ))
    t = find_service_token(account_id="acc-1", name="irc-svc")
    assert t == {"id": "st-b", "name": "irc-svc", "client_id": "cid-b"}


def test_find_service_token_returns_none_when_missing(http_stub):
    http_stub.queue(_list_envelope())
    assert find_service_token(account_id="acc-1", name="missing") is None


def test_ensure_service_token_raises_when_existing_with_strict(http_stub):
    # strict=True means: existing token of this name is an error,
    # because we can't surface the (one-shot) secret.
    http_stub.queue(_list_envelope(
        {"id": "st-b", "name": "irc-svc", "client_id": "cid-b"},
    ))
    with pytest.raises(CfafiError) as exc:
        ensure_service_token(account_id="acc-1", name="irc-svc", strict=True)
    assert exc.value.code == EXIT_USER_ERROR
    assert "secret is not retrievable" in exc.value.message


def test_ensure_service_token_returns_existing_with_no_secret_when_lax(http_stub):
    # strict=False means: caller (e.g. teardown's planner) accepts
    # 'no secret available'. Returns the resource id so an idempotent
    # re-run can still attach a non_identity policy.
    http_stub.queue(_list_envelope(
        {"id": "st-b", "name": "irc-svc", "client_id": "cid-b"},
    ))
    cid, secret, created, token_id = ensure_service_token(
        account_id="acc-1", name="irc-svc", strict=False,
    )
    assert cid == "cid-b"
    assert secret is None
    assert created is False
    assert token_id == "st-b"


def test_ensure_service_token_posts_when_absent(http_stub):
    http_stub.queue(_list_envelope())
    http_stub.set("POST", "/accounts/acc-1/access/service_tokens", {
        "success": True, "errors": [], "messages": [],
        "result": {
            "id": "st-new", "name": "irc-svc",
            "client_id": "cid-new", "client_secret": "secret-shhh",
        },
    })
    cid, secret, created, token_id = ensure_service_token(
        account_id="acc-1", name="irc-svc", strict=True,
    )
    assert cid == "cid-new"
    assert secret == "secret-shhh"
    assert created is True
    assert token_id == "st-new"
    posts = [c for c in http_stub.calls if c[0] == "POST"]
    assert posts[0][2] == {"name": "irc-svc"}


def test_delete_service_token_calls_delete(http_stub):
    http_stub.set(
        "DELETE", "/accounts/acc-1/access/service_tokens/st-b",
        {"success": True, "errors": [], "messages": [], "result": {"id": "st-b"}},
    )
    delete_service_token(account_id="acc-1", token_id="st-b")
    assert http_stub.calls == [
        ("DELETE", "/accounts/acc-1/access/service_tokens/st-b", None, {}),
    ]
