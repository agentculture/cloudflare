"""Tests for cfafi._env."""

import pytest

from cfafi._env import require_env
from cfafi.cli._errors import EXIT_ENV_ERROR, CfafiError


def test_require_env_returns_value_when_set(monkeypatch):
    monkeypatch.setenv("CFAFI_TEST_VAR", "hello")
    assert require_env("CFAFI_TEST_VAR") == "hello"


def test_require_env_raises_on_missing(monkeypatch):
    monkeypatch.delenv("CFAFI_TEST_MISSING", raising=False)
    with pytest.raises(CfafiError) as excinfo:
        require_env("CFAFI_TEST_MISSING")
    assert excinfo.value.code == EXIT_ENV_ERROR
    assert "CFAFI_TEST_MISSING" in excinfo.value.message
    assert "cfafi learn" in excinfo.value.remediation


def test_require_env_treats_empty_as_missing(monkeypatch):
    monkeypatch.setenv("CFAFI_TEST_EMPTY", "")
    with pytest.raises(CfafiError) as excinfo:
        require_env("CFAFI_TEST_EMPTY")
    assert excinfo.value.code == EXIT_ENV_ERROR
