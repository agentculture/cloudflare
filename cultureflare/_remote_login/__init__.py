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
    delete_policy, ensure_allow_policy, ensure_service_token_policy,
    find_policy, find_service_token_policy,
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
    delete_tunnel, ensure_tunnel, ensure_tunnel_config,
    find_tunnel, get_tunnel_config, get_tunnel_token,
)
from cultureflare._secrets import _shushu_sink
from cultureflare.cli._errors import EXIT_USER_ERROR, CfafiError

__all__ = ["setup", "show", "teardown"]


def _seal_setup_secrets(
    *,
    seal: SealPlan,
    ctx: Context,
    tunnel_token: str,
    with_service_token: bool,
    svc_secret: str | None,
) -> tuple[str | None, str | None, dict[str, str]]:
    """Run shushu seals for both secrets when seal.enabled.

    Returns (tunnel_token_out, svc_secret_out, sealed_in) where the
    output secrets are None if sealed; sealed_in maps each key to its
    shushu marker. On partial-seal failure raises CfafiError with a
    rotate remediation.
    """
    sealed_in: dict[str, str] = {}
    marker_user = seal.user or _whoami()

    _shushu_sink.seal(
        seal.tunnel_token_target,
        tunnel_token.encode("utf-8"),
        seal.metadata,
    )
    sealed_in["tunnel_token"] = (
        f"shushu/{marker_user}/{seal.tunnel_token_target.name}"
    )
    tunnel_token_out: str | None = None

    svc_secret_out: str | None = svc_secret
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
        svc_secret_out = None

    return tunnel_token_out, svc_secret_out, sealed_in


def _probe_sealed_targets(seal: SealPlan) -> dict[str, dict | None]:
    """Probe both seal targets in shushu and return a status map."""
    sealed_status: dict[str, dict | None] = {}
    marker_user = seal.user or _whoami()
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
    return sealed_status


def _delete_sealed_targets(seal: SealPlan) -> list[StepRecord]:
    """Delete both seal targets in shushu; return per-target step records."""
    steps: list[StepRecord] = []
    for step_name, target in (
        ("shushu-tunnel-token", seal.tunnel_token_target),
        ("shushu-svc-secret", seal.service_token_secret_target),
    ):
        try:
            ok = _shushu_sink.delete(target)
            steps.append(StepRecord(
                name=step_name,
                action="deleted" if ok else "skipped",
                detail=target.name,
            ))
        except CfafiError as exc:
            steps.append(StepRecord(
                name=step_name,
                action="delete-failed",
                detail=f"{target.name}: {exc.message}",
            ))
    return steps


def _whoami() -> str:
    """OS username for sealed_in path rendering when --shushu (self).

    Used only for the user-facing marker string. Failure to resolve
    (very rare on Linux) falls back to literal '-' to avoid a crash."""
    try:
        return getpass.getuser()
    except Exception:
        return "-"


def _action(created: bool) -> str:
    """Map ``created`` to the canonical step-record action verb."""
    return "ensured" if created else "skipped"


