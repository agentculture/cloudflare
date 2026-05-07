"""Pre-flight token-scope validation.

CloudFlare permission-group names (as returned by
``/user/tokens/verify``) are stable strings; we hard-code the ones we
care about. If a future scope rename happens upstream we'll see the
mismatch in tests before it bites operators.
"""

from __future__ import annotations

from typing import Literal

import cfafi._api as _api
from cfafi.cli._errors import EXIT_AUTH, CfafiError

Operation = Literal["setup", "show", "teardown"]

# Required permission-group names per operation. Read scopes suffice
# for `show`; everything else needs Write.
_REQUIRED: dict[Operation, set[str]] = {
    "setup": {
        "Cloudflare Tunnel Write",
        "Access: Apps and Policies Write",
        "Access: Organizations Write",
        "DNS Write",
    },
    "show": {
        "Cloudflare Tunnel Read",
        "Access: Apps and Policies Read",
        "DNS Read",
    },
    "teardown": {
        "Cloudflare Tunnel Write",
        "Access: Apps and Policies Write",
        "DNS Write",
    },
}

_SERVICE_TOKEN_SCOPE = "Access: Service Tokens Write"


def _granted_scopes(verify_response: dict) -> set[str]:
    result = verify_response.get("result") or {}
    policies = result.get("policies") or []
    out: set[str] = set()
    for pol in policies:
        for pg in pol.get("permission_groups") or []:
            name = pg.get("name")
            if name:
                out.add(name)
    return out


def check_token_scopes(*, operation: Operation, with_service_token: bool) -> None:
    """Raise CfafiError(EXIT_AUTH) if the configured token lacks any scope.

    Calls ``GET /user/tokens/verify`` once and walks the response.
    """
    response = _api.http_request("GET", "/user/tokens/verify")
    granted = _granted_scopes(response)
    required = set(_REQUIRED[operation])
    if operation == "setup" and with_service_token:
        required.add(_SERVICE_TOKEN_SCOPE)

    missing = sorted(required - granted)
    if missing:
        raise CfafiError(
            code=EXIT_AUTH,
            message=(
                "configured CLOUDFLARE_API_TOKEN is missing required scopes: "
                + ", ".join(missing)
            ),
            remediation=(
                "mint a token with these permission groups in the CloudFlare "
                "dashboard (My Profile → API Tokens → Create Token → "
                "Custom token). See docs/SETUP.md § Operator token scopes."
            ),
        )
