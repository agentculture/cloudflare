#!/usr/bin/env bash
# List zones in the configured CloudFlare account.
#
# Usage: cf-zones.sh [--json]
#
# Calls /zones. Renders a markdown table of id, name, status, and plan
# name. --json passes the raw API response through for bots and jq
# pipelines.

set -euo pipefail

mode=md
for arg in "$@"; do
  case "$arg" in
    --json) mode=json ;;
    -h|--help)
      sed -n 's/^# \{0,1\}//p' "$0" | head -8
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

response=$(cf_api_paginated /zones)

if [[ "$mode" == "md" ]]; then
  count=$(printf '%s' "$response" | jq -r '.result | length')
  printf '## Zones (%s)\n\n' "$count"
fi

# shellcheck disable=SC2016  # single-quoted jq filter
cf_output "$response" "$mode" \
  '.result[] | [.id, .name, .status, (.plan.name // "—")] | @tsv' \
  "$(printf 'ID\tNAME\tSTATUS\tPLAN')"
