"""CNAME helpers for the remote-login orchestrator."""

from __future__ import annotations

import cfafi._api as _api
from cfafi.cli._errors import EXIT_USER_ERROR, CfafiError


def find_cname(*, zone_id: str, hostname: str) -> dict | None:
    """Return the CNAME record at hostname, or None."""
    for rec in _api.paginate(
        f"/zones/{zone_id}/dns_records",
        query={"type": "CNAME", "name": hostname},
    ):
        return rec
    return None


def ensure_cname(
    *, zone_id: str, hostname: str, tunnel_id: str
) -> tuple[str, bool]:
    """Find or create a proxied CNAME hostname → <tunnel_id>.cfargotunnel.com.

    Raises EXIT_USER_ERROR if an existing CNAME at hostname points
    somewhere else (we refuse to repoint; that's a teardown decision).
    """
    target = f"{tunnel_id}.cfargotunnel.com"
    existing = find_cname(zone_id=zone_id, hostname=hostname)
    if existing is not None:
        if existing.get("content") != target:
            raise CfafiError(
                code=EXIT_USER_ERROR,
                message=(
                    f"DNS CNAME at {hostname} already points to "
                    f"{existing.get('content')!r} — refusing to repoint to "
                    f"{target!r}"
                ),
                remediation=(
                    f"run `cfafi remote-login teardown --hostname {hostname} "
                    f"--apply` first, or change the record in the dashboard"
                ),
            )
        # Access requires proxied=True. An unproxied CNAME pointing at
        # the right tunnel is a silent misconfiguration — traffic would
        # bypass Access. Refuse rather than declare success.
        if not existing.get("proxied"):
            raise CfafiError(
                code=EXIT_USER_ERROR,
                message=(
                    f"DNS CNAME at {hostname} points to the right tunnel "
                    f"but is unproxied; Access requires proxied (orange cloud)"
                ),
                remediation=(
                    f"flip the record to proxied in the dashboard, or run "
                    f"`cfafi remote-login teardown --hostname {hostname} "
                    f"--apply` and re-run setup"
                ),
            )
        return existing["id"], False

    body = {
        "type": "CNAME",
        "name": hostname,
        "content": target,
        "ttl": 1,
        "proxied": True,
        "comment": f"Managed by cfafi remote-login for {hostname}",
    }
    response = _api.http_request(
        "POST", f"/zones/{zone_id}/dns_records", payload=body
    )
    return response["result"]["id"], True


def delete_cname(*, zone_id: str, record_id: str) -> None:
    """DELETE the DNS record by id."""
    _api.http_request(
        "DELETE", f"/zones/{zone_id}/dns_records/{record_id}"
    )
