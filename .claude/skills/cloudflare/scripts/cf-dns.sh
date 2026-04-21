#!/usr/bin/env bash
# List DNS records for a zone.
#
# Usage: cf-dns.sh ZONE [--json]
#
# ZONE is the zone name (e.g. culture.dev). The script resolves the
# name to a zone id via /zones?name=<ZONE>, then lists records via
# /zones/<id>/dns_records. Renders a markdown table of type, name,
# content, proxied, ttl by default; --json emits the raw records
# response.

set -euo pipefail

mode=md
zone=""
for arg in "$@"; do
  case "$arg" in
    --json) mode=json ;;
    -h|--help)
      sed -n 's/^# \{0,1\}//p' "$0" | head -11
      exit 0
      ;;
    -*)
      echo "ERROR: unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      if [[ -z "$zone" ]]; then
        zone="$arg"
      else
        echo "ERROR: unexpected extra argument: $arg" >&2
        exit 2
      fi
      ;;
  esac
done

if [[ -z "$zone" ]]; then
  echo "ERROR: zone name is required. Usage: cf-dns.sh ZONE [--json]" >&2
  exit 2
fi

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Step 1: resolve zone name → id. URL-encode the zone argument before
# interpolating so a caller passing an unusual character (e.g. `&` or
# `?`) can't inject extra query parameters. jq's @uri matches RFC 3986
# unreserved chars, so ordinary DNS labels (culture.dev) pass through
# unchanged.
zone_encoded=$(jq -rn --arg v "$zone" '$v|@uri')
lookup=$(cf_api "/zones?name=$zone_encoded")
zone_id=$(printf '%s' "$lookup" | jq -r '.result[0].id // empty')
if [[ -z "$zone_id" ]]; then
  echo "ERROR: zone '$zone' not found in the configured account." >&2
  exit 1
fi

# Step 2: list DNS records for that zone. Paginated — active zones
# routinely exceed CloudFlare's default 20-per-page response size.
response=$(cf_api_paginated "/zones/$zone_id/dns_records")

if [[ "$mode" == "md" ]]; then
  count=$(printf '%s' "$response" | jq -r '.result | length')
  printf '## DNS records for %s (%s)\n\n' "$zone" "$count"
fi

# shellcheck disable=SC2016  # single-quoted jq filter
cf_output "$response" "$mode" \
  '.result[] | [.type, .name, .content, (if .proxied then "proxied" else "—" end), (.ttl | tostring)] | @tsv' \
  "$(printf 'TYPE\tNAME\tCONTENT\tPROXIED\tTTL')"
