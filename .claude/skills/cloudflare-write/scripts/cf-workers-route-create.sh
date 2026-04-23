#!/usr/bin/env bash
# Create a Workers route on a CloudFlare zone.
#
# Usage:
#   cf-workers-route-create.sh ZONE PATTERN SCRIPT [--apply] [--json]
#
# Default is DRY-RUN: resolves the zone, checks no matching
# {pattern,script} route already exists, prints the JSON body it
# would POST, and exits 0 WITHOUT mutating anything. Pass --apply
# to actually create the route.
#
# Arguments:
#   ZONE      zone name (e.g. culture.dev), resolved to id internally
#   PATTERN   URL pattern matching incoming requests, e.g.
#             'culture.dev/afi*'. CF's pattern syntax is domain + path
#             with optional `*` wildcards. Quote it in the shell so
#             the glob doesn't expand.
#   SCRIPT    name of an existing Workers script to route to
#
# Prerequisites for --apply to succeed against the live API:
#   * CLOUDFLARE_API_TOKEN has Zone · Workers Routes · Edit on the zone
#     (all AgentCulture zones if the token is scoped that way; per-zone
#     tokens work too)
#   * SCRIPT must already be uploaded (see cf-worker-create.sh). The
#     CF POST errors out with "script not found" otherwise — we don't
#     pre-check script existence here because the Workers-scripts
#     endpoint requires Account · Workers Scripts · Read, which not
#     every route-creation token will carry.
#
# Flags:
#   --apply   actually POST (without it, dry-run)
#   --json    raw CF response envelope (or simulated body in dry-run)
#
# Exits 1 on: zone not found, matching {pattern,script} route already
#   exists, API error. Exits 2 on usage error.

set -euo pipefail
shopt -s inherit_errexit

mode=md
apply=0
positional=()

for arg in "$@"; do
  case "$arg" in
    --json)   mode=json ;;
    --apply)  apply=1 ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
      exit 0
      ;;
    -*)
      echo "ERROR: unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      positional+=("$arg")
      ;;
  esac
done

if (( ${#positional[@]} != 3 )); then
  echo "ERROR: expected ZONE, PATTERN, and SCRIPT positional args, got ${#positional[@]}" >&2
  echo "usage: cf-workers-route-create.sh ZONE PATTERN SCRIPT [--apply] [--json]" >&2
  exit 2
fi
zone_name="${positional[0]}"
pattern="${positional[1]}"
script_name="${positional[2]}"

# Basic shape check on pattern: non-empty, no newlines, no leading
# scheme (CF patterns are scheme-less — `https://culture.dev/foo*` is
# invalid, `culture.dev/foo*` is correct). Catch the most common
# mistake locally instead of chasing a cryptic CF 400.
if [[ -z "$pattern" || "$pattern" == *$'\n'* ]]; then
  echo "ERROR: invalid route pattern: $pattern" >&2
  exit 2
fi
if [[ "$pattern" == http://* || "$pattern" == https://* ]]; then
  echo "ERROR: route pattern must be scheme-less (e.g. 'culture.dev/afi*'), got: $pattern" >&2
  exit 2
fi

# Worker script names: 1-63 chars, [a-z0-9_-], cannot start/end with
# hyphen or underscore. Same rule as cf-worker-create.sh.
if [[ ! "$script_name" =~ ^[a-z0-9]([a-z0-9_-]{0,61}[a-z0-9])?$ ]]; then
  echo "ERROR: invalid script name: $script_name" >&2
  echo "       must be 1-63 chars, lowercase a-z 0-9 _ -, no leading/trailing _ or -" >&2
  exit 2
fi

# shellcheck source=../../cloudflare/scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Resolve ZONE to a zone ID — same pattern as cf-dns-create.sh.
zones_json=$(cf_api_paginated /zones)
# shellcheck disable=SC2016  # single-quoted jq filter
zone_id=$(printf '%s' "$zones_json" | jq -r --arg name "$zone_name" \
  '[.result[] | select(.name == $name) | .id] | .[0] // ""')

if [[ -z "$zone_id" ]]; then
  echo "ERROR: zone $zone_name not found in this account" >&2
  exit 1
fi

# Idempotency: bail if a route with the same {pattern, script} pair
# already exists on the zone. (CF allows multiple routes with the
# same pattern routing to different scripts, or the same script
# pattern-matching different URLs — only the exact pair is a dup.)
existing_json=$(cf_api_paginated "/zones/$zone_id/workers/routes")
# shellcheck disable=SC2016  # single-quoted jq filter
existing_id=$(printf '%s' "$existing_json" | jq -r \
  --arg p "$pattern" --arg s "$script_name" \
  '[.result[] | select(.pattern == $p and .script == $s) | .id] | .[0] // ""')
if [[ -n "$existing_id" ]]; then
  echo "ERROR: Workers route already exists on $zone_name: $pattern → $script_name (id=$existing_id)" >&2
  echo "       nothing to do. Delete it first via the dashboard or a future cf-workers-route-delete.sh." >&2
  exit 1
fi

# Build the request body.
# shellcheck disable=SC2016  # single-quoted jq filter
body=$(jq -n \
  --arg pattern "$pattern" \
  --arg script  "$script_name" \
  '{pattern: $pattern, script: $script}')

_render_summary_md() {
  local banner="$1"
  printf '%s\n\n' "$banner"
  printf -- '- **zone:** %s (id=%s)\n' "$zone_name" "$zone_id"
  printf -- '- **pattern:** %s\n' "$pattern"
  printf -- '- **script:** %s\n' "$script_name"
  return 0
}

if (( apply == 0 )); then
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n --argjson body "$body" --arg zone_id "$zone_id" --arg zone "$zone_name" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, zone: $zone, zone_id: $zone_id, would_post: $body}}'
    exit 0
  fi
  _render_summary_md "**Dry-run — no changes applied**"
  # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
  printf '\n**would POST** `/zones/%s/workers/routes`:\n\n' "$zone_id"
  # shellcheck disable=SC2016  # literal backticks fence a markdown code block
  printf '```json\n%s\n```\n' "$body"
  exit 0
fi

response=$(cf_api "/zones/$zone_id/workers/routes" -X POST --data-binary "$body")

if [[ "$mode" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

new_id=$(printf '%s' "$response" | jq -r '.result.id // "—"')
_render_summary_md "**Workers route created**"
printf -- '- **route_id:** %s\n' "$new_id"
