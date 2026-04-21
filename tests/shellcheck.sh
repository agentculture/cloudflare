#!/usr/bin/env bash
# Run shellcheck across every shell script in the repo.
#
# Discovers scripts two ways:
#   1. By extension: *.sh and *.bash
#   2. By bash/sh shebang: extensionless files under tests/bats/stubs/
#      (e.g. the PATH-injected `curl` mock)
#
# Skips vendored dirs (.git, node_modules, .venv). Suppresses SC1091
# ("not following sourced files") because we intentionally source .env
# at runtime — the parser is vetted separately in tests/bats/_lib.bats.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

mapfile -t files < <(find . \
  \( -path ./.git -o -path ./node_modules -o -path ./.venv \) -prune -o \
  -type f \( -name '*.sh' -o -name '*.bash' \) -print | sort)

if [[ -d tests/bats/stubs ]]; then
  while IFS= read -r -d '' f; do
    if head -c 128 "$f" | grep -qE '^#!.*\b(bash|sh)\b'; then
      files+=("$f")
    fi
  done < <(find tests/bats/stubs -type f ! -name '*.*' -print0)
fi

if ((${#files[@]} == 0)); then
  echo "no shell scripts found" >&2
  exit 0
fi

printf 'Running shellcheck on %d file(s):\n' "${#files[@]}"
printf '  %s\n' "${files[@]}"
echo

shellcheck -e SC1091 "${files[@]}"
