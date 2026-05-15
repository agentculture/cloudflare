#!/usr/bin/env bash
# Add a custom domain to a CloudFlare Pages project.
#
# Usage:
#   cf-pages-domain-add.sh PROJECT DOMAIN [--apply] [--json]
#
# Default is DRY-RUN: lists the project's custom domains (which also
# confirms the project exists), checks DOMAIN is not already attached,
# prints the JSON body it would POST, and exits 0 WITHOUT mutating
# anything. Pass --apply to actually POST.
#
# Prerequisites for --apply to succeed against the live API:
#   * CLOUDFLARE_API_TOKEN has Account · Cloudflare Pages · Edit
#
# Flags:
#   --apply   actually POST (without it, this is a dry-run)
#   --json    raw CloudFlare response envelope (or simulated body in dry-run)
#
# Exits 1 on: account id missing, project not found, domain already
#   attached, API error. Exits 2 on usage error.

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

if (( ${#positional[@]} != 2 )); then
  echo "ERROR: expected PROJECT and DOMAIN positional args, got ${#positional[@]}" >&2
  echo "usage: cf-pages-domain-add.sh PROJECT DOMAIN [--apply] [--json]" >&2
  exit 2
fi
project="${positional[0]}"
domain="${positional[1]}"

# Project name is CF-restricted (lowercase alnum, dashes; dashboard-era
# projects also allow dots / underscores). Domain is a hostname. Reject
# anything that could escape the URL path before we interpolate.
if [[ ! "$project" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo "ERROR: invalid project name: $project" >&2
  exit 2
fi
if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
  echo "ERROR: invalid domain: $domain" >&2
  exit 2
fi

# shellcheck source=../../cloudflare/scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cf_require_account_id

project_encoded=$(jq -rn --arg v "$project" '$v|@uri')

# Pre-flight: list the project's custom domains. This GET doubles as
# the project-existence check — a missing project returns CF's
# structured "Project not found" error, which cf_api surfaces (don't
# silence its stderr) before exiting 1. Pages list endpoints cap
# per_page at 10 (CF error 8000024 on >=11); scope CF_PAGE_SIZE to
# this call so other cf_api_paginated callers are unaffected.
if ! domains_json=$(CF_PAGE_SIZE=10 cf_api_paginated "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/domains"); then
  echo "HINT: could not resolve Pages project '$project'. Check the project name with cf-pages.sh." >&2
  exit 1
fi

# Idempotency: refuse if DOMAIN is already attached to this project.
# shellcheck disable=SC2016  # single-quoted jq filter
if printf '%s' "$domains_json" | jq -e --arg d "$domain" 'any(.result[]; .name == $d)' >/dev/null; then
  echo "ERROR: domain '$domain' is already attached to Pages project '$project'" >&2
  exit 1
fi

post_path="/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/domains"
# shellcheck disable=SC2016  # single-quoted jq filter
body=$(jq -n --arg name "$domain" '{name: $name}')

render_summary_kv() {
  printf -- '- **project:** %s\n' "$project"
  printf -- '- **domain:** %s\n' "$domain"
  printf -- '- **account:** %s\n' "$CLOUDFLARE_ACCOUNT_ID"
  return 0
}

if (( apply == 0 )); then
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n --argjson body "$body" --arg account "$CLOUDFLARE_ACCOUNT_ID" \
      --arg project "$project" --arg domain "$domain" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, account_id: $account, project: $project,
                 domain: $domain, would_post: $body}}'
    exit 0
  fi
  printf '**Dry-run — no changes applied**\n\n'
  render_summary_kv
  # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
  printf '\n**would POST** `%s`:\n\n' "$post_path"
  printf '```json\n'
  printf '%s\n' "$body"
  printf '```\n'
  exit 0
fi

response=$(cf_api "$post_path" -X POST --data-binary "$body")

if [[ "$mode" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

status=$(printf '%s' "$response" | jq -r '.result.status // "—"')
printf '**Custom domain added**\n\n'
render_summary_kv
printf -- '- **status:** %s\n' "$status"
