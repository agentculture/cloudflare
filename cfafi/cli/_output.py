"""stdout / stderr helpers with a strict split.

Rule: results go to stdout, diagnostics and errors go to stderr. Agents
parsing cfafi output rely on this invariant. JSON mode routes payloads
to the same streams — never mixes them.
"""

from __future__ import annotations

import json
import sys
from typing import Any, Iterable, Sequence, TextIO

from cfafi.cli._errors import CfafiError


def emit_result(data: Any, *, json_mode: bool, stream: TextIO | None = None) -> None:
    """Write a command result. Text mode stringifies, JSON mode dumps."""
    s = stream if stream is not None else sys.stdout
    if json_mode:
        json.dump(data, s, ensure_ascii=False)
        s.write("\n")
        return
    text = data if isinstance(data, str) else str(data)
    s.write(text)
    if not text.endswith("\n"):
        s.write("\n")


def emit_error(err: CfafiError, *, json_mode: bool, stream: TextIO | None = None) -> None:
    """Write a CfafiError to stderr (or the given stream)."""
    s = stream if stream is not None else sys.stderr
    if json_mode:
        json.dump(err.to_dict(), s, ensure_ascii=False)
        s.write("\n")
        return
    s.write(f"error: {err.message}\n")
    if err.remediation:
        s.write(f"hint: {err.remediation}\n")


def emit_diagnostic(message: str, *, stream: TextIO | None = None) -> None:
    """Human-readable progress/summary line — stderr only."""
    s = stream if stream is not None else sys.stderr
    s.write(message if message.endswith("\n") else message + "\n")


def emit_json(payload: Any, *, stream: TextIO | None = None) -> None:
    """Dump a JSON payload (used when the caller already holds a full envelope)."""
    s = stream if stream is not None else sys.stdout
    json.dump(payload, s, ensure_ascii=False)
    s.write("\n")


def _escape_cell(value: Any) -> str:
    # Pipes break markdown tables; newlines/CRs/tabs collapse to spaces.
    return (
        str(value)
        .replace("|", "\\|")
        .replace("\n", " ")
        .replace("\r", " ")
        .replace("\t", " ")
    )


def emit_table(
    *,
    headers: Sequence[str],
    rows: Iterable[Sequence[Any]],
    stream: TextIO | None = None,
) -> None:
    """Render a pipe-delimited markdown table. Matches `cf_output` shell shape."""
    s = stream if stream is not None else sys.stdout
    ncols = len(headers)
    s.write("| " + " | ".join(_escape_cell(h) for h in headers) + " |\n")
    s.write("| " + " | ".join(["---"] * ncols) + " |\n")
    for row in rows:
        if len(row) != ncols:
            raise ValueError(
                f"emit_table: row has {len(row)} cells, expected {ncols}"
            )
        s.write("| " + " | ".join(_escape_cell(c) for c in row) + " |\n")


def emit_kv(
    pairs: Iterable[tuple[str, Any]],
    *,
    stream: TextIO | None = None,
) -> None:
    """Render ``- **key:** value`` bullets. Matches `cf_output_kv` shell shape."""
    s = stream if stream is not None else sys.stdout
    for key, value in pairs:
        safe_value = str(value).replace("\n", " ").replace("\r", " ")
        s.write(f"- **{key}:** {safe_value}\n")
