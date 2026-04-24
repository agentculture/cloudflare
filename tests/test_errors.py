"""Tests for cfafi.cli._errors."""

import pytest

from cfafi.cli._errors import (
    EXIT_API,
    EXIT_AUTH,
    EXIT_ENV_ERROR,
    EXIT_SUCCESS,
    EXIT_USER_ERROR,
    CfafiError,
)


def test_exit_codes_are_distinct_ints():
    codes = {EXIT_SUCCESS, EXIT_USER_ERROR, EXIT_ENV_ERROR, EXIT_AUTH, EXIT_API}
    assert len(codes) == 5
    assert EXIT_SUCCESS == 0
    assert EXIT_USER_ERROR == 1
    assert EXIT_ENV_ERROR == 2
    assert EXIT_AUTH == 3
    assert EXIT_API == 4


def test_cfafi_error_carries_code_and_message():
    err = CfafiError(code=EXIT_USER_ERROR, message="nope")
    assert err.code == EXIT_USER_ERROR
    assert err.message == "nope"
    assert err.remediation == ""
    assert str(err) == "nope"


def test_cfafi_error_to_dict_shape():
    err = CfafiError(code=EXIT_API, message="boom", remediation="retry")
    assert err.to_dict() == {"code": EXIT_API, "message": "boom", "remediation": "retry"}


def test_cfafi_error_is_raisable():
    with pytest.raises(CfafiError) as excinfo:
        raise CfafiError(code=EXIT_AUTH, message="401", remediation="rotate token")
    assert excinfo.value.code == EXIT_AUTH
