#!/usr/bin/env bash
# Create (upload) a Cloudflare Worker script.
#
# Usage:
#   cf-worker-create.sh NAME --from-file=PATH [flags]
#
# Default is DRY-RUN: verifies the account id, checks that no Worker
# with NAME already exists, prints the metadata JSON that would be sent
# and a preview of the script source, then exits 0 WITHOUT mutating
# anything. Pass --apply to actually upload.
#
# Prerequisites for --apply to succeed against the live API:
#   * CLOUDFLARE_API_TOKEN has Account · Workers Scripts · Edit
#
# Flags:
#   --from-file=PATH            local worker.js file to upload (required)
#   --module                    ES-module format (default). Sets
#                               metadata.main_module = "worker.js" and
#                               the worker part Content-Type to
#                               application/javascript+module.
#   --service-worker            legacy service-worker format. Sets
#                               metadata.body_part = "script" and the
#                               worker part Content-Type to
#                               application/javascript. Mutually
#                               exclusive with --module.
#   --compatibility-date=DATE   YYYY-MM-DD (default: today). Pins the
#                               Workers runtime behavior — upgrade by
#                               bumping this, never silently.
#   --no-workers-dev            do NOT enable the Worker's
#                               NAME.<account>.workers.dev subdomain.
#                               By default the subdomain is enabled
#                               after a successful upload, matching
#                               the live agex-proxy / citation-cli-proxy
#                               state. Pass this to opt out (e.g. for
#                               internal Workers that should only run
#                               on their Workers routes, never at a
#                               public .workers.dev URL).
#   --apply                     actually PUT (without it, dry-run)
#   --json                      raw CF response envelope (or simulated
#                               body in dry-run)
#
# Exits 1 on: account id missing, file not found, Worker already exists,
#   any API error.
# Exits 2 on usage error.

set -euo pipefail
shopt -s inherit_errexit

mode=md
apply=0
from_file=""
fmt=module
compat_date=""
workers_dev=1   # default: enable .workers.dev subdomain (matches agex-proxy)
# Track which fmt flag (if any) was explicitly passed, so we can
# reject the mutually-exclusive `--module --service-worker` case
# instead of silently letting the later flag win.
fmt_module_set=0
fmt_service_worker_set=0
positional=()

for arg in "$@"; do
  case "$arg" in
    --json)                   mode=json ;;
    --apply)                  apply=1 ;;
    --from-file=*)            from_file="${arg#*=}" ;;
    --module)                 fmt=module;         fmt_module_set=1 ;;
    --service-worker)         fmt=service-worker; fmt_service_worker_set=1 ;;
    --compatibility-date=*)   compat_date="${arg#*=}" ;;
    --no-workers-dev)         workers_dev=0 ;;
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

if (( ${#positional[@]} != 1 )); then
  echo "ERROR: expected NAME positional arg, got ${#positional[@]}" >&2
  echo "usage: cf-worker-create.sh NAME --from-file=PATH [flags]" >&2
  exit 2
fi
name="${positional[0]}"

if (( fmt_module_set && fmt_service_worker_set )); then
  echo "ERROR: --module and --service-worker are mutually exclusive" >&2
  exit 2
fi

# Worker script names: 1-63 chars, [a-z0-9_-], cannot start/end with
# hyphen or underscore. Enforce locally so errors come from us, not a
# cryptic CF 400.
if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9_-]{0,61}[a-z0-9])?$ ]]; then
  echo "ERROR: invalid worker name: $name" >&2
  echo "       must be 1-63 chars, lowercase a-z 0-9 _ -, no leading/trailing _ or -" >&2
  exit 2
fi

if [[ -z "$from_file" ]]; then
  echo "ERROR: --from-file=PATH is required" >&2
  exit 2
fi
if [[ ! -f "$from_file" ]]; then
  echo "ERROR: --from-file not found or not a regular file: $from_file" >&2
  exit 1
fi

if [[ -z "$compat_date" ]]; then
  compat_date=$(date -u +%Y-%m-%d)
