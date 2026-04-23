#!/usr/bin/env bash
# Create a Cloudflare Pages project — either GitHub-connected (default)
# or Direct Upload (with --direct-upload).
#
# Usage:
#   # GitHub-connected:
#   cf-pages-project-create.sh NAME GITHUB_OWNER REPO_NAME [flags]
#   # Direct Upload (no git source; deployments come from wrangler /
#   # the CF Pages deploy API — used by agex, citation-cli, afi):
#   cf-pages-project-create.sh NAME --direct-upload [flags]
#
# Default is DRY-RUN: verifies the account id, checks no project with
# NAME already exists, resolves --clone-from (if given), prints the
# JSON body that would be POSTed, and exits 0 WITHOUT mutating
# anything. Pass --apply to actually create the project.
#
# Prerequisites for --apply to succeed against the live API:
#   * CLOUDFLARE_API_TOKEN has Account · Cloudflare Pages · Edit
#   * (GitHub-connected only) The Cloudflare Pages GitHub App is
#     installed on GITHUB_OWNER and granted access to REPO_NAME. If
#     not, the POST fails with a CF error about the repo being
#     unreachable — that's a dashboard / GitHub-org-admin action this
#     script cannot automate. Direct Upload has no GitHub App dep.
#
# Flags:
#   --direct-upload             create a Direct Upload project (no
#                               `source` field in the POST body; the
#                               project is populated via later
#                               `wrangler pages deploy` / direct-upload
#                               API calls). Positional args collapse
#                               to NAME only; passing OWNER / REPO
#                               alongside --direct-upload is an error.
#   --clone-from=PROJECT        copy build_config, deployment_configs,
#                               and production_branch from an existing
#                               Pages project in the same account.
#                               Individual --build-command / --destination-dir /
#                               --root-dir / --production-branch /
#                               --compatibility-date / --build-image-version
#                               flags override the cloned values.
#                               --clone-from only copies build + deploy
#                               config — the source block is always
#                               derived fresh from OWNER / REPO (or
#                               omitted under --direct-upload).
#   --production-branch=BRANCH  git branch that produces production
#                               deployments (default: main, or cloned)
#   --build-command=CMD         shell command CF runs to build the site
#   --destination-dir=DIR       path (relative to root-dir) of the
#                               built output directory CF uploads
#   --root-dir=DIR              repo subdirectory to build from
#                               (default: "" = repo root)
#   --compatibility-date=DATE   YYYY-MM-DD, applied to both preview and
#                               production deployment configs
#   --build-image-version=N     1, 2, or 3 (default: 3 = latest)
#   --apply                     actually POST (without it, dry-run)
#   --json                      raw CF response envelope (or simulated
#                               body in dry-run)
#
# Exits 1 on: account id missing, project name already exists,
#   --clone-from target not found, any API error.
# Exits 2 on usage error.

set -euo pipefail
shopt -s inherit_errexit

mode=md
apply=0
direct_upload=0
clone_from=""
production_branch=""
build_command=""
destination_dir=""
root_dir=""
compatibility_date=""
build_image_version=""
# Track whether each overridable flag was explicitly passed: "" is a
# meaningful value (e.g. clear a cloned build_command) that's distinct
# from "unset" (fall back to clone or built-in default). Without these
# booleans, a plain `:-` expansion silently treats "" as "fall back".
root_dir_set=0
build_command_set=0
destination_dir_set=0
compatibility_date_set=0
production_branch_set=0
build_image_version_set=0
positional=()

for arg in "$@"; do
  case "$arg" in
    --json)            mode=json ;;
    --apply)           apply=1 ;;
    --direct-upload)   direct_upload=1 ;;
    --clone-from=*)           clone_from="${arg#*=}" ;;
    --production-branch=*)    production_branch="${arg#*=}"; production_branch_set=1 ;;
    --build-command=*)        build_command="${arg#*=}"; build_command_set=1 ;;
    --destination-dir=*)      destination_dir="${arg#*=}"; destination_dir_set=1 ;;
    --root-dir=*)             root_dir="${arg#*=}"; root_dir_set=1 ;;
    --compatibility-date=*)   compatibility_date="${arg#*=}"; compatibility_date_set=1 ;;
    --build-image-version=*)  build_image_version="${arg#*=}"; build_image_version_set=1 ;;
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

