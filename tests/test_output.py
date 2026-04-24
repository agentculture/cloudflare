"""Tests for cfafi.cli._output."""

import io
import json

import pytest

from cfafi.cli._errors import EXIT_API, EXIT_USER_ERROR, CfafiError
from cfafi.cli._output import (
    emit_error,
    emit_json,
    emit_kv,
    emit_result,
    emit_table,
)


def test_emit_result_text_adds_newline():
    buf = io.StringIO()
    emit_result("hello", json_mode=False, stream=buf)
    assert buf.getvalue() == "hello\n"


def test_emit_result_text_preserves_existing_newline():
    buf = io.StringIO()
    emit_result("hello\n", json_mode=False, stream=buf)
    assert buf.getvalue() == "hello\n"


def test_emit_result_json_dumps_payload():
    buf = io.StringIO()
    emit_result({"a": 1}, json_mode=True, stream=buf)
    assert json.loads(buf.getvalue()) == {"a": 1}


def test_emit_error_text_two_lines():
    buf = io.StringIO()
    err = CfafiError(code=EXIT_USER_ERROR, message="bad", remediation="fix it")
    emit_error(err, json_mode=False, stream=buf)
    assert buf.getvalue() == "error: bad\nhint: fix it\n"


def test_emit_error_text_no_hint_when_empty():
    buf = io.StringIO()
    err = CfafiError(code=EXIT_API, message="boom")
    emit_error(err, json_mode=False, stream=buf)
    assert buf.getvalue() == "error: boom\n"


def test_emit_error_json_envelope():
    buf = io.StringIO()
    err = CfafiError(code=EXIT_API, message="boom", remediation="retry")
    emit_error(err, json_mode=True, stream=buf)
    payload = json.loads(buf.getvalue())
    assert payload == {"code": EXIT_API, "message": "boom", "remediation": "retry"}


def test_emit_table_markdown_rendering():
    buf = io.StringIO()
    emit_table(
        headers=["ID", "NAME", "STATUS"],
        rows=[
            ["abc123", "culture.dev", "active"],
            ["def456", "agentirc.dev", "active"],
        ],
        stream=buf,
    )
    out = buf.getvalue()
    assert out == (
        "| ID | NAME | STATUS |\n"
        "| --- | --- | --- |\n"
        "| abc123 | culture.dev | active |\n"
        "| def456 | agentirc.dev | active |\n"
    )


def test_emit_table_escapes_pipes_in_cells():
    buf = io.StringIO()
    emit_table(headers=["A"], rows=[["x|y"]], stream=buf)
    assert "x\\|y" in buf.getvalue()


def test_emit_kv_markdown_rendering():
    buf = io.StringIO()
    emit_kv(
        [("id", "abc"), ("status", "active"), ("expires_on", "never")],
        stream=buf,
    )
    assert buf.getvalue() == (
        "- **id:** abc\n"
        "- **status:** active\n"
        "- **expires_on:** never\n"
    )


def test_emit_table_raises_on_mismatched_row_length():
    buf = io.StringIO()
    with pytest.raises(ValueError) as excinfo:
        emit_table(headers=["A", "B"], rows=[["x", "y", "z"]], stream=buf)
    assert "3 cells" in str(excinfo.value) and "expected 2" in str(excinfo.value)


def test_emit_table_escapes_pipes_in_headers():
    buf = io.StringIO()
    emit_table(headers=["ID", "NAME|TYPE"], rows=[["x", "y"]], stream=buf)
    # Header row renders the pipe as \| so markdown parsers don't misread:
    assert "| ID | NAME\\|TYPE |\n" in buf.getvalue()


def test_emit_kv_collapses_newlines_in_value():
    buf = io.StringIO()
    emit_kv([("multiline", "line1\nline2\rline3")], stream=buf)
    # A single bullet, no embedded newlines breaking the list structure:
    assert buf.getvalue() == "- **multiline:** line1 line2 line3\n"


def test_emit_json_writes_envelope():
    buf = io.StringIO()
    emit_json({"success": True, "result": [1, 2, 3]}, stream=buf)
    assert json.loads(buf.getvalue()) == {"success": True, "result": [1, 2, 3]}
