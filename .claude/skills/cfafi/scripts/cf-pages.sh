#!/usr/bin/env bash
# List CloudFlare Pages projects (or deployments for a specific project).
#
# Usage:
#   cf-pages.sh [--json]             # list all Pages projects in the account
#   cf-pages.sh PROJECT [--json]     # list deployments for that project
#
# Needed for Phase 2 (agentirc.dev Pages cleanup) — use the project
# listing to identify the orphaned project, then pass its name here to
# inventory its deployments before removal.
#
# Calls /accounts/<CLOUDFLARE_ACCOUNT_ID>/pages/projects or
#       /accounts/<CLOUDFLARE_ACCOUNT_ID>/pages/projects/<PROJECT>/deployments.

set -euo pipefail

mode=md
project=""
for arg in "$@"; do
  case "$arg" in
    --json) mode=json ;;
    -h|--help)
      sed -n 's/^# \{0,1\}//p' "$0" | head -13
      exit 0
      ;;
    -*)
      echo "ERROR: unknown flag: $arg" >&2
      exit 2
      ;;
    *)
      if [[ -z "$project" ]]; then
        project="$arg"
      else
        echo "ERROR: unexpected extra argument: $arg" >&2
        exit 2
      fi
      ;;
  esac
done

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cf_require_account_id

# CloudFlare Pages list endpoints cap per_page at 10 — requests with
# per_page >= 11 return code 8000024 "Invalid list options provided".
# Every other list endpoint we call accepts the library default of 50,
# so this override is Pages-local. Respect a user-supplied CF_PAGE_SIZE.
export CF_PAGE_SIZE="${CF_PAGE_SIZE:-10}"

if [[ -z "$project" ]]; then
  response=$(cf_api_paginated "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects")

  if [[ "$mode" == "md" ]]; then
    count=$(printf '%s' "$response" | jq -r '.result | length')
    printf '## Pages projects (%s)\n\n' "$count"
  fi

  # shellcheck disable=SC2016  # single-quoted jq filter
  cf_output "$response" "$mode" \
    '.result[] | [.name, (.production_branch // "—"), (.subdomain // "—"), (.latest_deployment.created_on // "—")] | @tsv' \
    "$(printf 'NAME\tBRANCH\tSUBDOMAIN\tLATEST')"
else
  # URL-encode the project argument so an unusual character (space,
  # `/`, `?`, `#`) cannot alter the request path. CloudFlare Pages
  # project names are normally safe, but the encoding is cheap
  # insurance.
  project_encoded=$(jq -rn --arg v "$project" '$v|@uri')
  response=$(cf_api_paginated "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/deployments")

  if [[ "$mode" == "md" ]]; then
    count=$(printf '%s' "$response" | jq -r '.result | length')
    printf '## Deployments for %s (%s)\n\n' "$project" "$count"
  fi

  # shellcheck disable=SC2016  # single-quoted jq filter
  cf_output "$response" "$mode" \
    '.result[] | [(.short_id // (.id[0:8])), (.environment // "—"), (.deployment_trigger.metadata.branch // "—"), (.latest_stage.status // "—"), .created_on] | @tsv' \
    "$(printf 'SHORT_ID\tENV\tBRANCH\tSTATUS\tCREATED')"
fi
