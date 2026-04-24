"""``cfafi learn`` — self-teaching prompt for agent consumers.

Mirrors ``afi learn``. Includes credential-loading guidance (the bit
that prevents accidental exposure via .env walked upward from cwd).
"""

from __future__ import annotations

import argparse

from cfafi import __version__
from cfafi.cli._output import emit_result

_TEXT = """\
cfafi — CloudFlare Agent First Interface.

Purpose
-------
Agent-first CLI for managing CloudFlare state in the AgentCulture org.
Every verb has a markdown-default output, a `--json` opt-in, and
structured errors. Mutations default to dry-run; pass `--apply` to
commit.

Commands (v0.1.0)
-----------------
  cfafi whoami                    Verify the configured CloudFlare API token.
  cfafi zones list                List zones in the token's account.
  cfafi dns create ZONE TYPE NAME CONTENT [--apply]
                                  Create a DNS record. Dry-run by default.
  cfafi learn                     This prompt. Supports --json.
  cfafi explain <path>...         Markdown docs for any noun/verb path.

Credentials
-----------
cfafi reads two environment variables and never touches the filesystem:
  CLOUDFLARE_API_TOKEN   required for every verb
  CLOUDFLARE_ACCOUNT_ID  required for account-scoped verbs (Pages, Workers)

Secure loading pattern (recommended):
  1. Store credentials in a file owned by the agent's POSIX user,
     mode 0600, outside any git-tracked directory:
       chmod 600 ~/.config/agent/cfafi.env
  2. In your agent script, source it just before invoking cfafi:
       set -a; . ~/.config/agent/cfafi.env; set +a
       cfafi zones list
  3. Do NOT commit that file, and do NOT keep a world-readable `.env`
     in the repo root — other users / agents on the host can read it.

Machine-readable output
-----------------------
Every command supports `--json`. List commands emit a CloudFlare-shape
envelope `{success, errors, messages, result, result_info}`. Errors in
JSON mode emit `{code, message, remediation}` to stderr.

Exit codes
----------
  0 success
  1 user-input error (bad flag, missing arg)
  2 environment/setup error (missing CLOUDFLARE_API_TOKEN)
  3 authentication error (401/403 from CloudFlare — rotate/scope token)
  4 upstream CloudFlare API error (non-2xx, network)

More detail
-----------
  cfafi explain whoami
  cfafi explain zones list
  cfafi explain dns create

Homepage: https://github.com/agentculture/cfafi
"""


def _json_payload() -> dict[str, object]:
    return {
        "tool": "cfafi",
        "version": __version__,
        "purpose": "Agent-first CLI for CloudFlare management in the AgentCulture org.",
        "commands": [
            {"path": ["whoami"], "summary": "Verify the configured CloudFlare API token."},
            {"path": ["zones", "list"], "summary": "List zones in the token's account."},
            {"path": ["dns", "create"], "summary": "Create a DNS record (dry-run default)."},
            {"path": ["learn"], "summary": "This prompt."},
            {"path": ["explain"], "summary": "Markdown docs by noun/verb path."},
        ],
        "exit_codes": {
            "0": "success",
            "1": "user-input error",
            "2": "environment/setup error",
            "3": "authentication error",
            "4": "upstream API error",
        },
        "env": {
            "CLOUDFLARE_API_TOKEN": "required",
            "CLOUDFLARE_ACCOUNT_ID": "required for Pages/Workers account-scoped verbs",
        },
        "secure_loading": (
            "store creds in a 0600 file owned by the agent user, then "
            "'set -a; . /path/to/cfafi.env; set +a' before invoking cfafi"
        ),
        "json_support": True,
        "dry_run_policy": "mutations default to dry-run; pass --apply to commit",
        "explain_pointer": "cfafi explain <path> (e.g. 'cfafi explain dns create')",
    }


def cmd_learn(args: argparse.Namespace) -> int:
    json_mode = bool(getattr(args, "json", False))
    if json_mode:
        emit_result(_json_payload(), json_mode=True)
    else:
        emit_result(_TEXT, json_mode=False)
    return 0


def register(sub: argparse._SubParsersAction) -> None:
    p = sub.add_parser("learn", help="Print a structured self-teaching prompt for agent consumers.")
    p.add_argument("--json", action="store_true", help="Emit structured JSON.")
    p.set_defaults(func=cmd_learn)
