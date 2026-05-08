"""CloudFlare Access service-token helpers.

Service tokens are the only one-shot-secret resource cultureflare creates.
``client_secret`` is returned exactly once, by the POST response;
list / get endpoints never expose it again.
"""

from __future__ import annotations

import cultureflare._api as _api
from cultureflare.cli._errors import EXIT_USER_ERROR, CfafiError


def find_service_token(*, account_id: str, name: str) -> dict | None:
    """Return the service-token record whose .name matches, or None."""
    for tok in _api.paginate(f"/accounts/{account_id}/access/service_tokens"):
        if tok.get("name") == name:
            return tok
    return None


def ensure_service_token(
    *, account_id: str, name: str, strict: bool
) -> tuple[str, str | None, bool, str | None]:
    """Find or create a service token.

    Returns (client_id, client_secret_or_None, created, token_id).
    The CF resource id (``token_id``) is distinct from the public
    ``client_id`` — only the resource id can be referenced from a
    non_identity policy's ``include[].service_token.token_id``.

    ``strict=True`` (used by setup with --with-service-token): if a
    token of this name already exists, raise — its secret can't be
    re-surfaced and the operator likely wanted a fresh one.

    ``strict=False`` (used by show/teardown planners and by setup
    after #28): return the existing record with secret=None and the
    full token_id, so an idempotent re-run can attach a missing
    non_identity policy without rotating the secret.
    """
    existing = find_service_token(account_id=account_id, name=name)
    if existing is not None:
        if strict:
            raise CfafiError(
                code=EXIT_USER_ERROR,
                message=(
                    f"service token {name!r} already exists; secret is not "
                    "retrievable"
                ),
                remediation=(
                    "pass --service-token-name=<other> or run "
                    "`cultureflare remote-login teardown --hostname <host> --apply` "
                    "first"
                ),
            )
        return (
            existing.get("client_id") or "",
            None,
            False,
            existing.get("id"),
        )

    response = _api.http_request(
        "POST",
        f"/accounts/{account_id}/access/service_tokens",
        payload={"name": name},
    )
    result = response.get("result") or {}
    return (
        result.get("client_id") or "",
        result.get("client_secret"),
        True,
        result.get("id"),
    )


def delete_service_token(*, account_id: str, token_id: str) -> None:
    """DELETE a service token by id."""
    _api.http_request(
        "DELETE", f"/accounts/{account_id}/access/service_tokens/{token_id}"
    )
