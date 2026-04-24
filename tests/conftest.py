"""Shared pytest fixtures — fixture-backed HTTP stub + env setup."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from cfafi import _api

FIXTURES = Path(__file__).parent / "fixtures"


def load_fixture(name: str) -> dict:
    """Load tests/fixtures/<name>.json as a dict."""
    return json.loads((FIXTURES / f"{name}.json").read_text())


class Stub:
    """Controllable replacement for cfafi._api.http_request.

    - ``set(method, path, response_or_error)`` programs a fallback keyed
      by (method, path). Any query string is ignored for matching.
    - ``queue(*items)`` stacks responses returned FIFO across calls
      (used for pagination tests where the same path is hit with
      different ``page=`` values).
    - ``stub.calls`` is the list of ``(method, path, payload, query)``
      tuples recorded in order.
    """

    def __init__(self) -> None:
        self.calls: list[tuple[str, str, dict | None, dict]] = []
        self._responses: dict[tuple[str, str], object] = {}
        self._queue: list[object] = []

    def set(self, method: str, path: str, response_or_error: object) -> None:
        self._responses[(method, path)] = response_or_error

    def set_fixture(self, method: str, path: str, fixture_name: str) -> None:
        self.set(method, path, load_fixture(fixture_name))

    def queue(self, *items: object) -> None:
        self._queue.extend(items)

    def __call__(self, method: str, path: str, *, payload=None, query=None) -> dict:
        q = dict(query or {})
        self.calls.append((method, path, payload, q))
        if self._queue:
            item = self._queue.pop(0)
        else:
            key = (method, path)
            if key not in self._responses:
                raise AssertionError(f"unprogrammed call: {method} {path} query={q}")
            item = self._responses[key]
        if isinstance(item, Exception):
            raise item
        return item


@pytest.fixture
def http_stub(monkeypatch):
    stub = Stub()
    monkeypatch.setattr(_api, "http_request", stub)
    return stub


@pytest.fixture(autouse=True)
def _default_env(monkeypatch):
    """Every CLI test gets valid-looking CloudFlare env vars by default."""
    monkeypatch.setenv("CLOUDFLARE_API_TOKEN", "test-token")
    monkeypatch.setenv("CLOUDFLARE_ACCOUNT_ID", "test-account")
