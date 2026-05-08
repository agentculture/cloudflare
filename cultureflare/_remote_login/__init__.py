"""Remote-login orchestrator.

Composes the per-resource helpers under ``_remote_login/_*`` into the
three operator-facing actions: ``setup`` (create or ensure), ``show``
(read), ``teardown`` (delete in reverse). All three take a populated
``Context`` and return a typed result dataclass; they do NOT perform
CLI parsing or rendering. The CLI module wraps them.
"""

from __future__ import annotations

import getpass

from cultureflare._remote_login._access_app import (
    delete_app, ensure_app, find_app,
)
from cultureflare._remote_login._access_org import find_org
from cultureflare._remote_login._access_policy import (
    delete_policy, ensure_allow_policy, find_policy,
)
from cultureflare._remote_login._common import (
    Context, SetupResult, ShowResult, StepRecord, TeardownResult,
)
from cultureflare._remote_login._dns import delete_cname, ensure_cname, find_cname
from cultureflare._remote_login._seal_plan import SealPlan, derive_seal_plan
from cultureflare._remote_login._service_token import (
    delete_service_token, ensure_service_token, find_service_token,
)
from cultureflare._remote_login._tunnel import (
    delete_tunnel, ensure_tunnel, find_tunnel, get_tunnel_token,
)
from cultureflare._secrets import _shushu_sink
from cultureflare.cli._errors import EXIT_USER_ERROR, CfafiError

__all__ = ["setup", "show", "teardown"]


def _whoami() -> str:
    """OS username for sealed_in path rendering when --shushu (self).

    Used only for the user-facing marker string. Failure to resolve
    (very rare on Linux) falls back to literal '-' to avoid a crash."""
    try:
        return getpass.getuser()
    except Exception:
        return "-"


