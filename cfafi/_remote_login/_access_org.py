"""CloudFlare Access organization (Zero Trust) helpers."""

from __future__ import annotations

import cfafi._api as _api
from cfafi.cli._errors import EXIT_USER_ERROR, CfafiError


def find_org(*, account_id: str) -> dict | None:
    """Return the Access org dict, or None if Zero Trust is not enabled."""
    response = _api.http_request(
        "GET", f"/accounts/{account_id}/access/organizations"
    )
    return response.get("result") or None


def ensure_org(
    *, account_id: str, name: str, auth_domain: str
) -> tuple[str, bool]:
    """Find or create the Zero Trust organization.

    Returns (auth_domain, created). If an org exists with a *different*
    auth_domain than requested, raises EXIT_USER_ERROR rather than
    overwriting — operators reset Zero Trust from the dashboard, not
    from cfafi.
    """
    existing = find_org(account_id=account_id)
    if existing is not None:
        existing_domain = existing.get("auth_domain") or ""
        if existing_domain and existing_domain != auth_domain:
            raise CfafiError(
                code=EXIT_USER_ERROR,
                message=(
                    f"Zero Trust org already exists with auth_domain="
                    f"{existing_domain!r}, refusing to repoint to "
                    f"{auth_domain!r}"
                ),
                remediation=(
                    "align the requested auth_domain with the existing "
                    "org, or reset Zero Trust from the dashboard "
                    "(https://one.dash.cloudflare.com/?to=/:account/access)"
                ),
            )
        return existing.get("auth_domain") or auth_domain, False

    response = _api.http_request(
        "POST",
        f"/accounts/{account_id}/access/organizations",
        payload={"name": name, "auth_domain": auth_domain},
    )
    created = (response.get("result") or {})
    return created.get("auth_domain") or auth_domain, True
