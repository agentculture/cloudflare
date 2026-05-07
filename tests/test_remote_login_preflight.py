"""Tests for cfafi._remote_login._preflight."""

import pytest

from cfafi._remote_login._preflight import check_token_scopes
from cfafi.cli._errors import CfafiError, EXIT_AUTH


def _verify_response(*scope_names: str) -> dict:
    return {
        "success": True, "errors": [], "messages": [],
        "result": {
            "id": "tok-1",
            "status": "active",
            "policies": [{
                "permission_groups": [{"name": s} for s in scope_names],
                "resources": {},
            }],
        },
    }


def test_passes_when_all_required_scopes_present(http_stub):
    http_stub.queue(_verify_response(
        "Cloudflare Tunnel Write",
        "Access: Apps and Policies Write",
        "Access: Organizations Write",
        "DNS Write",
    ))
    # Should not raise.
    check_token_scopes(operation="setup", with_service_token=False)


def test_passes_when_with_service_token_and_st_scope_present(http_stub):
    http_stub.queue(_verify_response(
        "Cloudflare Tunnel Write",
        "Access: Apps and Policies Write",
        "Access: Service Tokens Write",
        "Access: Organizations Write",
        "DNS Write",
    ))
    check_token_scopes(operation="setup", with_service_token=True)


def test_raises_when_required_scope_missing(http_stub):
    http_stub.queue(_verify_response("DNS Write"))  # missing tunnel + access
    with pytest.raises(CfafiError) as exc:
        check_token_scopes(operation="setup", with_service_token=False)
    assert exc.value.code == EXIT_AUTH
    assert "Cloudflare Tunnel Write" in exc.value.message


def test_show_only_requires_read_scopes(http_stub):
    http_stub.queue(_verify_response(
        "Cloudflare Tunnel Read",
        "Access: Apps and Policies Read",
        "DNS Read",
    ))
    check_token_scopes(operation="show", with_service_token=False)


def test_teardown_does_not_require_organizations_write(http_stub):
    # We never delete the ZT org, so teardown shouldn't demand that scope.
    http_stub.queue(_verify_response(
        "Cloudflare Tunnel Write",
        "Access: Apps and Policies Write",
        "DNS Write",
    ))
    check_token_scopes(operation="teardown", with_service_token=False)
