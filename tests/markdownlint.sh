#!/usr/bin/env bash
# Run markdownlint-cli2 across every markdown file in the repo.
#
# Uses the local .markdownlint-cli2.yaml at the repo root (mirrors the
# workspace global — MD013 and MD060 disabled). Clones include this
# config by default, so CI and local runs use identical rules without
# depending on per-machine setup.
#
# Skips vendored dirs (.git, node_modules, .local) via the config's
# own `ignores` list.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v markdownlint-cli2 >/dev/null 2>&1; then
  echo "ERROR: markdownlint-cli2 is not installed." >&2
  echo "Install with: npm install -g markdownlint-cli2@0.21.0  # same version CI pins" >&2
  exit 127
fi

# markdownlint-cli2 accepts globs directly and honours .markdownlint-cli2.yaml
# in the current directory (or any ancestor). Running from repo root ensures
# it finds the checked-in config.
exec markdownlint-cli2 "**/*.md"
