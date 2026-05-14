"""cultureflare — CloudFlare Agent First Interface."""

from importlib.metadata import PackageNotFoundError, version as _pkg_version

# Baked default: kept in sync with pyproject.toml by
# `.claude/skills/version-bump`. At runtime the installed-distribution
# lookup below takes precedence, so TestPyPI dev builds (whose dist
# version is rewritten to "0.3.0.devN" by the publish workflow) report
# their actual version here. The legacy `cfafi` wheel (frozen at 0.2.2)
# is the second-tier fallback for anyone still on the old install.
__version__ = "0.7.0"

try:
    __version__ = _pkg_version("cultureflare")
except PackageNotFoundError:
    try:
        __version__ = _pkg_version("cfafi")
    except PackageNotFoundError:
        pass  # fall through to baked default (source / editable run)
