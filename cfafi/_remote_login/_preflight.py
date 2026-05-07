"""Pre-flight token-alive check.

CloudFlare's ``GET /user/tokens/verify`` returns ``id`` / ``status`` /
``not_before`` / ``expires_on`` — no ``policies`` field exposing
granted scopes. We can't strictly preflight scope correctness from
that endpoint, so we settle for a liveness check: confirm the token
exists and is ``active``. If the token is missing a scope the
orchestrator needs, the resulting 403 surfaces through the standard
:class:`CfafiError` ``EXIT_AUTH`` path, whose remediation points at
``docs/SETUP.md § Operator token scopes``.
"""

from __future__ import annotations

import cfafi._api as _api
from cfafi.cli._errors import EXIT_AUTH, CfafiError


def check_token_alive() -> None:
    """Raise ``CfafiError(EXIT_AUTH)`` if the configured token is not active."""
    response = _api.http_request("GET", "/user/tokens/verify")
    result = response.get("result") or {}
    status = result.get("status")
    if status != "active":
        raise CfafiError(
            code=EXIT_AUTH,
            message=(
                f"CLOUDFLARE_API_TOKEN status is {status!r}, expected 'active'"
            ),
            remediation=(
                "rotate or replace the token (My Profile → API Tokens). "
                "See docs/SETUP.md § Operator token scopes for the scope "
                "list `remote-login` needs."
            ),
        )
