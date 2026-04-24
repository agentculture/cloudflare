"""Tests for `cfafi learn`."""

import json

from cfafi.cli import main


def test_learn_text_contains_required_sections(capsys):
    rc = main(["learn"])
    out = capsys.readouterr().out
    assert rc == 0
    for token in ("cfafi", "CLOUDFLARE_API_TOKEN", "--json", "explain", "whoami", "zones", "dns"):
        assert token in out
    assert "secure" in out.lower() or "0600" in out  # credential-loading guidance
    assert len(out) >= 400  # learnability-rubric floor


def test_learn_json_payload(capsys):
    rc = main(["learn", "--json"])
    out = capsys.readouterr().out
    assert rc == 0
    payload = json.loads(out)
    assert payload["tool"] == "cfafi"
    assert payload["json_support"] is True
    assert any(c["path"] == ["whoami"] for c in payload["commands"])
    assert any(c["path"] == ["zones", "list"] for c in payload["commands"])
    assert any(c["path"] == ["dns", "create"] for c in payload["commands"])
    assert "0" in payload["exit_codes"]
    assert "env" in payload and "CLOUDFLARE_API_TOKEN" in payload["env"]
