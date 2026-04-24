"""``cfafi explain <path>...`` — markdown docs lookup by noun/verb path."""

from __future__ import annotations

import argparse

from cfafi.cli._errors import EXIT_USER_ERROR, CfafiError
from cfafi.cli._output import emit_result

# Keys are tuples of path tokens. Empty tuple = index.
_CATALOG: dict[tuple[str, ...], str] = {
    (): """\
# cfafi

CloudFlare Agent First Interface. Run `cfafi learn` for the full
self-teaching prompt.

Available paths (v0.1.0):

- `cfafi whoami` — verify the configured CloudFlare API token
- `cfafi zones list` — list zones in the token's account
- `cfafi dns create` — create a DNS record (dry-run by default)
- `cfafi learn` — self-teaching prompt
- `cfafi explain <path>...` — this lookup

Ask for any one with `cfafi explain <path>`, e.g.
`cfafi explain dns create`.
""",
    ("whoami",): """\
# cfafi whoami

Verify the configured CloudFlare API token.

Calls `GET /user/tokens/verify`. Renders a markdown key-value list of
the token id, status, not-before, and expires-on; `--json` emits the
raw CloudFlare envelope.

## Flags

- `--json` — emit the raw CloudFlare response envelope.

## Exit codes

- `0` — token is active
- `2` — CLOUDFLARE_API_TOKEN not set
- `3` — authentication error (token expired, revoked, or scope-mismatch)
- `4` — upstream error
""",
    ("zones",): """\
# cfafi zones

Zone-level inventory. Current verbs:

- `cfafi zones list` — list every zone visible to the token

More verbs land in future minor releases.
""",
    ("zones", "list"): """\
# cfafi zones list

List zones accessible to the configured token.

Walks `GET /zones` with pagination (per_page=50). Renders a markdown
table of ID / NAME / STATUS / PLAN; `--json` emits a synthetic
single-envelope aggregating every page.

## Flags

- `--json` — emit synthetic JSON envelope.
""",
    ("dns",): """\
# cfafi dns

DNS record management. Current verbs:

- `cfafi dns create` — create a record (dry-run by default)

More verbs (`list`, `delete`, `update`) land in future minor releases.
""",
    ("dns", "create"): """\
# cfafi dns create

Create a DNS record in a CloudFlare zone. **Dry-run by default.**

```
cfafi dns create ZONE TYPE NAME CONTENT [--proxied] [--ttl N] [--comment STR] [--apply] [--json]
```

## Behaviour

Dry-run (no `--apply`): resolves the zone, checks no matching
type+name+content record already exists, prints the exact JSON body
it would POST, and exits 0 without mutating anything.

`--apply`: actually POSTs the record. Idempotency guard still
applies — if a matching record already exists, the command exits 1
without creating a duplicate.

## Flags

- `--proxied` — orange-cloud the record (CF intercepts HTTP traffic).
- `--ttl N` — TTL seconds (default 1 = automatic; 60–86400 for manual).
- `--comment STR` — free-text note attached to the record.
- `--apply` — actually POST. Without it, this is a dry-run.
- `--json` — emit raw CloudFlare response envelope (or a synthetic
  `{result: {dry_run: true, ...}}` envelope in dry-run mode).

## Record types

`A`, `AAAA`, `CNAME`, `TXT`, `MX`, `NS`, `SRV`, `CAA`. Extend
`_SUPPORTED_TYPES` in `cfafi/cli/_commands/dns.py` if you need more.

## Exit codes

- `0` — success (dry-run printed, or record created with --apply)
- `1` — zone not found, record already exists, or bad flag combination
- `2` — CLOUDFLARE_API_TOKEN not set
- `3` — authentication error
- `4` — upstream CloudFlare API error
""",
    ("learn",): """\
# cfafi learn

Print a self-teaching prompt for agent consumers. Supports `--json`
for a structured payload. Run `cfafi learn` for the full text.
""",
    ("explain",): """\
# cfafi explain

Look up markdown docs for any noun/verb path. Empty path = index.

Examples:

```
cfafi explain
cfafi explain whoami
cfafi explain dns create
```
""",
}


def resolve(path: tuple[str, ...]) -> str:
    if path in _CATALOG:
        return _CATALOG[path]
    raise CfafiError(
        code=EXIT_USER_ERROR,
        message=f"no docs for path: {' '.join(path)!r}",
        remediation="run `cfafi explain` with no arguments for the index",
    )


def cmd_explain(args: argparse.Namespace) -> int:
    path = tuple(args.path) if args.path else ()
    markdown = resolve(path)
    json_mode = bool(getattr(args, "json", False))
    if json_mode:
        emit_result({"path": list(path), "markdown": markdown}, json_mode=True)
    else:
        emit_result(markdown, json_mode=False)
    return 0


def register(sub: argparse._SubParsersAction) -> None:
    p = sub.add_parser(
        "explain",
        help="Print markdown docs for a noun/verb path (e.g. 'cfafi explain dns create').",
    )
    p.add_argument("path", nargs="*", help="Command path tokens; empty = index.")
    p.add_argument("--json", action="store_true", help="Emit structured JSON.")
    p.set_defaults(func=cmd_explain)