def _ensure_service_token_step(
    *,
    ctx: Context,
    app_id: str,
    with_service_token: bool,
    steps: list[StepRecord],
) -> tuple[str | None, str | None, str | None]:
    """Run the optional service-token + non_identity-policy pair.

    Returns ``(client_id, client_secret, policy_id)`` for the
    ``SetupResult``. Each tuple element is None when the corresponding
    resource wasn't requested or is not retrievable. Mutates ``steps``
    in place so the orchestrator's step record list keeps its order.

    Strict=False on the token ensure: re-running setup against a
    deployment whose token already exists must be safe. The secret is
    one-shot; re-runs return ``client_id`` with ``secret=None`` and a
    "skipped (existing; secret not rotated)" step. Operators wanting a
    fresh secret teardown first.
    """
    if not with_service_token:
        return None, None, None

    svc_cid, svc_secret, svc_created, svc_token_id = ensure_service_token(
        account_id=ctx.account_id,
        name=ctx.names.service_token_name,
        strict=False,
    )
    svc_detail = f"client_id={svc_cid}"
    if not svc_created:
        svc_detail += " (existing; secret not rotated)"
    steps.append(StepRecord(
        name="service-token", action=_action(svc_created), detail=svc_detail,
    ))

    if not svc_token_id:
        return svc_cid, svc_secret, None

    # Non-identity policy admitting the token. Without it, requests
    # carrying CF-Access-Client-Id/Secret are 302-redirected to SSO
    # regardless of the existing email allow-policy.
    svc_policy_id, svc_policy_created = ensure_service_token_policy(
        account_id=ctx.account_id,
        app_id=app_id,
        token_id=svc_token_id,
        name=ctx.names.service_token_policy_name,
    )
    steps.append(StepRecord(
        name="service-token-policy",
        action=_action(svc_policy_created),
        detail=f"id={svc_policy_id}",
    ))
    return svc_cid, svc_secret, svc_policy_id


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
    if not ctx.service:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message="setup requires a local service URL for tunnel ingress",
            remediation=(
                "pass --service http://localhost:<port> on `cultureflare "
                "remote-login setup` so cloudflared can route the public "
                "hostname to your local process"
            ),
        )
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
        name="tunnel", action=_action(tunnel_created),
        detail=f"{ctx.names.tunnel_name} (id={tunnel_id})",
    ))
    tunnel_token = get_tunnel_token(
        account_id=ctx.account_id, tunnel_id=tunnel_id,
    )

    # 2b. Tunnel ingress config — must follow tunnel creation.
    # Without this, cloudflared registers connections then 503s every
    # request because no ingress rule maps the public hostname to a
    # local service. Idempotent: skipped when ingress already matches.
    tunnel_config_changed = ensure_tunnel_config(
        account_id=ctx.account_id,
        tunnel_id=tunnel_id,
        hostname=ctx.hostname,
        service=ctx.service,
    )
    steps.append(StepRecord(
        name="tunnel-config", action=_action(tunnel_config_changed),
        detail=f"{ctx.hostname} → {ctx.service}",
    ))

    # 3. DNS CNAME → tunnel.
    dns_id, dns_created = ensure_cname(
        zone_id=ctx.zone_id, hostname=ctx.hostname, tunnel_id=tunnel_id,
    )
    dns_target = f"{tunnel_id}.cfargotunnel.com"
    steps.append(StepRecord(
        name="dns", action=_action(dns_created),
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
        name="access-app", action=_action(app_created), detail=f"id={app_id}",
    ))

    # 5. Allow-policy.
    policy_id, policy_created = ensure_allow_policy(
        account_id=ctx.account_id, app_id=app_id,
        name=ctx.names.policy_name,
        emails=emails, domains=domains,
    )
    steps.append(StepRecord(
        name="allow-policy", action=_action(policy_created),
        detail=f"id={policy_id}",
    ))

    # 6. Service token + non_identity policy (optional, paired).
    svc_cid, svc_secret, svc_policy_id = _ensure_service_token_step(
        ctx=ctx, app_id=app_id,
        with_service_token=with_service_token,
        steps=steps,
    )

    sealed_in: dict[str, str] = {}
    if seal.enabled:
        # Seal tunnel token + optional service-token secret.
        # _seal_setup_secrets returns None for the sealed values to prevent
        # them from appearing in the result; sealed_in records the shushu path.
        tunnel_token, svc_secret, sealed_in = _seal_setup_secrets(  # type: ignore[assignment]
            seal=seal,
            ctx=ctx,
            tunnel_token=tunnel_token,
            with_service_token=with_service_token,
            svc_secret=svc_secret,
        )

    return SetupResult(
        team_domain=team_domain,
        tunnel_id=tunnel_id,
        tunnel_name=ctx.names.tunnel_name,
        tunnel_token=tunnel_token,
        tunnel_service=ctx.service,
        dns_record_id=dns_id,
        dns_target=dns_target,
        access_app_id=app_id,
        policy_id=policy_id,
        policy_emails=list(emails),
        policy_domains=list(domains),
        service_token_client_id=svc_cid,
        service_token_client_secret=svc_secret,
        service_token_policy_id=svc_policy_id,
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
    tunnel_config = (
        get_tunnel_config(
            account_id=ctx.account_id, tunnel_id=tunnel["id"],
        )
        if tunnel is not None
        else None
    )
    dns = find_cname(zone_id=ctx.zone_id, hostname=ctx.hostname)

    # Probe shushu unconditionally (independent of CF/ZT state) so that
    # ``--shushu`` shows sealed secret presence even when ZT is not enabled.
    sealed_status: dict[str, dict | None] = (
        _probe_sealed_targets(seal) if seal.enabled else {}
    )

    if org is None:
        return ShowResult(
            team_domain=None,
            tunnel=tunnel, tunnel_config=tunnel_config, dns=dns,
            access_app=None, policy=None,
            service_token=None, service_token_policy=None,
            sealed_in_status=sealed_status,
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
    svc_policy = (
        find_service_token_policy(
            account_id=ctx.account_id,
            app_id=app["id"],
            token_id=svc["id"],
        )
        if app is not None and svc is not None and svc.get("id")
        else None
    )

    return ShowResult(
        team_domain=org.get("auth_domain"),
        tunnel=tunnel,
        tunnel_config=tunnel_config,
        dns=dns,
        access_app=app,
        policy=policy,
        service_token=svc,
        service_token_policy=svc_policy,
        sealed_in_status=sealed_status,
    )


def teardown(
    *,
    ctx: Context,
    keep_tunnel: bool,
    seal: SealPlan | None = None,
) -> TeardownResult:
    """Delete in reverse-dependency order. The ZT org is never touched.

    When ``seal`` is provided and enabled, also attempts to delete each
    sealed shushu entry. Deletion failures are recorded as steps with
    action ``"delete-failed"`` but do NOT abort the function — CF-side
    resources are already gone.
    """
    if seal is None:
        seal = derive_seal_plan(hostname=ctx.hostname, shushu_arg=None)
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

    # 2. Allow-policy + service-token policy + 3. Access app.
    app = find_app(account_id=ctx.account_id, hostname=ctx.hostname)
    if app is not None:
        # Service-token policy: matched by include[].service_token.token_id.
        # ``svc`` was captured BEFORE the token delete in step 1, so we
        # still have the right id to look the policy up by even though
        # the token itself is gone. Delete-app would cascade-delete any
        # leftover policy too, but we surface the step explicitly.
        if svc is not None:
            svc_policy = find_service_token_policy(
                account_id=ctx.account_id, app_id=app["id"],
                token_id=svc["id"],
            )
            if svc_policy is not None:
                delete_policy(
                    account_id=ctx.account_id, app_id=app["id"],
                    policy_id=svc_policy["id"],
                )
                steps.append(StepRecord(
                    name="service-token-policy", action="deleted",
                    detail=f"id={svc_policy['id']}",
                ))
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

    # 6. Shushu sealed entries (best-effort; failures recorded, not raised).
    if seal.enabled:
        steps.extend(_delete_sealed_targets(seal))

    return TeardownResult(steps=steps)
