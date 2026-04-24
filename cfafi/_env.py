"""Environment-variable access — the sole credential ingress for cfafi.

The installed CLI never reads ``.env`` or config files. Callers are
responsible for exporting the right variables (see ``cfafi learn`` for
secure-loading patterns).
"""

from __future__ import annotations

import os

from cfafi.cli._errors import EXIT_ENV_ERROR, CfafiError


def require_env(name: str) -> str:
    """Return ``os.environ[name]`` or raise CfafiError(EXIT_ENV_ERROR)."""
    value = os.environ.get(name)
    if not value:
        raise CfafiError(
            code=EXIT_ENV_ERROR,
            message=f"{name} not set",
            remediation=(
                f"export {name}=... in your shell. For secure loading "
                "patterns see `cfafi learn`; for token scopes see "
                "docs/SETUP.md."
            ),
        )
    return value
