#!/usr/bin/env bash
# Create a zone-level Single Redirect in the
# http_request_dynamic_redirect phase.
#
# Usage:
#   cf-redirect-create.sh FROM_HOST TO_HOST [--www] [--status=N] [--apply] [--json]
#
# Default is DRY-RUN: resolves the zone, checks no redirect ruleset
# already exists on it, prints the JSON body that would be POSTed,
# and exits 0 WITHOUT mutating anything. Pass --apply to actually
# create the redirect.
#
# Path + query string are preserved:
#   target_url = concat("https://TO_HOST", http.request.uri.path)
#   preserve_query_string = true
#
# Flags:
#   --www        match both FROM_HOST and www.FROM_HOST
#   --status=N   redirect status code (default 301)
#   --apply      actually POST (without it, this is a dry-run)
#   --json       raw CloudFlare response envelope (or simulated body in dry-run)
#
# Exits 1 on: zone not found, existing redirect ruleset (idempotency),
#   or any API error. Exits 2 on usage error.

set -euo pipefail
shopt -s inherit_errexit

mode=md
apply=0
www=0
status=301
positional=()

for arg in "$@"; do
  case "$arg" in
    --json)   mode=json ;;
    --apply)  apply=1 ;;
    --www)    www=1 ;;
    --status=*) status="${arg#*=}" ;;
    -h|--help)
      # Print the leading comment block only:
      #   skip line 1 (shebang), strip `# ?`, stop at the first
      #   non-comment line. No magic `head -N` constant to drift.
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