def setup(
    *,
    ctx: Context,
    emails: list[str],
    domains: list[str],
    with_service_token: bool,
    session_duration: str,
    seal: SealPlan | None = None,
) -> SetupResult:
    """Run the full setup against the live CF API.

    v1 assumes Zero Trust is already enabled on the account; if absent,
    we surface a clear error rather than auto-onboard (onboarding needs
    an auth_domain we don't have at this layer).
    """
    if seal is None:
        seal = derive_seal_plan(hostname=ctx.hostname, shushu_arg=None)
    steps: list[StepRecord] = []

    # 1. Zero Trust org — verified, never created here.
    org = find_org(account_id=ctx.account_id)
    if org is None:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message="Zero Trust is not enabled for this account",
            remediation=(
                "enable Zero Trust at "
                "https://one.dash.cloudflare.com/?to=/:account/access "
                "(pick a team subdomain), then re-run setup"
            ),
        )
    team_domain = org.get("auth_domain")
    steps.append(StepRecord(
        name="zero-trust-org", action="ensured",
        detail=f"existing auth_domain={team_domain}",
    ))

    # 2. Tunnel.
    tunnel_id, tunnel_created = ensure_tunnel(
        account_id=ctx.account_id, name=ctx.names.tunnel_name,
    )
    steps.append(StepRecord(
        name="tunnel",
        action="ensured" if tunnel_created else "skipped",
        detail=f"{ctx.names.tunnel_name} (id={tunnel_id})",
    ))
    tunnel_token = get_tunnel_token(
        account_id=ctx.account_id, tunnel_id=tunnel_id,
    )

    # 3. DNS CNAME → tunnel.
    dns_id, dns_created = ensure_cname(
        zone_id=ctx.zone_id, hostname=ctx.hostname, tunnel_id=tunnel_id,
    )
    dns_target = f"{tunnel_id}.cfargotunnel.com"
    steps.append(StepRecord(
        name="dns",
        action="ensured" if dns_created else "skipped",
        detail=f"CNAME {ctx.hostname} → {dns_target}",
    ))

    # 4. Access app.
    app_id, app_created = ensure_app(
        account_id=ctx.account_id,
        hostname=ctx.hostname,
        app_name=ctx.names.app_name,
        session_duration=session_duration,
    )
    steps.append(StepRecord(
        name="access-app",
        action="ensured" if app_created else "skipped",
        detail=f"id={app_id}",
    ))

    # 5. Allow-policy.
    policy_id, policy_created = ensure_allow_policy(
        account_id=ctx.account_id, app_id=app_id,
        name=ctx.names.policy_name,
        emails=emails, domains=domains,
    )
    steps.append(StepRecord(
        name="allow-policy",
        action="ensured" if policy_created else "skipped",
        detail=f"id={policy_id}",
    ))

    # 6. Service token (optional).
    svc_cid: str | None = None
    svc_secret: str | None = None
    if with_service_token:
        svc_cid, svc_secret, svc_created = ensure_service_token(
            account_id=ctx.account_id,
            name=ctx.names.service_token_name,
            strict=True,
        )
        steps.append(StepRecord(
            name="service-token",
            action="ensured" if svc_created else "skipped",
            detail=f"client_id={svc_cid}",
        ))

    sealed_in: dict[str, str] = {}
    if seal.enabled:
        # 1. Seal tunnel token.
        _shushu_sink.seal(
            seal.tunnel_token_target,
            tunnel_token.encode("utf-8"),
            seal.metadata,
        )
        marker_user = seal.user or _whoami()
        sealed_in["tunnel_token"] = (
            f"shushu/{marker_user}/{seal.tunnel_token_target.name}"
        )
        tunnel_token = None  # type: ignore[assignment]

        # 2. Seal service-token secret. If this fails after the tunnel
        # seal succeeded, the service-token secret is one-shot from CF
        # and is now lost — surface a curated rotate remediation.
        if with_service_token and svc_secret is not None:
            try:
                _shushu_sink.seal(
                    seal.service_token_secret_target,
                    svc_secret.encode("utf-8"),
                    seal.metadata,
                )
            except CfafiError as exc:
                raise CfafiError(
                    code=exc.code,
                    message=(
                        "partial seal — tunnel-token stored, "
                        f"service-token secret failed: {exc.message}"
                    ),
                    remediation=(
                        f"cultureflare remote-login teardown "
                        f"--hostname {ctx.hostname} "
                        f"--shushu{'=' + seal.user if seal.user else ''} "
                        "--apply, then re-run setup; the service-token "
                        "secret was one-shot and must be rotated."
                    ),
                ) from exc
            sealed_in["service_token_client_secret"] = (
                f"shushu/{marker_user}/{seal.service_token_secret_target.name}"
            )
            svc_secret = None  # type: ignore[assignment]

    return SetupResult(
        team_domain=team_domain,
        tunnel_id=tunnel_id,
        tunnel_name=ctx.names.tunnel_name,
        tunnel_token=tunnel_token,
        dns_record_id=dns_id,
        dns_target=dns_target,
        access_app_id=app_id,
        policy_id=policy_id,
        policy_emails=list(emails),
        policy_domains=list(domains),
        service_token_client_id=svc_cid,
        service_token_client_secret=svc_secret,
        steps=steps,
        sealed_in=sealed_in,
    )


