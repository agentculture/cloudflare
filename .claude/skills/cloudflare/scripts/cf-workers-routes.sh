#!/usr/bin/env bash
# List Workers routes across all zones in the configured account.
#
# Usage: cf-workers-routes.sh [--json]
#
# Performs n+1 API calls: GET /zones once, then one
# GET /zones/<zone_id>/workers/routes per zone. Results are merged
# into a single array with .zone_name attached to each route, and
# rendered as a markdown table (ZONE / PATTERN / SCRIPT / ENABLED)
# or a synthetic CloudFlare-shaped JSON envelope with --json.
#
# Cost scales linearly with zones in the account. For accounts with
# many zones, prefer inspecting one zone at a time.

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

# Step 1: enumerate zones the token can see (paginated — some accounts
# have >50 zones).
zones_response=$(cf_api_paginated /zones)
zone_count=$(printf '%s' "$zones_response" | jq -r '.result | length')

# Step 2: fetch routes per zone, accumulate into a single array with
# .zone_name attached so the final table can group routes by zone.
all_routes='[]'
while IFS=$'\t' read -r zone_id zone_name; do
  [[ -z "$zone_id" ]] && continue
  routes_response=$(cf_api_paginated "/zones/$zone_id/workers/routes")
  enriched=$(printf '%s' "$routes_response" | jq --arg zname "$zone_name" \
    '(.result // []) | map(. + {zone_name: $zname})')
  all_routes=$(jq -s 'add' <(printf '%s' "$all_routes") <(printf '%s' "$enriched"))
done < <(printf '%s' "$zones_response" | jq -r '.result[]? | [.id, .name] | @tsv')

# Synthetic envelope so --json output matches the shape of other cf-* scripts
combined=$(jq -n --argjson routes "$all_routes" \
  '{success: true, errors: [], messages: [], result: $routes}')

if [[ "$mode" == "md" ]]; then
  route_count=$(printf '%s' "$all_routes" | jq 'length')
  printf '## Workers routes across %s zone(s) (%s)\n\n' "$zone_count" "$route_count"
fi

# shellcheck disable=SC2016  # single-quoted jq filter
cf_output "$combined" "$mode" \
  '.result[] | [.zone_name, .pattern, (.script // "—"), ((.enabled // true) | tostring)] | @tsv' \
  "$(printf 'ZONE\tPATTERN\tSCRIPT\tENABLED')"