if (( ${#positional[@]} != 2 )); then
  echo "ERROR: expected FROM_HOST and TO_HOST positional args, got ${#positional[@]}" >&2
  echo "usage: cf-redirect-create.sh FROM_HOST TO_HOST [--www] [--status=N] [--apply] [--json]" >&2
  exit 2
fi
from_host="${positional[0]}"
to_host="${positional[1]}"

# Validate hostnames early — they interpolate into the wirefilter
# expression and target URL, so anything containing quotes / backticks
# / backslashes would escape the surrounding string literal.
host_re='^[a-zA-Z0-9][a-zA-Z0-9.-]*$'
for h in "$from_host" "$to_host"; do
  if [[ ! "$h" =~ $host_re ]]; then
    echo "ERROR: invalid hostname: $h" >&2
    exit 2
  fi
done

if ! [[ "$status" =~ ^[0-9]+$ ]] || (( 10#$status < 300 || 10#$status > 399 )); then
  echo "ERROR: --status must be a 3xx HTTP code, got: $status" >&2
  exit 2
fi
# Normalize leading zeros (e.g. "0302" → 302) so jq --argjson below
# never sees a JSON-invalid leading-zero number.
status=$((10#$status))

# --www blindly prepends "www." to FROM_HOST, so passing
# www.example.com with --www would produce www.www.example.com in the
# wirefilter expression. Reject instead of silently stripping — a
# loud error is easier to debug than a subtly-wrong redirect rule.
if (( www )) && [[ "$from_host" == www.* ]]; then
  echo "ERROR: --www cannot be combined with a FROM_HOST that already starts with 'www.'" >&2
  echo "       drop the 'www.' prefix from FROM_HOST (the --www flag adds it for you)" >&2
  exit 2
fi

# shellcheck source=../../cloudflare/scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Resolve FROM_HOST to a zone ID. cf_api_paginated handles every page
# automatically; the zone list is small in practice but stay honest.
zones_json=$(cf_api_paginated /zones)
# Use `.[0]` inside jq rather than `jq | head -n 1`. Under pipefail,
# head closing the pipe after one line can send SIGPIPE to jq and make
# the whole pipeline exit non-zero even though the match succeeded.
# shellcheck disable=SC2016  # single-quoted jq filter
zone_id=$(printf '%s' "$zones_json" | jq -r --arg name "$from_host" \
  '[.result[] | select(.name == $name) | .id] | .[0] // ""')

if [[ -z "$zone_id" ]]; then
  echo "ERROR: zone $from_host not found in this account" >&2
  exit 1
fi

# Idempotency: bail if any redirect ruleset already exists on the zone.
# One zone can have at most one ruleset per phase, so POST would fail
# with a CF error anyway — we want a friendlier message instead.
rulesets_json=$(cf_api_paginated "/zones/$zone_id/rulesets")
# shellcheck disable=SC2016  # single-quoted jq filter
existing_redirect_id=$(printf '%s' "$rulesets_json" | jq -r '
  [
    .result[]
    | select(.phase == "http_request_dynamic_redirect")
    | select(.kind == "zone")
    | .id
  ] | .[0] // ""
')

if [[ -n "$existing_redirect_id" ]]; then
  echo "ERROR: redirect ruleset already exists on zone $from_host (id=$existing_redirect_id)" >&2
  echo "Delete it in the CF dashboard or wait for cf-redirect-update.sh (not yet implemented)." >&2
  exit 1
fi

# Build the wirefilter expression. If --www, match apex OR www subdomain.
if (( www )); then
  expression="(http.host eq \"$from_host\") or (http.host eq \"www.$from_host\")"
  from_display="$from_host (apex + www)"
else
  expression="(http.host eq \"$from_host\")"
  from_display="$from_host"
fi

target_expression="concat(\"https://$to_host\", http.request.uri.path)"

# shellcheck disable=SC2016  # single-quoted jq filter
body=$(jq -n \
  --arg expression "$expression" \
  --arg target     "$target_expression" \
  --argjson status_code "$status" \
  '{
    kind: "zone",
    phase: "http_request_dynamic_redirect",
    name: "claudeflare managed redirect",
    description: "Managed by cf-redirect-create.sh in agentculture/cloudflare",
    rules: [{
      expression: $expression,
      action: "redirect",
      action_parameters: {
        from_value: {
          target_url: {
            expression: $target
          },
          status_code: $status_code,
          preserve_query_string: true
        }
      }
    }]
  }')

if (( apply == 0 )); then
  # Dry-run. Emit a synthetic envelope in --json mode so downstream
  # consumers always see the same shape; in md mode, preface the body
  # with a clear "no changes applied" banner.
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n --argjson body "$body" --arg zone_id "$zone_id" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, zone_id: $zone_id, would_post: $body}}'
    exit 0
  fi
  printf '**Dry-run — no changes applied**\n\n'
  printf -- '- **zone:** %s (id=%s)\n' "$from_host" "$zone_id"
  printf -- '- **from:** %s\n' "$from_display"
  printf -- '- **to:** https://%s\n' "$to_host"
  printf -- '- **status:** %s\n' "$status"
  printf -- '- **preserve_query_string:** true\n'
  # shellcheck disable=SC2016  # single-quoted literal backticks wrap markdown inline code
  printf '\n**would POST** `/zones/%s/rulesets`:\n\n' "$zone_id"
  printf '```json\n'
  printf '%s\n' "$body"
  printf '```\n'
  exit 0
fi

# Apply path: POST the ruleset. cf_api forwards trailing curl opts,
# so we pass -X POST + --data directly. The body goes via
# --data-binary to avoid any curl munging of \n inside the JSON.
response=$(cf_api "/zones/$zone_id/rulesets" -X POST --data-binary "$body")

if [[ "$mode" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

new_id=$(printf '%s' "$response" | jq -r '.result.id // "—"')
printf '**Redirect created**\n\n'
printf -- '- **zone:** %s (id=%s)\n' "$from_host" "$zone_id"
printf -- '- **from:** %s\n' "$from_display"
printf -- '- **to:** https://%s\n' "$to_host"
printf -- '- **status:** %s\n' "$status"
printf -- '- **preserve_query_string:** true\n'
printf -- '- **ruleset_id:** %s\n' "$new_id"
