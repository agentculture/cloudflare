"""Markdown + JSON renderers for the remote-login result dataclasses."""

from __future__ import annotations

from cfafi._remote_login._common import (
    SetupResult, ShowResult, TeardownResult,
)


def render_setup_markdown(result: SetupResult, *, hostname: str) -> str:
    lines: list[str] = []
    lines.append(f"## Remote login set up — {hostname}")
    lines.append("")
    lines.append(f"- **CF_TEAM_DOMAIN:** {result.team_domain or '(not set)'}")
    lines.append(f"- **TUNNEL_NAME:** {result.tunnel_name}")
    lines.append(f"- **TUNNEL_ID:** {result.tunnel_id}")
    lines.append(f"- **TUNNEL_TOKEN:** {result.tunnel_token}")
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
    if result.service_token_client_secret is not None:
        lines.append(
            f"- **SERVICE_TOKEN_CLIENT_SECRET:** "
            f"{result.service_token_client_secret}"
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
    emails: list[str],
    domains: list[str],
    with_service_token: bool,
    session_duration: str,
) -> str:
    lines: list[str] = []
    lines.append("**Dry-run — no changes applied**")
    lines.append("")
    lines.append(f"## Plan for {hostname}")
    lines.append("1. ensure Zero Trust org (existing required for v1)")
    lines.append(f"2. ensure tunnel `{tunnel_name}`")
    lines.append(
        f"3. ensure DNS CNAME {hostname} → <tunnel_id>.cfargotunnel.com (proxied)"
    )
    lines.append(
        f"4. ensure Access app `{app_name}` (session_duration={session_duration})"
    )
    policy_parts: list[str] = []
    if emails:
        policy_parts.append(f"allow [{', '.join(emails)}]")
    if domains:
        policy_parts.append(f"allow-domain [{', '.join(domains)}]")
    lines.append(f"5. ensure allow-policy ({'; '.join(policy_parts)})")
    if with_service_token:
        lines.append("6. ensure service-token (one-shot secret)")
    lines.append("")
    lines.append("Pass --apply to commit.")
    return "\n".join(lines) + "\n"


def render_show_markdown(result: ShowResult, *, hostname: str) -> str:
    lines: list[str] = []
    lines.append(f"## Remote login state — {hostname}")
    lines.append("")
    lines.append(
        f"- **zero-trust-org:** {result.team_domain or '(not found)'}"
    )
    if result.tunnel is not None:
        lines.append(
            f"- **tunnel:** {result.tunnel.get('name')} "
            f"(id={result.tunnel.get('id')})"
        )
    else:
        lines.append("- **tunnel:** (not found)")
    if result.dns is not None:
        proxied = bool(result.dns.get("proxied"))
        marker = "✓" if proxied else "⚠ (unproxied — Access bypassed)"
        lines.append(
            f"- **dns:** CNAME {hostname} → {result.dns.get('content')} "
            f"({'proxied' if proxied else 'unproxied'}) {marker}"
        )
    else:
        lines.append("- **dns:** (not found)")
    lines.append(
        f"- **access-app:** "
        f"{'id=' + result.access_app['id'] if result.access_app else '(not found)'}"
    )
    lines.append(
        f"- **policies:** "
        f"{'1 allow rule' if result.policy else '(not found)'}"
    )
    if result.service_token is not None:
        lines.append(
            f"- **service-token:** {result.service_token.get('name')} "
            f"(id={result.service_token.get('id')}, "
            f"secret not retrievable)"
        )
    else:
        lines.append("- **service-token:** (not found)")
    return "\n".join(lines) + "\n"


def render_show_json(result: ShowResult, *, hostname: str) -> dict:
    return {
        "success": True, "errors": [], "messages": [],
        "result": {
            "hostname": hostname,
            "team_domain": result.team_domain,
            "tunnel": result.tunnel,
            "dns": result.dns,
            "access_app": result.access_app,
            "policy": result.policy,
            "service_token": result.service_token,
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
