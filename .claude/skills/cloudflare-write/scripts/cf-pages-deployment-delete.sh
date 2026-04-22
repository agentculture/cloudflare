#!/usr/bin/env bash
# Delete a single CloudFlare Pages deployment.
#
# Usage:
#   cf-pages-deployment-delete.sh PROJECT SHORT_ID_OR_ID [--force-canonical] [--apply] [--json]
#
# Default is DRY-RUN: resolves the project + deployment, refuses if the
# target is the aliased (canonical) deployment unless --force-canonical
# is set, prints the DELETE URL it would hit, and exits 0 WITHOUT
# mutating anything. Pass --apply to actually DELETE.
#
# SHORT_ID_OR_ID accepts either the 8-char short_id (first segment of
# the UUID) or the full deployment UUID. Short IDs are unique within a
# project; ambiguous matches are refused.
#
# Flags:
#   --force-canonical   allow deleting the currently-aliased deployment.
#                       Maps to ?force=true on the CF DELETE endpoint.
#                       Without this flag, the canonical deployment is
#                       protected — the redirect-only zone that still
#                       serves agentirc-dev.pages.dev would break.
#   --apply             actually DELETE (without it, this is a dry-run)
#   --json              raw CloudFlare response envelope (or simulated body in dry-run)
#
# Exits 1 on: project not found, deployment not found, canonical guard,
#   API error. Exits 2 on usage error.

set -euo pipefail
shopt -s inherit_errexit

mode=md
apply=0
force_canonical=0
positional=()

for arg in "$@"; do
  case "$arg" in
    --json)             mode=json ;;
    --apply)            apply=1 ;;
    --force-canonical)  force_canonical=1 ;;
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

if (( ${#positional[@]} != 2 )); then
  echo "ERROR: expected PROJECT and SHORT_ID_OR_ID positional args, got ${#positional[@]}" >&2
  echo "usage: cf-pages-deployment-delete.sh PROJECT SHORT_ID_OR_ID [--force-canonical] [--apply] [--json]" >&2
  exit 2
fi
project="${positional[0]}"
target="${positional[1]}"

# Hand-wavy validation: project name is CF-restricted (lowercase,
# digits, dashes), and short_id / id are hex + dashes. Reject anything
# that could escape the URL path. Tighter than strictly necessary, but
# matches the "encode + validate at the boundary" convention.
if [[ ! "$project" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo "ERROR: invalid project name: $project" >&2
  exit 2
fi
if [[ ! "$target" =~ ^[a-fA-F0-9-]+$ ]]; then
  echo "ERROR: invalid deployment id: $target (expected hex + dashes)" >&2
  exit 2
fi

# shellcheck source=../../cloudflare/scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cf_require_account_id

project_encoded=$(jq -rn --arg v "$project" '$v|@uri')

# Fetch project metadata for canonical_deployment.id. The project-detail
# endpoint is a single-object GET, so use cf_api directly, not _paginated.
# Don't silence cf_api's stderr — it distinguishes "project missing"
# from "token lacks scope" / "transport failure" with structured
# .errors, and hiding that turns every failure into the same
# misleading "not found" message. cf_api already prints its own
# diagnostic; we just add a final hint that the project arg was the
# resolution target.
if ! project_json=$(cf_api "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded"); then
  echo "HINT: could not resolve Pages project '$project'. Check the project name with cf-pages.sh." >&2
  exit 1
fi
canonical_id=$(printf '%s' "$project_json" | jq -r '.result.canonical_deployment.id // ""')

# Resolve target to a full deployment id. If the user passed a full
# UUID, we still validate it exists in the listing so "does it exist"
# and "is it canonical" both get answered with one lookup.
#
# Pages list endpoints cap per_page at 10 (CF error code 8000024 on
# per_page >= 11) — same quirk that cf-pages.sh documents. Scope the
# override to this call via a subshell so we don't surprise other
# callers of cf_api_paginated sourced from the same shell.
deployments_json=$(CF_PAGE_SIZE=10 cf_api_paginated "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/deployments")

# shellcheck disable=SC2016  # single-quoted jq filter
matches_json=$(printf '%s' "$deployments_json" | jq --arg t "$target" '
  [
    .result[]
    | select(.id == $t or .short_id == $t or ((.id | startswith($t)) and ($t | length) == 8))
    | {id, short_id, environment, created_on,
       status: (.latest_stage.status // "unknown")}
  ]
')
match_count=$(printf '%s' "$matches_json" | jq 'length')

if (( match_count == 0 )); then
  echo "ERROR: deployment not found in project $project: $target" >&2
  exit 1
fi
if (( match_count > 1 )); then
  echo "ERROR: ambiguous match in project $project: $target matches $match_count deployments" >&2
  printf '%s\n' "$matches_json" | jq -r '.[] | "  - \(.id) (\(.short_id))"' >&2
  exit 1
fi

deployment_id=$(printf '%s' "$matches_json" | jq -r '.[0].id')
short_id=$(printf '%s' "$matches_json" | jq -r '.[0].short_id')
environment=$(printf '%s' "$matches_json" | jq -r '.[0].environment')
status=$(printf '%s' "$matches_json" | jq -r '.[0].status')
created_on=$(printf '%s' "$matches_json" | jq -r '.[0].created_on')

is_canonical=0
if [[ -n "$canonical_id" && "$deployment_id" == "$canonical_id" ]]; then
  is_canonical=1
fi

# Canonical guard: refuse unless explicitly overridden.
if (( is_canonical && force_canonical == 0 )); then
  echo "ERROR: deployment $short_id ($deployment_id) is the canonical (aliased) deployment for project $project" >&2
  echo "       deleting it would take $project.pages.dev offline." >&2
  echo "       re-run with --force-canonical to override (maps to ?force=true)." >&2
  exit 1
fi

# Build the DELETE URL. force=true required to delete an aliased
# deployment — CF returns "this deployment is currently active" otherwise.
delete_path="/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/deployments/$deployment_id"
if (( is_canonical )); then
  delete_path="${delete_path}?force=true"
fi

render_summary_kv() {
  printf -- '- **project:** %s\n' "$project"
  printf -- '- **deployment:** %s (id=%s)\n' "$short_id" "$deployment_id"
  printf -- '- **environment:** %s\n' "$environment"
  printf -- '- **status:** %s\n' "$status"
  printf -- '- **created:** %s\n' "$created_on"
  printf -- '- **canonical:** %s\n' "$([[ $is_canonical -eq 1 ]] && echo 'yes (force=true)' || echo 'no')"
  return 0
}

if (( apply == 0 )); then
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n \
      --arg project "$project" \
      --arg deployment_id "$deployment_id" \
      --arg short_id "$short_id" \
      --arg delete_path "$delete_path" \
      --argjson is_canonical "$is_canonical" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, project: $project,
                 deployment_id: $deployment_id, short_id: $short_id,
                 canonical: ($is_canonical == 1),
                 would_delete: $delete_path}}'
    exit 0
  fi
  printf '**Dry-run — no changes applied**\n\n'
  render_summary_kv
  # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
  printf '\n**would DELETE** `%s`\n' "$delete_path"
  exit 0
fi

# Apply path.
response=$(cf_api "$delete_path" -X DELETE)

if [[ "$mode" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

printf '**Deployment deleted**\n\n'
render_summary_kv
