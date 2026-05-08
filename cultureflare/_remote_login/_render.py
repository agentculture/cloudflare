"""Markdown + JSON renderers for the remote-login result dataclasses."""

from __future__ import annotations

from cultureflare._remote_login._common import (
    SetupResult, ShowResult, TeardownResult,
)


def _seal_or_value(result: SetupResult, key: str, fallback: str | None) -> str:
    if key in result.sealed_in:
        return f"<sealed: {result.sealed_in[key]}>"
    return str(fallback) if fallback is not None else "(none)"


def render_setup_markdown(result: SetupResult, *, hostname: str) -> str:
    lines: list[str] = []
    lines.append(f"## Remote login set up — {hostname}")
    lines.append("")
    lines.append(f"- **CF_TEAM_DOMAIN:** {result.team_domain or '(not set)'}")
    lines.append(f"- **TUNNEL_NAME:** {result.tunnel_name}")
    lines.append(f"- **TUNNEL_ID:** {result.tunnel_id}")
    lines.append(
        f"- **TUNNEL_TOKEN:** {_seal_or_value(result, 'tunnel_token', result.tunnel_token)}"
    )
    if result.tunnel_service is not None:
        lines.append(
            f"- **TUNNEL_INGRESS:** {hostname} → {result.tunnel_service}"
        )
    lines.append(
        f"- **DNS:** CNAME {hostname} → {result.dns_target} (proxied)"
    )
    lines.append(f"- **ACCESS_APP_ID:** {result.access_app_id}")
    policy_bits = []
    if result.policy_emails:
        policy_bits.append(f"allow [{', '.join(result.policy_emails)}]")
    if result.policy_domains:
        policy_bits.append(f"allow-domain [{', '.join(result.policy_domains)}]")
    lines.append(f"- **POLICY:** {'; '.join(policy_bits)}")
    if result.service_token_client_id is not None:
        lines.append(
            f"- **SERVICE_TOKEN_CLIENT_ID:** {result.service_token_client_id}"
        )
        if (
            "service_token_client_secret" in result.sealed_in
            or result.service_token_client_secret is not None
        ):
            lines.append(
                f"- **SERVICE_TOKEN_CLIENT_SECRET:** "
                f"{_seal_or_value(result, 'service_token_client_secret', result.service_token_client_secret)}"
            )
        if result.service_token_policy_id is not None:
            lines.append(
                f"- **SERVICE_TOKEN_POLICY_ID:** {result.service_token_policy_id}"
            )
    lines.append("")
    lines.append("## Steps")
    for i, step in enumerate(result.steps, start=1):
        lines.append(f"{i}. ✓ {step.action} {step.name} ({step.detail})")
    return "\n".join(lines) + "\n"


def render_setup_json(result: SetupResult, *, hostname: str) -> dict:
    return {
        "success": True, "errors": [], "messages": [],
        "result": {
            "hostname": hostname,
            "team_domain": result.team_domain,
            "tunnel_name": result.tunnel_name,
            "tunnel_id": result.tunnel_id,
            "tunnel_token": result.tunnel_token,
            "tunnel_service": result.tunnel_service,
            "dns": {
                "record_id": result.dns_record_id,
                "target": result.dns_target,
            },
            "access_app_id": result.access_app_id,
            "policy": {
                "id": result.policy_id,
                "emails": list(result.policy_emails),
                "domains": list(result.policy_domains),
            },
            "service_token_client_id": result.service_token_client_id,
            "service_token_client_secret": result.service_token_client_secret,
            "service_token_policy_id": result.service_token_policy_id,
            "sealed_in": dict(result.sealed_in),
            "steps": [
                {"name": s.name, "action": s.action, "detail": s.detail}
                for s in result.steps
            ],
        },
    }


def render_setup_dryrun_markdown(
    *,
    hostname: str,
    tunnel_name: str,
    app_name: str,
    service: str,
    emails: list[str],
    domains: list[str],
    with_service_token: bool,
    session_duration: str,
    seal_user: str | None = None,
    seal_tunnel_name: str | None = None,
    seal_svc_name: str | None = None,
) -> str:
    lines: list[str] = []
    lines.append("**Dry-run — no changes applied**")
    lines.append("")
    lines.append(f"## Plan for {hostname}")
    step = 0

    def _step() -> int:
        nonlocal step
        step += 1
        return step

    lines.append(f"{_step()}. ensure Zero Trust org (existing required for v1)")
    lines.append(f"{_step()}. ensure tunnel `{tunnel_name}`")
    lines.append(
        f"{_step()}. ensure tunnel ingress {hostname} → {service}"
    )
    lines.append(
        f"{_step()}. ensure DNS CNAME {hostname} → "
        "<tunnel_id>.cfargotunnel.com (proxied)"
    )
    lines.append(
        f"{_step()}. ensure Access app `{app_name}` "
        f"(session_duration={session_duration})"
    )
    policy_parts: list[str] = []
    if emails:
        policy_parts.append(f"allow [{', '.join(emails)}]")
    if domains:
        policy_parts.append(f"allow-domain [{', '.join(domains)}]")
    lines.append(f"{_step()}. ensure allow-policy ({'; '.join(policy_parts)})")
    if with_service_token:
        lines.append(f"{_step()}. ensure service-token (one-shot secret)")
        lines.append(
            f"{_step()}. ensure non_identity service-token policy admitting it"
        )
    if seal_tunnel_name is not None:
        u = seal_user or "<self>"
        lines.append(
            f"{_step()}. seal tunnel_token into shushu/{u}/{seal_tunnel_name}"
        )
        if with_service_token and seal_svc_name is not None:
            lines.append(
                f"{_step()}. seal service-token client_secret into "
                f"shushu/{u}/{seal_svc_name}"
            )
    lines.append("")
    lines.append("Pass --apply to commit.")
    return "\n".join(lines) + "\n"


