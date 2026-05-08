"""``cultureflare remote-login`` — setup / show / teardown a hostname behind Access."""

from __future__ import annotations

import argparse
from urllib.parse import urlparse

from cultureflare._env import require_env
from cultureflare._remote_login import setup, show, teardown
from cultureflare._remote_login._common import Context, derive_names, resolve_zone
from cultureflare._remote_login._preflight import check_token_alive
from cultureflare._remote_login._seal_plan import SealPlan, derive_seal_plan
from cultureflare._remote_login._render import (
    render_setup_dryrun_markdown, render_setup_json, render_setup_markdown,
    render_show_json, render_show_markdown,
    render_teardown_json, render_teardown_markdown,
)
from cultureflare.cli._errors import EXIT_USER_ERROR, CfafiError
from cultureflare.cli._output import emit_json, emit_result


def _validate_service_url(value: str) -> str:
    """Reject empty / scheme-less / host-less ``--service`` values.

    Catches the common shape mistakes that would POST garbage into CF
    and produce a 503 the operator has to hunt for. The check is
    ``scheme://host[:port]`` — i.e. cloudflared targets that have a
    netloc (``http://``, ``https://``, ``tcp://``). Schemes without
    a netloc (``unix:/path``) aren't accepted here; if you need that
    shape, set the tunnel ingress directly via the dashboard or API
    and skip this CLI's ingress step.
    """
    parsed = urlparse(value)
    if not parsed.scheme or not parsed.netloc:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message=f"--service must be scheme://host[:port], got {value!r}",
            remediation=(
                "use --service http://localhost:<port> "
                "(or https://… / tcp://… for non-HTTP backends)"
            ),
        )
    return value


_SHUSHU_HELP = (
    "seal tunnel_token + service_token client_secret into shushu "
    "instead of printing them. Bare --shushu = invoking user; "
    "--shushu=USER deposits into another user's vault via sudo. "
    "When set, value fields render as <sealed: shushu/USER/NAME> "
    "markers."
)


def _build_context(hostname: str) -> Context:
    account_id = require_env("CLOUDFLARE_ACCOUNT_ID")
    zone_id, _zone_name = resolve_zone(hostname)
    return Context(
        account_id=account_id,
        zone_id=zone_id,
        hostname=hostname,
        names=derive_names(hostname=hostname),
    )


def _ctx_with_overrides(args: argparse.Namespace) -> Context:
    base = _build_context(args.hostname)
    names = derive_names(
        hostname=args.hostname,
        tunnel_name=getattr(args, "tunnel_name", None),
        app_name=getattr(args, "app_name", None),
        service_token_name=getattr(args, "service_token_name", None),
    )
    return Context(
        account_id=base.account_id, zone_id=base.zone_id,
        hostname=base.hostname, names=names,
        service=getattr(args, "service", None),
    )


def _emit_setup_dryrun(
    args: argparse.Namespace, ctx: Context, seal: SealPlan,
) -> None:
    """Print dry-run plan for setup (markdown or JSON depending on args.json)."""
    json_mode = bool(args.json)
    if json_mode:
        result_body: dict = {
            "dry_run": True,
            "hostname": args.hostname,
            "tunnel_name": ctx.names.tunnel_name,
            "app_name": ctx.names.app_name,
            "service": args.service,
            "with_service_token": args.with_service_token,
            "session_duration": args.session_duration,
            "emails": list(args.allow),
            "domains": list(args.allow_domain),
        }
        if seal.enabled:
            u = seal.user or "<self>"
            result_body["sealed_in"] = {
                "tunnel_token": (
                    f"shushu/{u}/{seal.tunnel_token_target.name}"
                ),
                "service_token_client_secret": (
                    f"shushu/{u}/{seal.service_token_secret_target.name}"
                    if args.with_service_token else None
                ),
            }
        emit_json({
            "success": True, "errors": [], "messages": ["dry-run: no changes applied"],
            "result": result_body,
        })
    else:
        emit_result(
            render_setup_dryrun_markdown(
                hostname=args.hostname,
                tunnel_name=ctx.names.tunnel_name,
                app_name=ctx.names.app_name,
                service=args.service,
                emails=list(args.allow),
                domains=list(args.allow_domain),
                with_service_token=args.with_service_token,
                session_duration=args.session_duration,
                seal_user=seal.user if seal.enabled else None,
                seal_tunnel_name=seal.tunnel_token_target.name if seal.enabled else None,
                seal_svc_name=seal.service_token_secret_target.name if seal.enabled else None,
            ),
            json_mode=False,
        )


def _emit_setup_apply(
    args: argparse.Namespace, ctx: Context, seal: SealPlan,
) -> None:
    """Run setup() and emit the result."""
    json_mode = bool(args.json)
    result = setup(
        ctx=ctx,
        emails=list(args.allow),
        domains=list(args.allow_domain),
        with_service_token=args.with_service_token,
        session_duration=args.session_duration,
        seal=seal,
    )
    if json_mode:
        emit_json(render_setup_json(result, hostname=args.hostname))
    else:
        emit_result(
            render_setup_markdown(result, hostname=args.hostname),
            json_mode=False,
        )


