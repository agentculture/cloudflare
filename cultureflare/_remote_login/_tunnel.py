"""CloudFlare cfd_tunnel helpers (Cloudflared / 'remote-managed' tunnels)."""

from __future__ import annotations

import cultureflare._api as _api


def find_tunnel(*, account_id: str, name: str) -> dict | None:
    """Return the tunnel dict whose .name matches, or None.

    Always filters out deleted tunnels (CF retains tombstones with the
    same name but distinct IDs; querying without is_deleted=false leads
    to ambiguous matches).
    """
    for tun in _api.paginate(
        f"/accounts/{account_id}/cfd_tunnel",
        query={"is_deleted": "false"},
    ):
        if tun.get("name") == name:
            return tun
    return None


def ensure_tunnel(*, account_id: str, name: str) -> tuple[str, bool]:
    """Find or create a cloudflare-managed tunnel by name."""
    existing = find_tunnel(account_id=account_id, name=name)
    if existing is not None:
        return existing["id"], False
    response = _api.http_request(
        "POST",
        f"/accounts/{account_id}/cfd_tunnel",
        payload={"name": name, "config_src": "cloudflare"},
    )
    return response["result"]["id"], True


def get_tunnel_config(*, account_id: str, tunnel_id: str) -> dict | None:
    """GET the remote-managed tunnel configuration.

    Returns the ``result`` envelope (with keys like ``config``, ``version``)
    or None if the tunnel has no configuration set yet.
    """
    response = _api.http_request(
        "GET",
        f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations",
    )
    return response.get("result")


def _ingress_matches(
    config: dict | None, *, hostname: str, service: str
) -> bool:
    """True iff `config` already has the (hostname → service) + 404 catch-all."""
    if not config:
        return False
    rules = (config.get("config") or {}).get("ingress") or []
    if len(rules) < 2:
        return False
    head = rules[0]
    tail = rules[-1]
    head_match = (
        head.get("hostname") == hostname
        and head.get("service") == service
    )
    tail_match = tail.get("service") == "http_status:404"
    return head_match and tail_match


def ensure_tunnel_config(
    *,
    account_id: str,
    tunnel_id: str,
    hostname: str,
    service: str,
) -> bool:
    """Set ingress for a remote-managed tunnel; idempotent.

    Returns True if a PUT was made, False if existing config already
    matches ``(hostname → service)`` + the ``http_status:404`` catch-all.

    The PUT preserves any other writable keys already present on the
    tunnel's ``config`` object (e.g. ``warp-routing``, ``originRequest``)
    by overlaying the new ``ingress`` rules on top of the existing
    config rather than sending a fresh one. CF's `/configurations`
    endpoint is replace-not-merge, so omitting a key resets it to
    its default — which would silently drop operator-set
    ``warp-routing`` toggles or origin TLS / connectTimeout overrides.
    """
    existing = get_tunnel_config(account_id=account_id, tunnel_id=tunnel_id)
    if _ingress_matches(existing, hostname=hostname, service=service):
        return False
    existing_config = (existing or {}).get("config") or {}
    new_config = {
        **existing_config,
        "ingress": [
            {"hostname": hostname, "service": service},
            {"service": "http_status:404"},
        ],
    }
    _api.http_request(
        "PUT",
        f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/configurations",
        payload={"config": new_config},
    )
    return True


def get_tunnel_token(*, account_id: str, tunnel_id: str) -> str:
    """Fetch the runtime token (passed to `cloudflared tunnel run --token`).

    Refetchable on every call; not a one-shot secret.
    """
    response = _api.http_request(
        "GET",
        f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}/token",
    )
    token = response.get("result")
    if not isinstance(token, str):
        raise RuntimeError(
            f"unexpected /cfd_tunnel/{tunnel_id}/token response shape"
        )
    return token


def delete_tunnel(*, account_id: str, tunnel_id: str) -> None:
    """DELETE the tunnel with ?force=true to drop active connections."""
    _api.http_request(
        "DELETE",
        f"/accounts/{account_id}/cfd_tunnel/{tunnel_id}",
        query={"force": "true"},
    )
