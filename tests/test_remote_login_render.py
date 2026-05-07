"""Tests for cfafi._remote_login._render."""

from cfafi._remote_login._common import (
    SetupResult, ShowResult, StepRecord, TeardownResult,
)
from cfafi._remote_login._render import (
    render_setup_markdown, render_setup_json,
    render_show_markdown, render_show_json,
    render_teardown_markdown, render_teardown_json,
    render_setup_dryrun_markdown,
)


def _setup_fixture(with_st: bool = True) -> SetupResult:
    return SetupResult(
        team_domain="ac.cloudflareaccess.com",
        tunnel_id="tun-1", tunnel_name="irc-culture-dev",
        tunnel_token="TUN-TOK",
        dns_record_id="rec-1",
        dns_target="tun-1.cfargotunnel.com",
        access_app_id="app-1",
        policy_id="pol-1",
        policy_emails=["me@example.com"],
        policy_domains=["@example.com"],
        service_token_client_id="CID" if with_st else None,
        service_token_client_secret="SEC" if with_st else None,
        steps=[
            StepRecord("zero-trust-org", "ensured", "existing"),
            StepRecord("tunnel", "ensured", "irc-culture-dev"),
            StepRecord("dns", "ensured", "CNAME"),
            StepRecord("access-app", "ensured", "id=app-1"),
            StepRecord("allow-policy", "ensured", "id=pol-1"),
            *([StepRecord("service-token", "ensured", "CID")] if with_st else []),
        ],
    )


def test_render_setup_markdown_includes_all_section_keys():
    md = render_setup_markdown(_setup_fixture(), hostname="irc.culture.dev")
    for key in (
        "**CF_TEAM_DOMAIN:**", "**TUNNEL_NAME:**", "**TUNNEL_ID:**",
        "**TUNNEL_TOKEN:**", "**DNS:**", "**ACCESS_APP_ID:**",
        "**POLICY:**",
        "**SERVICE_TOKEN_CLIENT_ID:**", "**SERVICE_TOKEN_CLIENT_SECRET:**",
    ):
        assert key in md, f"missing section {key}"
    assert "TUN-TOK" in md
    assert "SEC" in md
    assert "## Steps" in md
    assert "Remote login set up" in md


def test_render_setup_markdown_omits_service_token_when_absent():
    md = render_setup_markdown(_setup_fixture(with_st=False), hostname="irc.culture.dev")
    assert "**SERVICE_TOKEN_CLIENT_ID:**" not in md
    assert "**SERVICE_TOKEN_CLIENT_SECRET:**" not in md


def test_render_setup_json_envelope_shape():
    env = render_setup_json(_setup_fixture(), hostname="irc.culture.dev")
    assert env["success"] is True
    assert env["errors"] == []
    r = env["result"]
    assert r["team_domain"] == "ac.cloudflareaccess.com"
    assert r["tunnel_token"] == "TUN-TOK"
    assert r["service_token_client_secret"] == "SEC"
    assert r["dns"]["target"] == "tun-1.cfargotunnel.com"


def test_render_setup_dryrun_markdown_shows_plan_and_no_secrets():
    md = render_setup_dryrun_markdown(
        hostname="irc.culture.dev",
        tunnel_name="irc-culture-dev",
        app_name="irc.culture.dev",
        emails=["me@example.com"],
        domains=[],
        with_service_token=True,
        session_duration="24h",
    )
    assert "Dry-run" in md
    assert "## Plan" in md
    assert "TUN-TOK" not in md
    assert "tunnel" in md.lower()
    assert "dns" in md.lower()


def test_render_show_markdown_marks_missing_resources():
    show = ShowResult(
        team_domain="ac.cloudflareaccess.com",
        tunnel={"id": "tun-1", "name": "irc-culture-dev"},
        dns=None,
        access_app=None,
        policy=None,
        service_token=None,
    )
    md = render_show_markdown(show, hostname="irc.culture.dev")
    assert "Remote login state" in md
    assert "tun-1" in md
    assert "(not found)" in md  # dns / app / policy / svc all missing


def test_render_teardown_markdown_lists_deleted_steps():
    td = TeardownResult(steps=[
        StepRecord("service-token", "deleted", "id=st-1"),
        StepRecord("allow-policy", "deleted", "id=pol-1"),
        StepRecord("access-app", "deleted", "id=app-1"),
        StepRecord("dns", "deleted", "id=rec-1"),
        StepRecord("tunnel", "deleted", "id=tun-1"),
    ])
    md = render_teardown_markdown(td, hostname="irc.culture.dev")
    assert "Remote login torn down" in md
    for s in ("service-token", "allow-policy", "access-app", "dns", "tunnel"):
        assert s in md


def test_render_show_json_envelope_shape():
    show = ShowResult(
        team_domain="ac.cloudflareaccess.com",
        tunnel={"id": "tun-1", "name": "irc-culture-dev"},
        dns=None,
        access_app=None,
        policy=None,
        service_token=None,
    )
    env = render_show_json(show, hostname="irc.culture.dev")
    assert env["success"] is True
    r = env["result"]
    assert r["team_domain"] == "ac.cloudflareaccess.com"
    assert r["tunnel"]["id"] == "tun-1"
    assert r["dns"] is None


def test_render_teardown_json_envelope_shape():
    td = TeardownResult(steps=[
        StepRecord("dns", "deleted", "id=rec-1"),
    ])
    env = render_teardown_json(td, hostname="irc.culture.dev")
    assert env["success"] is True
    assert env["result"]["steps"][0]["name"] == "dns"
    assert env["result"]["steps"][0]["action"] == "deleted"


def test_render_teardown_markdown_empty_steps_says_nothing_to_delete():
    md = render_teardown_markdown(
        TeardownResult(steps=[]), hostname="irc.culture.dev",
    )
    assert "Nothing to delete." in md
    assert "1." not in md


def test_render_show_markdown_marks_team_domain_not_found_when_none():
    show = ShowResult(
        team_domain=None, tunnel=None, dns=None,
        access_app=None, policy=None, service_token=None,
    )
    md = render_show_markdown(show, hostname="irc.culture.dev")
    assert "**zero-trust-org:** (not found)" in md


def test_render_show_markdown_warns_on_unproxied_cname():
    show = ShowResult(
        team_domain="ac.cloudflareaccess.com",
        tunnel={"id": "tun-1", "name": "irc-culture-dev"},
        dns={
            "id": "rec-1", "type": "CNAME", "name": "irc.culture.dev",
            "content": "tun-1.cfargotunnel.com", "proxied": False,
        },
        access_app=None, policy=None, service_token=None,
    )
    md = render_show_markdown(show, hostname="irc.culture.dev")
    assert "unproxied" in md
    assert "⚠" in md
    assert "Access bypassed" in md
    # The healthy ✓ marker MUST NOT appear on this line.
    dns_line = next(line for line in md.splitlines() if "**dns:**" in line)
    assert "✓" not in dns_line


def test_render_setup_markdown_renders_domains_only_policy():
    result = SetupResult(
        team_domain="ac.cloudflareaccess.com",
        tunnel_id="tun-1", tunnel_name="irc-culture-dev",
        tunnel_token="TUN-TOK",
        dns_record_id="rec-1",
        dns_target="tun-1.cfargotunnel.com",
        access_app_id="app-1",
        policy_id="pol-1",
        policy_emails=[],
        policy_domains=["@example.com"],
        service_token_client_id=None,
        service_token_client_secret=None,
        steps=[],
    )
    md = render_setup_markdown(result, hostname="irc.culture.dev")
    assert "**POLICY:** allow-domain [@example.com]" in md
    assert "allow [" not in md