def _row_tunnel(tunnel: dict | None) -> str:
    if tunnel is None:
        return "- **tunnel:** (not found)"
    return f"- **tunnel:** {tunnel.get('name')} (id={tunnel.get('id')})"


def _row_tunnel_config(config: dict | None) -> str:
    """Render the first ingress rule (the public-hostname route).

    Both ``config is None`` (no configuration object set yet) and an
    explicit empty ``ingress`` list are the same operational gap from
    #28: cloudflared registers connections then 503s every request.
    Surface them with the same hint.
    """
    rules = ((config or {}).get("config") or {}).get("ingress") or []
    if not rules:
        return "- **tunnel-ingress:** (no rules — cloudflared will 503)"
    head = rules[0]
    host = head.get("hostname") or "(any)"
    svc = head.get("service") or "(none)"
    return f"- **tunnel-ingress:** {host} → {svc}"


def _row_dns(dns: dict | None, hostname: str) -> str:
    if dns is None:
        return "- **dns:** (not found)"
    proxied = bool(dns.get("proxied"))
    marker = "✓" if proxied else "⚠ (unproxied — Access bypassed)"
    label = "proxied" if proxied else "unproxied"
    return (
        f"- **dns:** CNAME {hostname} → {dns.get('content')} "
        f"({label}) {marker}"
    )


def _row_access_app(app: dict | None) -> str:
    body = f"id={app['id']}" if app else "(not found)"
    return f"- **access-app:** {body}"


def _row_policies(policy: dict | None) -> str:
    body = "1 allow rule" if policy else "(not found)"
    return f"- **policies:** {body}"


def _row_service_token(svc: dict | None) -> str:
    if svc is None:
        return "- **service-token:** (not found)"
    return (
        f"- **service-token:** {svc.get('name')} "
        f"(id={svc.get('id')}, secret not retrievable)"
    )


def _row_service_token_policy(svc_policy: dict | None) -> str:
    """Render the non_identity policy admitting the service token.

    Absence of this policy is the gap from #28 that makes service-token
    auth fall through to SSO — surface it explicitly.
    """
    if svc_policy is None:
        return (
            "- **service-token-policy:** (not found — service token "
            "headers will 302 to SSO)"
        )
    return f"- **service-token-policy:** id={svc_policy.get('id')}"


def _row_sealed_status(key: str, status: dict | None) -> str:
    if status is None:
        return f"  - {key}: ?? (shushu not installed)"
    state = "present" if status.get("present") else "absent"
    src = status.get("source")
    tail = f" (source: {src})" if src else ""
    return f"  - {key}: {status.get('name')} — {state}{tail}"


def _rows_sealed_in_status(
    status_map: dict[str, dict | None],
) -> list[str]:
    if not status_map:
        return []
    rows = ["- **sealed-in:**"]
    rows.extend(_row_sealed_status(k, v) for k, v in status_map.items())
    return rows


def render_show_markdown(result: ShowResult, *, hostname: str) -> str:
    lines: list[str] = [
        f"## Remote login state — {hostname}",
        "",
        f"- **zero-trust-org:** {result.team_domain or '(not found)'}",
        _row_tunnel(result.tunnel),
        _row_tunnel_config(result.tunnel_config),
        _row_dns(result.dns, hostname),
        _row_access_app(result.access_app),
        _row_policies(result.policy),
        _row_service_token(result.service_token),
        _row_service_token_policy(result.service_token_policy),
    ]
    lines.extend(_rows_sealed_in_status(result.sealed_in_status))
    return "\n".join(lines) + "\n"


def render_show_json(result: ShowResult, *, hostname: str) -> dict:
    return {
        "success": True, "errors": [], "messages": [],
        "result": {
            "hostname": hostname,
            "team_domain": result.team_domain,
            "tunnel": result.tunnel,
            "tunnel_config": result.tunnel_config,
            "dns": result.dns,
            "access_app": result.access_app,
            "policy": result.policy,
            "service_token": result.service_token,
            "service_token_policy": result.service_token_policy,
            "sealed_in_status": dict(result.sealed_in_status),
        },
    }


def render_teardown_markdown(
    result: TeardownResult, *, hostname: str
) -> str:
    lines: list[str] = []
    lines.append(f"## Remote login torn down — {hostname}")
    lines.append("")
    if not result.steps:
        lines.append("Nothing to delete.")
        return "\n".join(lines) + "\n"
    for i, step in enumerate(result.steps, start=1):
        lines.append(f"{i}. ✓ {step.action} {step.name} ({step.detail})")
    return "\n".join(lines) + "\n"


def render_teardown_json(
    result: TeardownResult, *, hostname: str
) -> dict:
    return {
        "success": True, "errors": [], "messages": [],
        "result": {
            "hostname": hostname,
            "steps": [
                {"name": s.name, "action": s.action, "detail": s.detail}
                for s in result.steps
            ],
        },
    }
