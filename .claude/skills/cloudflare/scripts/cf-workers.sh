#!/usr/bin/env bash
# List Workers scripts in the configured CloudFlare account.
#
# Usage: cf-workers.sh [--json]
#
# Calls /accounts/<CLOUDFLARE_ACCOUNT_ID>/workers/scripts. Renders a
# markdown table of script id (name), handlers, modified_on, and usage
# model. --json emits the raw API response.
#
# Phase 1 intentionally does NOT list per-zone Workers routes — that
# requires enumerating every zone and is not needed for current
# visibility goals. Add cf-workers-routes.sh in a follow-up when the
# need is concrete.

set -euo pipefail

mode=md
for arg in "$@"; do
  case "$arg" in
    --json) mode=json ;;
    -h|--help)
      sed -n 's/^# \{0,1\}//p' "$0" | head -13
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
cf_require_account_id

response=$(cf_api_paginated "/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts")

if [[ "$mode" == "md" ]]; then
  count=$(printf '%s' "$response" | jq -r '.result | length')
  printf '## Workers scripts (%s)\n\n' "$count"
fi

# shellcheck disable=SC2016  # single-quoted jq filter
cf_output "$response" "$mode" \
  '.result[] | [.id, ((.handlers // []) | join(",") | if . == "" then "—" else . end), .modified_on, (.usage_model // "—")] | @tsv' \
  "$(printf 'NAME\tHANDLERS\tMODIFIED_ON\tUSAGE_MODEL')"