def show(*, ctx: Context, seal: SealPlan | None = None) -> ShowResult:
    """Read every resource setup would create, returning presence/absence.

    When Zero Trust is disabled (``find_org`` returns None), every other
    Access endpoint (`/access/apps`, `/access/service_tokens`) would also
    return CF error 9999. Skip those probes and report the Access-side
    fields as None — the operator gets a clean "(not found)" rendering
    instead of a fresh 4xx mid-`show`. Tunnel and DNS aren't
    Access-scoped, so we still query them.

    When ``seal`` is provided and enabled, probes shushu for each sealed
    target and populates ``sealed_in_status``. If shushu is not installed
    ("not found" in the error message), show is non-fatal: each entry
    becomes None rather than raising.
    """
    if seal is None:
        seal = derive_seal_plan(hostname=ctx.hostname, shushu_arg=None)

    org = find_org(account_id=ctx.account_id)
    tunnel = find_tunnel(
        account_id=ctx.account_id, name=ctx.names.tunnel_name,
    )
    dns = find_cname(zone_id=ctx.zone_id, hostname=ctx.hostname)
    if org is None:
        return ShowResult(
            team_domain=None,
            tunnel=tunnel, dns=dns,
            access_app=None, policy=None, service_token=None,
        )
    app = find_app(account_id=ctx.account_id, hostname=ctx.hostname)
    policy = (
        find_policy(
            account_id=ctx.account_id,
            app_id=app["id"],
            name=ctx.names.policy_name,
        )
        if app is not None
        else None
    )
    svc = find_service_token(
        account_id=ctx.account_id, name=ctx.names.service_token_name,
    )

    sealed_status: dict[str, dict | None] = {}
    if seal.enabled:
        for key, target in (
            ("tunnel_token", seal.tunnel_token_target),
            ("service_token_client_secret", seal.service_token_secret_target),
        ):
            try:
                meta = _shushu_sink.probe(target)
            except CfafiError as exc:
                if "not found" in exc.message.lower():
                    sealed_status[key] = None
                    continue
                raise
            marker_user = seal.user or _whoami()
            if meta is None:
                sealed_status[key] = {
                    "present": False,
                    "name": f"shushu/{marker_user}/{target.name}",
                    "source": None,
                }
            else:
                sealed_status[key] = {
                    "present": True,
                    "name": f"shushu/{marker_user}/{target.name}",
                    "source": meta.get("source"),
                }

    return ShowResult(
        team_domain=org.get("auth_domain"),
        tunnel=tunnel,
        dns=dns,
        access_app=app,
        policy=policy,
        service_token=svc,
        sealed_in_status=sealed_status,
    )


def teardown(*, ctx: Context, keep_tunnel: bool) -> TeardownResult:
    """Delete in reverse-dependency order. The ZT org is never touched."""
    steps: list[StepRecord] = []

    # 1. Service token.
    svc = find_service_token(
        account_id=ctx.account_id, name=ctx.names.service_token_name,
    )
    if svc is not None:
        delete_service_token(account_id=ctx.account_id, token_id=svc["id"])
        steps.append(StepRecord(
            name="service-token", action="deleted", detail=f"id={svc['id']}",
        ))

    # 2. Allow-policy + 3. Access app.
    app = find_app(account_id=ctx.account_id, hostname=ctx.hostname)
    if app is not None:
        policy = find_policy(
            account_id=ctx.account_id, app_id=app["id"],
            name=ctx.names.policy_name,
        )
        if policy is not None:
            delete_policy(
                account_id=ctx.account_id, app_id=app["id"],
                policy_id=policy["id"],
            )
            steps.append(StepRecord(
                name="allow-policy", action="deleted",
                detail=f"id={policy['id']}",
            ))
        delete_app(account_id=ctx.account_id, app_id=app["id"])
        steps.append(StepRecord(
            name="access-app", action="deleted", detail=f"id={app['id']}",
        ))

    # 4. DNS.
    dns = find_cname(zone_id=ctx.zone_id, hostname=ctx.hostname)
    if dns is not None:
        delete_cname(zone_id=ctx.zone_id, record_id=dns["id"])
        steps.append(StepRecord(
            name="dns", action="deleted", detail=f"id={dns['id']}",
        ))

    # 5. Tunnel.
    if not keep_tunnel:
        tun = find_tunnel(
            account_id=ctx.account_id, name=ctx.names.tunnel_name,
        )
        if tun is not None:
            delete_tunnel(account_id=ctx.account_id, tunnel_id=tun["id"])
            steps.append(StepRecord(
                name="tunnel", action="deleted", detail=f"id={tun['id']}",
            ))

    return TeardownResult(steps=steps)
