"""``cfafi zones <verb>`` — zone inventory."""

from __future__ import annotations

import argparse

import cfafi._api as _api
from cfafi.cli._output import emit_json, emit_result, emit_table


def cmd_zones_list(args: argparse.Namespace) -> None:
    """Success path falls off the end (implicit None). See cmd_whoami for rationale."""
    rows = list(_api.paginate("/zones"))
    json_mode = bool(getattr(args, "json", False))
    if json_mode:
        envelope = {
            "success": True,
            "errors": [],
            "messages": [],
            "result": rows,
            "result_info": {
                "page": 1,
                "total_pages": 1,
                "count": len(rows),
                "total_count": len(rows),
            },
        }
        emit_json(envelope)
    else:
        emit_result(f"## Zones ({len(rows)})\n", json_mode=False)
        emit_table(
            headers=["ID", "NAME", "STATUS", "PLAN"],
            rows=[
                [
                    z.get("id", "—"),
                    z.get("name", "—"),
                    z.get("status", "—"),
                    (z.get("plan") or {}).get("name") or "—",
                ]
                for z in rows
            ],
        )


def register(sub: argparse._SubParsersAction) -> None:
    p = sub.add_parser("zones", help="Zone inventory.")
    verbs = p.add_subparsers(dest="verb", required=True)
    lst = verbs.add_parser("list", help="List zones in the token's account.")
    lst.add_argument("--json", action="store_true", help="Emit synthetic JSON envelope.")
    lst.set_defaults(func=cmd_zones_list)
