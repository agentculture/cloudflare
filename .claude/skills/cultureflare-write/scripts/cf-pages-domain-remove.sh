#!/usr/bin/env bash
# Remove a custom domain from a CloudFlare Pages project.
#
# Usage:
#   cf-pages-domain-remove.sh PROJECT DOMAIN [--apply] [--json]
#
# Default is DRY-RUN: lists the project's custom domains (which also
# confirms the project exists), confirms DOMAIN is currently attached,
# prints the DELETE URL it would hit, and exits 0 WITHOUT mutating
# anything. Pass --apply to actually DELETE.
#
# This is the step that can take a production domain dark — detaching a
# custom domain stops that domain serving from this project. The
# dry-run output names the project and domain explicitly so the blast
# radius is reviewable before --apply.
#
# Prerequisites for --apply to succeed against the live API:
#   * CLOUDFLARE_API_TOKEN has Account · Cloudflare Pages · Edit
#
# Flags:
#   --apply   actually DELETE (without it, this is a dry-run)
#   --json    raw CloudFlare response envelope (or simulated body in dry-run)
#
# Exits 1 on: account id missing, project not found, domain not
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
  echo "usage: cf-pages-domain-remove.sh PROJECT DOMAIN [--apply] [--json]" >&2
  exit 2
fi
project="${positional[0]}"
domain="${positional[1]}"

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
domain_encoded=$(jq -rn --arg v "$domain" '$v|@uri')

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

# Refuse if DOMAIN is NOT attached — there is nothing to remove, and a
# silent no-op would hide a typo'd domain or project name.
# shellcheck disable=SC2016  # single-quoted jq filter
if ! printf '%s' "$domains_json" | jq -e --arg d "$domain" 'any(.result[]; .name == $d)' >/dev/null; then
  echo "ERROR: domain '$domain' is not attached to Pages project '$project' — nothing to remove" >&2
  exit 1
fi

delete_path="/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/domains/$domain_encoded"

render_summary_kv() {
  printf -- '- **project:** %s\n' "$project"
  printf -- '- **domain:** %s\n' "$domain"
  printf -- '- **account:** %s\n' "$CLOUDFLARE_ACCOUNT_ID"
  return 0
}

if (( apply == 0 )); then
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n --arg account "$CLOUDFLARE_ACCOUNT_ID" --arg project "$project" \
      --arg domain "$domain" --arg delete_path "$delete_path" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, account_id: $account, project: $project,
                 domain: $domain, would_delete: $delete_path}}'
    exit 0
  fi
  printf '**Dry-run — no changes applied**\n\n'
  # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
  printf '**This detaches a custom domain — `%s` will stop serving from project `%s`.**\n\n' "$domain" "$project"
  render_summary_kv
  # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
  printf '\n**would DELETE** `%s`\n' "$delete_path"
  exit 0
fi

response=$(cf_api "$delete_path" -X DELETE)

if [[ "$mode" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

printf '**Custom domain removed**\n\n'
render_summary_kv
