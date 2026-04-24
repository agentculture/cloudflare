#!/usr/bin/env bash
# Unified CloudFlare inventory: token + zones + Workers scripts +
# Workers routes + Pages projects in a single markdown digest.
#
# Usage:
#   cf-status.sh            # markdown digest (all sections)
#   cf-status.sh --json     # structured JSON envelope with one key per section
#
# Internally calls the other cf-*.sh scripts in --json mode and composes
# their output. Fetch logic stays in the per-resource scripts; this one
# only formats. Fails fast if any child call fails — each child prints
# its own error to stderr before exiting, and set -e propagates here.
#
# Cost: one /user/tokens/verify call + one paginated /zones + one
# /accounts/:id/workers/scripts + n /zones/:id/workers/routes (n = zones)
# + one paginated /accounts/:id/pages/projects. Same API surface as
# running the five scripts individually; only the rendering is new.

set -euo pipefail
# Propagate set -e into $(...) subshells so a failing child script
# terminates cf-status.sh instead of having its error swallowed by
# the command substitution. _lib.sh sets this too, but this script
# captures child output BEFORE sourcing _lib.sh, so we must set it
# ourselves up front.
shopt -s inherit_errexit

mode=md
for arg in "$@"; do
  case "$arg" in
    --json) mode=json ;;
    -h|--help)
      # Skip line 1 so the shebang doesn't render as "!/usr/bin/env bash".
      # `2,$` is a sed address range (lines 2 to end), not a shell expansion.
      # shellcheck disable=SC2016  # single-quoted sed script with literal $
      sed -n '2,${s/^# \{0,1\}//p;}' "$0" | head -18
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

token_json=$("$SCRIPT_DIR/cf-whoami.sh" --json)
zones_json=$("$SCRIPT_DIR/cf-zones.sh" --json)
workers_json=$("$SCRIPT_DIR/cf-workers.sh" --json)
routes_json=$("$SCRIPT_DIR/cf-workers-routes.sh" --json)
pages_json=$("$SCRIPT_DIR/cf-pages.sh" --json)

# result_count JSON
# Extracts .result | length from a CloudFlare-shaped envelope. Used for
# the (count) suffix in every markdown section heading so the jq filter
# literal lives in one place (ref: SonarCloud rule S1192).
result_count() {
  local json="$1"
  printf '%s' "$json" | jq -r '.result | length'
  return $?
}

if [[ "$mode" == "json" ]]; then
  # --slurpfile via process substitution keeps the JSON payloads off
  # the jq argv (--argjson puts them on the command line, which would
  # risk E2BIG "Argument list too long" on accounts with enough zones
  # / routes to push us past ARG_MAX). Each --slurpfile var is an
  # array of top-level JSON values; we take [0] since each child emits
  # exactly one envelope.
  # shellcheck disable=SC2016  # single-quoted jq filter
  jq -n \
    --slurpfile token   <(printf '%s' "$token_json") \
    --slurpfile zones   <(printf '%s' "$zones_json") \
    --slurpfile workers <(printf '%s' "$workers_json") \
    --slurpfile routes  <(printf '%s' "$routes_json") \
    --slurpfile pages   <(printf '%s' "$pages_json") \
    '{success: true, errors: [], messages: [], result: {
        token:           ($token[0].result   // {}),
        zones:           ($zones[0].result   // []),
        workers_scripts: ($workers[0].result // []),
        workers_routes:  ($routes[0].result  // []),
        pages_projects:  ($pages[0].result   // [])
    }}'
  exit 0
fi

# Markdown mode: reuse _lib.sh output helpers for consistent rendering.
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"

printf '# CloudFlare status\n\n'

printf '## Token\n\n'
# shellcheck disable=SC2016  # single-quoted jq filter
cf_output_kv "$token_json" md '
  .result as $r |
  [["id",         $r.id],
   ["status",     $r.status],
   ["expires_on", ($r.expires_on // "never")]]
  | .[] | @tsv
'

printf '\n## Zones (%s)\n\n' "$(result_count "$zones_json")"
# shellcheck disable=SC2016  # single-quoted jq filter
cf_output "$zones_json" md \
  '.result[] | [.name, .status, (.plan.name // "—")] | @tsv' \
  "$(printf 'NAME\tSTATUS\tPLAN')"

printf '\n## Workers scripts (%s)\n\n' "$(result_count "$workers_json")"
# shellcheck disable=SC2016  # single-quoted jq filter
cf_output "$workers_json" md \
  '.result[] | [.id, (.modified_on // "—")] | @tsv' \
  "$(printf 'NAME\tMODIFIED_ON')"

printf '\n## Workers routes (%s)\n\n' "$(result_count "$routes_json")"
# shellcheck disable=SC2016  # single-quoted jq filter
cf_output "$routes_json" md \
  '.result[] | [(.zone_name // "—"), .pattern, (.script // "—")] | @tsv' \
  "$(printf 'ZONE\tPATTERN\tSCRIPT')"

printf '\n## Pages projects (%s)\n\n' "$(result_count "$pages_json")"
# shellcheck disable=SC2016  # single-quoted jq filter
cf_output "$pages_json" md \
  '.result[] | [.name, (.production_branch // "—"), (.subdomain // "—"), (.latest_deployment.created_on // "—")] | @tsv' \
  "$(printf 'NAME\tBRANCH\tSUBDOMAIN\tLATEST')"