fi
if [[ ! "$compat_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "ERROR: --compatibility-date must be YYYY-MM-DD, got: $compat_date" >&2
  exit 2
fi

# shellcheck source=../../cloudflare/scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cf_require_account_id

# Build the metadata JSON part based on format. `part_name` is the
# multipart form-field name AND the filename= attribute — CF matches
# the script part against metadata.main_module / metadata.body_part
# via that string, so they have to agree. Module format points at
# worker.js; service-worker format points at `script`.
case "$fmt" in
  module)
    # shellcheck disable=SC2016  # single-quoted jq filter
    metadata=$(jq -n --arg date "$compat_date" \
      '{main_module: "worker.js", compatibility_date: $date}')
    part_ct="application/javascript+module"
    part_name="worker.js"
    ;;
  service-worker)
    # shellcheck disable=SC2016  # single-quoted jq filter
    metadata=$(jq -n --arg date "$compat_date" \
      '{body_part: "script", compatibility_date: $date}')
    part_ct="application/javascript"
    part_name="script"
    ;;
  *)
    echo "ERROR: internal: unknown format: $fmt" >&2
    exit 2
    ;;
esac

# Pre-flight: fail loudly if a Worker with this NAME is already
# deployed. Idempotency is explicit — no silent overwrites. We query
# the list endpoint (`/accounts/{id}/workers/scripts`) and filter by
# name client-side. This keeps the pre-flight URL distinct from the
# per-script upload URL (`/accounts/.../workers/scripts/{name}`),
# which is important for the bats curl stub — it can't discriminate
# GET vs PUT on the same URL.
scripts_json=$(cf_api_paginated "/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts")
# shellcheck disable=SC2016  # single-quoted jq filter
if printf '%s' "$scripts_json" | jq -e --arg n "$name" \
    'any(.result[]; .id == $n)' >/dev/null; then
  echo "ERROR: Worker '$name' already exists in account $CLOUDFLARE_ACCOUNT_ID" >&2
  echo "       refusing to overwrite; delete it first or use a future cf-worker-update script" >&2
  exit 1
fi

_render_summary_md() {
  local banner="$1"
  printf '%s\n\n' "$banner"
  printf -- '- **name:** %s\n' "$name"
  printf -- '- **account:** %s\n' "$CLOUDFLARE_ACCOUNT_ID"
  printf -- '- **format:** %s\n' "$fmt"
  printf -- '- **compatibility_date:** %s\n' "$compat_date"
  printf -- '- **from_file:** %s\n' "$from_file"
  printf -- '- **source_bytes:** %s\n' "$(wc -c < "$from_file" | tr -d ' ')"
  printf -- '- **workers_dev_subdomain:** %s\n' "$([[ $workers_dev -eq 1 ]] && echo enabled || echo disabled)"
  return 0
}

if (( apply == 0 )); then
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n --argjson metadata "$metadata" \
          --arg account "$CLOUDFLARE_ACCOUNT_ID" \
          --arg name "$name" \
          --arg from_file "$from_file" \
          --arg fmt "$fmt" \
          --argjson workers_dev "$workers_dev" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, account_id: $account, name: $name,
                 from_file: $from_file, format: $fmt,
                 workers_dev_subdomain: (if $workers_dev == 1 then "enabled" else "disabled" end),
                 would_put: {metadata: $metadata}}}'
    exit 0
  fi
  _render_summary_md "**Dry-run — no changes applied**"
  # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
  printf '\n**would PUT** `/accounts/%s/workers/scripts/%s`\n\n' "$CLOUDFLARE_ACCOUNT_ID" "$name"
  # shellcheck disable=SC2016  # literal backticks fence a markdown code block
  printf 'metadata:\n\n```json\n%s\n```\n\n' "$metadata"
  # shellcheck disable=SC2016  # literal backticks open a markdown code fence
  printf '%s preview (first 20 lines):\n\n```javascript\n' "$part_name"
  head -20 "$from_file"
  printf '```\n'
  # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
  printf '\n**would POST** `/accounts/%s/workers/scripts/%s/subdomain` with `{"enabled": %s, "previews_enabled": false}`\n' \
    "$CLOUDFLARE_ACCOUNT_ID" "$name" "$([[ $workers_dev -eq 1 ]] && echo true || echo false)"
  exit 0
