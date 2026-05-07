"""Tests for cfafi._remote_login._preflight."""

import pytest

from cfafi._remote_login._preflight import check_token_alive
from cfafi.cli._errors import CfafiError, EXIT_AUTH


def _verify_response(*, status: str = "active") -> dict:
    """Mirror the real `/user/tokens/verify` envelope.

    The real CF response only carries id/status/not_before/expires_on
    under `result`. There is no `policies` field — that's why this
    module dropped strict scope validation; see the module docstring.
    """
    return {
        "success": True, "errors": [], "messages": [],
        "result": {
            "id": "tok-1",
            "status": status,
            "not_before": "2026-01-01T00:00:00Z",
            "expires_on": "2027-01-01T00:00:00Z",
        },
    }


def test_passes_when_token_status_active(http_stub):
    http_stub.queue(_verify_response(status="active"))
    # Should not raise.
    check_token_alive()


def test_raises_when_token_status_inactive(http_stub):
    http_stub.queue(_verify_response(status="disabled"))
    with pytest.raises(CfafiError) as exc:
        check_token_alive()
    assert exc.value.code == EXIT_AUTH
    assert "'disabled'" in exc.value.message
    assert "rotate or replace" in (exc.value.remediation or "")


def test_raises_when_status_missing(http_stub):
    # Real CF will always include `status`; this guards against a
    # malformed envelope (e.g. proxy or fixture mistake).
    http_stub.queue({"success": True, "errors": [], "messages": [], "result": {}})
    with pytest.raises(CfafiError) as exc:
        check_token_alive()
    assert exc.value.code == EXIT_AUTH
