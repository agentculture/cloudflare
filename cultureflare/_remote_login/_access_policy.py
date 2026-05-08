"""CloudFlare Access allow-policy helpers."""

from __future__ import annotations

import cultureflare._api as _api
from cultureflare.cli._errors import EXIT_USER_ERROR, CfafiError


def build_include(*, emails: list[str], domains: list[str]) -> list[dict]:
    """Convert operator-supplied allow lists into Access include shapes.

    Domains may be passed with or without a leading '@'; we normalise
    by stripping it. We refuse an empty include list — an Access app
    with no allow rule blocks everyone.
    """
    if not emails and not domains:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message="at least one of --allow / --allow-domain is required",
            remediation="pass --allow user@example.com or --allow-domain @example.com",
        )
    include: list[dict] = [{"email": {"email": e}} for e in emails]
    for d in domains:
        normalised = d.lstrip("@")
        include.append({"email_domain": {"domain": normalised}})
    return include


def find_policy(*, account_id: str, app_id: str, name: str) -> dict | None:
    """Return the policy on the app whose .name matches, or None."""
    for pol in _api.paginate(
        f"/accounts/{account_id}/access/apps/{app_id}/policies"
    ):
        if pol.get("name") == name:
            return pol
    return None


def ensure_allow_policy(
    *,
    account_id: str,
    app_id: str,
    name: str,
    emails: list[str],
    domains: list[str],
) -> tuple[str, bool]:
    """Find or create an allow-policy on the Access app."""
    include = build_include(emails=emails, domains=domains)
    existing = find_policy(account_id=account_id, app_id=app_id, name=name)
    if existing is not None:
        return existing["id"], False
    response = _api.http_request(
        "POST",
        f"/accounts/{account_id}/access/apps/{app_id}/policies",
        payload={"name": name, "decision": "allow", "include": include},
    )
    return response["result"]["id"], True


def delete_policy(*, account_id: str, app_id: str, policy_id: str) -> None:
    """DELETE a policy on the Access app."""
    _api.http_request(
        "DELETE",
        f"/accounts/{account_id}/access/apps/{app_id}/policies/{policy_id}",
    )


def find_service_token_policy(
    *, account_id: str, app_id: str, token_id: str
) -> dict | None:
    """Return the non_identity policy admitting `token_id`, or None.

    Matches by *behavior* not by name: we look for any policy on the app
    whose ``decision == "non_identity"`` and whose ``include`` contains a
    ``service_token`` rule referencing ``token_id``. This way, an
    operator-renamed policy is still recognized as the one to skip.
    """
    for pol in _api.paginate(
        f"/accounts/{account_id}/access/apps/{app_id}/policies"
    ):
        if pol.get("decision") != "non_identity":
            continue
        for rule in pol.get("include") or []:
            svc = rule.get("service_token") or {}
            if svc.get("token_id") == token_id:
                return pol
    return None


def ensure_service_token_policy(
    *,
    account_id: str,
    app_id: str,
    token_id: str,
    name: str,
) -> tuple[str, bool]:
    """Find or create a non_identity allow-policy for a service token.

    Without such a policy, requests carrying ``CF-Access-Client-Id`` /
    ``CF-Access-Client-Secret`` are 302-redirected to SSO instead of
    being admitted (the meta JWT shows ``service_token_status: false``).
    """
    existing = find_service_token_policy(
        account_id=account_id, app_id=app_id, token_id=token_id,
    )
    if existing is not None:
        return existing["id"], False
    # No explicit ``precedence``: CF rejects two policies on the same
    # app sharing one (error 12130 "policy precedences must be unique").
    # The existing email allow-policy already holds precedence 1 in
    # most setups; let CF auto-assign rather than computing the next
    # free integer (racy with concurrent edits).
    response = _api.http_request(
        "POST",
        f"/accounts/{account_id}/access/apps/{app_id}/policies",
        payload={
            "name": name,
            "decision": "non_identity",
            "include": [
                {"service_token": {"token_id": token_id}},
            ],
        },
    )
    return response["result"]["id"], True
