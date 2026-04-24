"""``cfafi dns <verb>`` — DNS record management.

v0.1.0 exposes ``create`` only. The bash counterpart at
``.claude/skills/cloudflare-write/scripts/cf-dns-create.sh`` is the
behavioural reference — same dry-run default, same idempotency check,
same supported record-type set.
"""

from __future__ import annotations

import argparse
import json as _json

import cfafi._api as _api
from cfafi.cli._errors import EXIT_USER_ERROR, CfafiError
from cfafi.cli._output import emit_json, emit_kv, emit_result

_SUPPORTED_TYPES = {"A", "AAAA", "CNAME", "TXT", "MX", "NS", "SRV", "CAA"}


def _validate_ttl(ttl: int, *, proxied: bool) -> None:
    if ttl != 1 and (ttl < 60 or ttl > 86400):
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message=f"--ttl must be 1 (automatic) or between 60 and 86400, got {ttl}",
            remediation="drop --ttl for automatic, or pass an int in [60, 86400]",
        )
    if proxied and ttl != 1:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message="--proxied records must use --ttl=1 (CloudFlare ignores manual TTL on proxied records)",
            remediation="either remove --ttl or remove --proxied",
        )


def _resolve_zone_id(zone_name: str) -> str:
    for zone in _api.paginate("/zones"):
        if zone.get("name") == zone_name:
            return zone["id"]
    raise CfafiError(
        code=EXIT_USER_ERROR,
        message=f"zone {zone_name} not found in this account",
        remediation="run `cfafi zones list` to see accessible zones",
    )


def _find_existing(zone_id: str, record_type: str, name: str, content: str) -> dict | None:
    query = {"type": record_type, "name": name, "content": content, "match": "all"}
    for rec in _api.paginate(f"/zones/{zone_id}/dns_records", query=query):
        return rec
    return None


def _body(record_type: str, name: str, content: str, ttl: int, proxied: bool, comment: str) -> dict:
    return {
        "type": record_type,
        "name": name,
        "content": content,
        "ttl": ttl,
        "proxied": proxied,
        "comment": comment,
    }


def cmd_dns_create(args: argparse.Namespace) -> int:
    if args.type not in _SUPPORTED_TYPES:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message=f"unsupported record type: {args.type} (allowed: {' '.join(sorted(_SUPPORTED_TYPES))})",
            remediation="pick one of the supported record types or extend _SUPPORTED_TYPES",
        )
    _validate_ttl(args.ttl, proxied=args.proxied)

    zone_id = _resolve_zone_id(args.zone)
    existing = _find_existing(zone_id, args.type, args.name, args.content)
    if existing is not None:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message=(
                f"DNS record already exists on {args.zone}: "
                f"{args.type} {args.name} {args.content} (id={existing.get('id', '?')})"
            ),
            remediation="use an update flow (not yet implemented) to change content",
        )

    body = _body(args.type, args.name, args.content, args.ttl, args.proxied, args.comment)
    json_mode = bool(getattr(args, "json", False))

    if not args.apply:
        if json_mode:
            emit_json({
                "success": True, "errors": [], "messages": ["dry-run: no changes applied"],
                "result": {"dry_run": True, "zone_id": zone_id, "would_post": body},
            })
            return 0
        emit_result("**Dry-run — no changes applied**\n", json_mode=False)
        emit_kv([
            ("zone", f"{args.zone} (id={zone_id})"),
            ("type", args.type),
            ("name", args.name),
            ("content", args.content),
            ("ttl", f"{args.ttl}{' (automatic)' if args.ttl == 1 else ''}"),
            ("proxied", args.proxied),
        ])
        emit_result(f"\n**would POST** `/zones/{zone_id}/dns_records`:\n", json_mode=False)
        emit_result("```json\n" + _json.dumps(body, indent=2) + "\n```", json_mode=False)
        return 0

    response = _api.http_request("POST", f"/zones/{zone_id}/dns_records", payload=body)
    if json_mode:
        emit_json(response)
        return 0
    new_id = (response.get("result") or {}).get("id", "—")
    emit_result("**DNS record created**\n", json_mode=False)
    emit_kv([
        ("zone", f"{args.zone} (id={zone_id})"),
        ("type", args.type),
        ("name", args.name),
        ("content", args.content),
        ("ttl", f"{args.ttl}{' (automatic)' if args.ttl == 1 else ''}"),
        ("proxied", args.proxied),
        ("record_id", new_id),
    ])
    return 0


def register(sub: argparse._SubParsersAction) -> None:
    p = sub.add_parser("dns", help="DNS record management.")
    verbs = p.add_subparsers(dest="verb", required=True)

    c = verbs.add_parser("create", help="Create a DNS record (dry-run by default; --apply commits).")
    c.add_argument("zone", help="Zone name, e.g. culture.dev")
    c.add_argument("type", help="Record type (A, AAAA, CNAME, TXT, MX, NS, SRV, CAA)")
    c.add_argument("name", help="Record name, e.g. www or www.culture.dev")
    c.add_argument("content", help="Record content (IP, target, TXT value, etc.)")
    c.add_argument("--proxied", action="store_true", help="Orange-cloud the record")
    c.add_argument("--ttl", type=int, default=1, help="TTL seconds (1 = automatic; 60–86400 for manual)")
    c.add_argument(
        "--comment",
        default="Managed by cfafi in agentculture/cfafi",
        help="Free-text note attached to the record",
    )
    c.add_argument("--apply", action="store_true", help="Actually POST (without it, dry-run).")
    c.add_argument("--json", action="store_true", help="Emit raw/synthetic JSON envelope.")
    c.set_defaults(func=cmd_dns_create)
