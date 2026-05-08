"""Common types and pure helpers for the remote-login orchestrator."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Names:
    tunnel_name: str
    app_name: str
    service_token_name: str
    policy_name: str
    service_token_policy_name: str


def derive_names(
    *,
    hostname: str,
    tunnel_name: str | None = None,
    app_name: str | None = None,
    service_token_name: str | None = None,
) -> Names:
    """Derive default resource names from a hostname.

    The slugged tunnel name replaces dots with dashes so it survives
    CloudFlare's tunnel-name validation (alphanumerics + dashes only).
    """
    tn = tunnel_name or hostname.replace(".", "-")
    an = app_name or hostname
    stn = service_token_name or f"{hostname}-svc"
    return Names(
        tunnel_name=tn,
        app_name=an,
        service_token_name=stn,
        policy_name=f"{an}-allow",
        service_token_policy_name=f"{an}-svc-allow",
    )


@dataclass(frozen=True)
class Context:
    """Runtime context shared across all _remote_login helpers."""

    account_id: str
    zone_id: str
    hostname: str
    names: Names
    service: str | None = None


@dataclass
class StepRecord:
    """One step of a setup or teardown plan."""

    name: str    # e.g. "tunnel", "dns", "access-app"
    action: str  # "ensured" | "skipped" | "deleted" | "absent"
    detail: str  # human-readable, no secrets


@dataclass(frozen=True)
class SetupResult:
    team_domain: str | None
    tunnel_id: str
    tunnel_name: str
    tunnel_token: str | None
    dns_record_id: str
    dns_target: str
    access_app_id: str
    policy_id: str
    policy_emails: list[str]
    policy_domains: list[str]
    service_token_client_id: str | None
    service_token_client_secret: str | None
    steps: list[StepRecord]
    sealed_in: dict[str, str] = field(default_factory=dict)
    # Added in #28: tunnel ingress route + non_identity service-token policy.
    # Defaulted to None so older test fixtures keep compiling.
    tunnel_service: str | None = None
    service_token_policy_id: str | None = None


@dataclass(frozen=True)
class ShowResult:
    team_domain: str | None
    tunnel: dict | None
    dns: dict | None
    access_app: dict | None
    policy: dict | None
    service_token: dict | None
    sealed_in_status: dict[str, dict | None] = field(default_factory=dict)
    # Added in #28: see SetupResult note above.
    tunnel_config: dict | None = None
    service_token_policy: dict | None = None


@dataclass
class TeardownResult:
    steps: list[StepRecord]


import cultureflare._api as _api  # noqa: E402  (after dataclass defs to keep top-of-file lean)
from cultureflare.cli._errors import EXIT_USER_ERROR, CfafiError


def resolve_zone(hostname: str) -> tuple[str, str]:
    """Return (zone_id, zone_name) for the longest-suffix zone match.

    Raises CfafiError(EXIT_USER_ERROR) if no zone in the account
    is a suffix of the hostname.
    """
    candidates: list[tuple[str, str]] = []
    for zone in _api.paginate("/zones"):
        name = zone.get("name") or ""
        if hostname == name or hostname.endswith("." + name):
            candidates.append((zone.get("id", ""), name))
    if not candidates:
        raise CfafiError(
            code=EXIT_USER_ERROR,
            message=f"no zone in this account is a suffix of {hostname}",
            remediation="run `cultureflare zones list` to see accessible zones",
        )
    candidates.sort(key=lambda z: len(z[1]), reverse=True)
    return candidates[0]
