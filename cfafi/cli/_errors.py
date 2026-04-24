"""CfafiError and exit-code policy.

Every failure inside cfafi raises :class:`CfafiError`. The top-level
``main()`` catches it, formats via :mod:`cfafi.cli._output`, and exits
with :attr:`CfafiError.code`. No Python traceback ever reaches stderr —
agents can parse our error shape reliably.
"""

from __future__ import annotations

from dataclasses import dataclass

# Exit-code policy.
# 0      = success
# 1      = user-input error (bad flag, missing required arg)
# 2      = environment / setup error (missing CLOUDFLARE_API_TOKEN, etc.)
# 3      = authentication error (401/403 from CloudFlare)
# 4      = upstream CloudFlare API error (non-2xx, network)
EXIT_SUCCESS = 0
EXIT_USER_ERROR = 1
EXIT_ENV_ERROR = 2
EXIT_AUTH = 3
EXIT_API = 4


@dataclass
class CfafiError(Exception):
    """Structured error raised within cfafi; carries a remediation hint.

    Not picklable — ``Exception.__reduce__`` uses ``self.args`` which only
    holds ``message``, while ``__init__`` requires all three fields.
    Cfafi is a synchronous CLI, so this is fine. If a future feature
    needs to ship errors across a multiprocessing boundary, add a
    ``__reduce__`` that returns ``(cls, (self.code, self.message, self.remediation))``.
    """

    code: int
    message: str
    remediation: str = ""

    def __post_init__(self) -> None:
        super().__init__(self.message)

    def to_dict(self) -> dict[str, object]:
        return {
            "code": self.code,
            "message": self.message,
            "remediation": self.remediation,
        }