def cmd_setup(args: argparse.Namespace) -> None:
    if not args.allow and not args.allow_domain:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message="at least one of --allow / --allow-domain is required",
            remediation="pass --allow user@example.com or --allow-domain @example.com",
        )
    args.service = _validate_service_url(args.service)
    check_token_alive()
    ctx = _ctx_with_overrides(args)
    seal = derive_seal_plan(hostname=args.hostname, shushu_arg=args.shushu)
    if not args.apply:
        _emit_setup_dryrun(args, ctx, seal)
    else:
        _emit_setup_apply(args, ctx, seal)


def cmd_show(args: argparse.Namespace) -> None:
    json_mode = bool(args.json)
    check_token_alive()
    ctx = _ctx_with_overrides(args)
    seal = derive_seal_plan(hostname=args.hostname, shushu_arg=args.shushu)
    result = show(ctx=ctx, seal=seal)
    if json_mode:
        emit_json(render_show_json(result, hostname=args.hostname))
    else:
        emit_result(
            render_show_markdown(result, hostname=args.hostname),
            json_mode=False,
        )


def cmd_teardown(args: argparse.Namespace) -> None:
    json_mode = bool(args.json)
    check_token_alive()
    ctx = _ctx_with_overrides(args)
    seal = derive_seal_plan(hostname=args.hostname, shushu_arg=args.shushu)

    if not args.apply:
        msg = (
            f"**Dry-run — no changes applied**\n\n"
            f"`teardown --hostname {args.hostname}` would delete (in order): "
            f"service-token, allow-policy, access-app, dns, "
            f"{'tunnel' if not args.keep_tunnel else '(tunnel kept)'}.\n"
        )
        if json_mode:
            emit_json({
                "success": True, "errors": [],
                "messages": ["dry-run: no changes applied"],
                "result": {
                    "dry_run": True, "hostname": args.hostname,
                    "keep_tunnel": args.keep_tunnel,
                },
            })
        else:
            emit_result(msg, json_mode=False)
        return

    result = teardown(ctx=ctx, keep_tunnel=args.keep_tunnel, seal=seal)
    if json_mode:
        emit_json(render_teardown_json(result, hostname=args.hostname))
    else:
        emit_result(
            render_teardown_markdown(result, hostname=args.hostname),
            json_mode=False,
        )


def register(sub: argparse._SubParsersAction) -> None:
    p = sub.add_parser(
        "remote-login",
        help="Set up / show / tear down a hostname behind Cloudflare Access.",
    )
    verbs = p.add_subparsers(dest="verb", required=True)

    s = verbs.add_parser("setup", help="Create or ensure the full set.")
    s.add_argument("--hostname", required=True, help="e.g. irc.culture.dev")
    s.add_argument(
        "--allow", action="append", default=[],
        help="Email to allow (repeatable).",
    )
    s.add_argument(
        "--allow-domain", action="append", default=[],
        help="Email-domain to allow, e.g. @example.com (repeatable).",
    )
    s.add_argument(
        "--service", required=True,
        help=(
            "Local service URL the tunnel routes the public hostname to, "
            "e.g. http://localhost:8080. Required: a missing ingress rule "
            "is exactly the gap that makes cloudflared reply 503."
        ),
    )
    s.add_argument("--tunnel-name", default=None,
                   help="Override the derived tunnel name.")
    s.add_argument("--app-name", default=None,
                   help="Override the derived Access app name.")
    s.add_argument("--service-token-name", default=None,
                   help="Override the derived service-token name.")
    s.add_argument("--with-service-token", action="store_true",
                   help="Also create a service token (one-shot secret).")
    s.add_argument("--session-duration", default="24h",
                   help="Access session duration (default 24h).")
    s.add_argument("--apply", action="store_true",
                   help="Actually mutate (default: dry-run).")
    s.add_argument("--json", action="store_true",
                   help="Emit JSON envelope on stdout.")
    s.add_argument(
        "--shushu",
        nargs="?", const="", default=None, metavar="USER",
        help=_SHUSHU_HELP,
    )
    s.set_defaults(func=cmd_setup)

    sh = verbs.add_parser("show", help="Inspect the current state for a hostname.")
    sh.add_argument("--hostname", required=True)
    sh.add_argument("--tunnel-name", default=None)
    sh.add_argument("--app-name", default=None)
    sh.add_argument("--service-token-name", default=None)
    sh.add_argument("--json", action="store_true")
    sh.add_argument(
        "--shushu",
        nargs="?", const="", default=None, metavar="USER",
        help=_SHUSHU_HELP,
    )
    sh.set_defaults(func=cmd_show)

    t = verbs.add_parser("teardown", help="Delete in reverse-dependency order.")
    t.add_argument("--hostname", required=True)
    t.add_argument("--tunnel-name", default=None)
    t.add_argument("--app-name", default=None)
    t.add_argument("--service-token-name", default=None)
    t.add_argument("--keep-tunnel", action="store_true",
                   help="Keep the tunnel; delete only DNS/Access resources.")
    t.add_argument("--apply", action="store_true",
                   help="Actually mutate (default: dry-run).")
    t.add_argument("--json", action="store_true")
    t.add_argument(
        "--shushu",
        nargs="?", const="", default=None, metavar="USER",
        help=_SHUSHU_HELP,
    )
    t.set_defaults(func=cmd_teardown)