if (( direct_upload )); then
  if (( ${#positional[@]} != 1 )); then
    echo "ERROR: --direct-upload takes exactly one positional arg (NAME), got ${#positional[@]}" >&2
    echo "usage: cf-pages-project-create.sh NAME --direct-upload [flags]" >&2
    exit 2
  fi
  name="${positional[0]}"
  owner=""
  repo=""
else
  if (( ${#positional[@]} != 3 )); then
    echo "ERROR: expected NAME, GITHUB_OWNER, and REPO_NAME positional args, got ${#positional[@]}" >&2
    echo "usage: cf-pages-project-create.sh NAME GITHUB_OWNER REPO_NAME [flags]" >&2
    echo "   or: cf-pages-project-create.sh NAME --direct-upload [flags]" >&2
    exit 2
  fi
  name="${positional[0]}"
  owner="${positional[1]}"
  repo="${positional[2]}"
fi

# CF Pages project names: 1-58 chars, [a-z0-9-], cannot start/end with
# hyphen. Enforce locally so errors come from us, not a cryptic CF 400.
if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]{0,56}[a-z0-9])?$ ]]; then
  echo "ERROR: invalid project name: $name" >&2
  echo "       must be 1-58 chars, lowercase a-z 0-9 and hyphens, no leading/trailing hyphen" >&2
  exit 2
fi

# GitHub owner / repo naming: alnum, dash, underscore, dot. Skipped
# under --direct-upload where there's no source repo to validate.
if (( direct_upload == 0 )); then
  gh_re='^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'
  for v in "$owner" "$repo"; do
    if [[ ! "$v" =~ $gh_re ]]; then
      echo "ERROR: invalid GitHub identifier: $v" >&2
      exit 2
    fi
  done
fi

if [[ -n "$production_branch" ]]; then
  branch_re='^[A-Za-z0-9._/-]{1,255}$'
  if [[ ! "$production_branch" =~ $branch_re ]]; then
    echo "ERROR: invalid --production-branch: $production_branch" >&2
    exit 2
  fi
fi

if [[ -n "$compatibility_date" ]]; then
  if [[ ! "$compatibility_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "ERROR: --compatibility-date must be YYYY-MM-DD, got: $compatibility_date" >&2
    exit 2
  fi
fi

if [[ -n "$build_image_version" ]]; then
  if [[ ! "$build_image_version" =~ ^[0-9]+$ ]] || (( 10#$build_image_version < 1 || 10#$build_image_version > 3 )); then
    echo "ERROR: --build-image-version must be 1, 2, or 3, got: $build_image_version" >&2
    exit 2
  fi
  build_image_version=$((10#$build_image_version))
fi

# shellcheck source=../../cloudflare/scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cf_require_account_id

# CloudFlare Pages list endpoints cap per_page at 10 — requests with
# per_page >= 11 return code 8000024 "Invalid list options provided".
# The shared helper defaults to 50, so override here. Respect a
# user-supplied CF_PAGE_SIZE (the bats suite uses that to test drift).
export CF_PAGE_SIZE="${CF_PAGE_SIZE:-10}"

# Pre-flight: make sure NAME isn't already taken in this account.
# List every Pages project via the paginated endpoint, then filter by
# name with jq. Any API/listing error propagates via cf_api_paginated's
# `exit 1`. The same list also serves --clone-from's existence check
# below, so we pay one round-trip for both.
projects_json=$(cf_api_paginated "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects")
# shellcheck disable=SC2016  # single-quoted jq filter
existing_id=$(printf '%s' "$projects_json" | jq -r --arg n "$name" \
  '[.result[] | select(.name == $n) | .id] | .[0] // ""')
if [[ -n "$existing_id" ]]; then
  echo "ERROR: Pages project '$name' already exists in this account (id=$existing_id)" >&2
  echo "       pick a different NAME or delete the existing project first" >&2
  exit 1
fi

# --clone-from: fetch template project so we can inherit its
# build_config / deployment_configs / production_branch.
cloned_build_command=""
cloned_destination_dir=""
cloned_root_dir=""
cloned_production_branch=""
cloned_compat_date=""
cloned_build_image=""
if [[ -n "$clone_from" ]]; then
  # Existence check against the list we already fetched — no second
  # round-trip. Use `any(...)` because we don't need the id, only
  # confirmation that the name resolves.
  # shellcheck disable=SC2016  # single-quoted jq filter
  if ! printf '%s' "$projects_json" | jq -e --arg n "$clone_from" \
      'any(.result[]; .name == $n)' >/dev/null; then
    echo "ERROR: --clone-from project '$clone_from' not found in this account" >&2
    exit 1
  fi
  # URL-encode --clone-from before interpolating into the path. Project
  # names are locally validated as lowercase alnum + hyphen for *new*
  # projects, but existing projects may have been created via the
  # dashboard under older, looser rules — be defensive on the lookup.
  # shellcheck disable=SC2016  # single-quoted jq filter
  clone_from_encoded=$(printf '%s' "$clone_from" | jq -sRr @uri)
  clone_detail=$(cf_api "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$clone_from_encoded")
  cloned_build_command=$(printf '%s' "$clone_detail" | jq -r '.result.build_config.build_command // ""')
  cloned_destination_dir=$(printf '%s' "$clone_detail" | jq -r '.result.build_config.destination_dir // ""')
  cloned_root_dir=$(printf '%s' "$clone_detail" | jq -r '.result.build_config.root_dir // ""')
  cloned_production_branch=$(printf '%s' "$clone_detail" | jq -r '.result.production_branch // ""')
  cloned_compat_date=$(printf '%s' "$clone_detail" | jq -r '.result.deployment_configs.production.compatibility_date // ""')
  cloned_build_image=$(printf '%s' "$clone_detail" | jq -r '.result.deployment_configs.production.build_image_major_version // ""')
fi

# Explicit flags win over clone; clone wins over built-in defaults.
# `*_set` booleans distinguish "flag passed with empty value" (which
# must override the clone) from "flag not passed" (fall back to
# clone / default). A plain `:-` would conflate the two.
if (( production_branch_set ));    then effective_production_branch="$production_branch";
else effective_production_branch="${cloned_production_branch:-main}"; fi
if (( build_command_set ));        then effective_build_command="$build_command";
else effective_build_command="$cloned_build_command"; fi
if (( destination_dir_set ));      then effective_destination_dir="$destination_dir";
else effective_destination_dir="$cloned_destination_dir"; fi
if (( root_dir_set ));             then effective_root_dir="$root_dir";
else effective_root_dir="$cloned_root_dir"; fi
if (( compatibility_date_set ));   then effective_compat_date="$compatibility_date";
else effective_compat_date="$cloned_compat_date"; fi
if (( build_image_version_set ));  then effective_build_image="$build_image_version";
else effective_build_image="${cloned_build_image:-3}"; fi

# Build the POST body. Unset fields are emitted as empty-string /
# default values — CF treats an unset build_command as "no build
# step" (direct upload style), which is a valid state.
# shellcheck disable=SC2016  # single-quoted jq filter
body=$(jq -n \
  --arg name           "$name" \
  --arg owner          "$owner" \
  --arg repo           "$repo" \
  --arg prod_branch    "$effective_production_branch" \
  --arg build_command  "$effective_build_command" \
  --arg dest_dir       "$effective_destination_dir" \
  --arg root_dir       "$effective_root_dir" \
  --arg compat_date    "$effective_compat_date" \
  --argjson build_image "$effective_build_image" \
  --argjson direct_upload "$direct_upload" \
  '({
    name: $name,
    production_branch: $prod_branch,
    build_config: {
      build_command: $build_command,
      destination_dir: $dest_dir,
      root_dir: $root_dir
    },
    deployment_configs: {
      preview: ({
        fail_open: true,
        always_use_latest_compatibility_date: false,
        build_image_major_version: $build_image,
        usage_model: "standard"
      } + (if $compat_date == "" then {} else {compatibility_date: $compat_date} end)),
      production: ({
        fail_open: true,
        always_use_latest_compatibility_date: false,
        build_image_major_version: $build_image,
        usage_model: "standard"
      } + (if $compat_date == "" then {} else {compatibility_date: $compat_date} end))
    }
  })
  + (if $direct_upload == 1 then {} else {
    source: {
      type: "github",
      config: {
        owner: $owner,
        repo_name: $repo,
        production_branch: $prod_branch,
        pr_comments_enabled: true,
        deployments_enabled: true,
        production_deployments_enabled: true,
        preview_deployment_setting: "all",
        preview_branch_includes: ["*"],
        preview_branch_excludes: [],
        path_includes: ["*"],
        path_excludes: []
      }
    }} end)')

_render_summary_md() {
  local banner="$1"
  printf '%s\n\n' "$banner"
  printf -- '- **name:** %s\n' "$name"
  printf -- '- **account:** %s\n' "$CLOUDFLARE_ACCOUNT_ID"
  if (( direct_upload )); then
    printf -- '- **source:** direct_upload\n'
  else
    printf -- '- **source:** github:%s/%s\n' "$owner" "$repo"
  fi
  printf -- '- **production_branch:** %s\n' "$effective_production_branch"
  printf -- '- **build_command:** %s\n' "${effective_build_command:-—}"
  printf -- '- **destination_dir:** %s\n' "${effective_destination_dir:-—}"
  printf -- '- **root_dir:** %s\n' "${effective_root_dir:-<repo root>}"
  printf -- '- **compatibility_date:** %s\n' "${effective_compat_date:-<cf default>}"
  printf -- '- **build_image_major_version:** %s\n' "$effective_build_image"
  if [[ -n "$clone_from" ]]; then
    printf -- '- **cloned_from:** %s\n' "$clone_from"
  fi
}

if (( apply == 0 )); then
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n --argjson body "$body" --arg account "$CLOUDFLARE_ACCOUNT_ID" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, account_id: $account, would_post: $body}}'
    exit 0
  fi
  _render_summary_md "**Dry-run — no changes applied**"
  # shellcheck disable=SC2016  # single-quoted literal backticks wrap markdown inline code
  printf '\n**would POST** `/accounts/%s/pages/projects`:\n\n' "$CLOUDFLARE_ACCOUNT_ID"
  printf '```json\n'
  printf '%s\n' "$body"
  printf '```\n'
  exit 0
fi

response=$(cf_api "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects" -X POST --data-binary "$body")

if [[ "$mode" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

new_id=$(printf '%s' "$response" | jq -r '.result.id // "—"')
subdomain=$(printf '%s' "$response" | jq -r '.result.subdomain // "—"')
_render_summary_md "**Pages project created**"
printf -- '- **project_id:** %s\n' "$new_id"
printf -- '- **subdomain:** https://%s\n' "$subdomain"