fi

# Live upload. Multipart form-data with two parts:
#   * metadata (application/json) — the JSON we built above
#   * worker.js ($part_ct) — the script source
# curl's -F handles the multipart assembly and sets the
# Content-Type + boundary automatically. We write metadata to a
# temp file so curl's @-reference reads it byte-for-byte without
# shell re-quoting surprises.
#
# IMPORTANT: `-F "name=@path"` makes curl emit
# `Content-Disposition: form-data; name="$part_name"; filename="afi-proxy.js"`
# — the filename comes from the source path's basename. CF's
# resolver then complains with code 10021 "No such module: worker.js"
# (module mode) or a similar miss for service-worker mode, because
# metadata.main_module / metadata.body_part points at "$part_name"
# but the only part CF sees is `filename="afi-proxy.js"`. Fix:
# `;filename=$part_name`, which overrides the filename regardless of
# the source path. The part's form-field NAME (left of the =) must
# also match $part_name, since some CF paths key off that too.
# Removing either breaks every apply against the live API.
meta_tmp=$(mktemp "${TMPDIR:-/tmp}/cf-worker-metadata.XXXXXX.json")
trap 'rm -f "$meta_tmp"' EXIT
printf '%s' "$metadata" > "$meta_tmp"

url_upload="$CF_API_BASE/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$name"
# Use curl directly — cf_api fixes Content-Type to application/json,
# which would conflict with the multipart boundary curl computes.
response=$(curl -sS -X PUT \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -F "metadata=@$meta_tmp;type=application/json;filename=metadata.json" \
  -F "$part_name=@$from_file;type=$part_ct;filename=$part_name" \
  "$url_upload")

if ! printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
  echo "ERROR: CloudFlare API request failed: PUT /accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$name" >&2
  printf '%s' "$response" | jq '.errors // .' >&2 || printf '%s\n' "$response" >&2
  exit 1
fi

# Second write: set the `.workers.dev` subdomain state. Required
# because CF's PUT /workers/scripts/{name} endpoint defaults the
# subdomain to DISABLED, while the dashboard / wrangler default it
# to ENABLED. Without this the new Worker isn't reachable at its
# NAME.<account>.workers.dev URL, which is a silent divergence from
# agex-proxy / citation-cli-proxy (both `enabled: true`). Same
# Account · Workers Scripts · Edit scope — no extra permission.
#
# NOTE: CF's subdomain endpoint is POST, not PUT. Sending PUT here
# returns code 10405 "Method not allowed for this authentication
# scheme" (misleading — the auth is fine, the method is wrong).
# Keep -X POST.
subdomain_body=$(jq -n --argjson enabled "$workers_dev" \
  '{enabled: ($enabled == 1), previews_enabled: false}')
subdomain_response=$(cf_api \
  "/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$name/subdomain" \
  -X POST --data-binary "$subdomain_body")

if [[ "$mode" == "json" ]]; then
  # Merge the upload response and the subdomain response into one
  # envelope so downstream jq pipelines see both outcomes.
  jq -n --argjson upload "$response" --argjson subdomain "$subdomain_response" \
    '{success: true, errors: [], messages: [],
      result: {upload: $upload.result, subdomain: $subdomain.result}}'
  exit 0
fi

_render_summary_md "**Worker uploaded**"
etag=$(printf '%s' "$response" | jq -r '.result.etag // "—"')
modified=$(printf '%s' "$response" | jq -r '.result.modified_on // "—"')
printf -- '- **etag:** %s\n' "$etag"
printf -- '- **modified_on:** %s\n' "$modified"
printf -- '- **workers_dev_enabled:** %s\n' \
  "$(printf '%s' "$subdomain_response" | jq -r '.result.enabled')"
