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
positional=()

for arg in "$@"; do
  case "$arg" in
    --json)                   mode=json ;;
    --apply)                  apply=1 ;;
    --from-file=*)            from_file="${arg#*=}" ;;
    --module)                 fmt=module ;;
    --service-worker)         fmt=service-worker ;;
    --compatibility-date=*)   compat_date="${arg#*=}" ;;
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

# Build the metadata JSON part based on format.
case "$fmt" in
  module)
    # shellcheck disable=SC2016  # single-quoted jq filter
    metadata=$(jq -n --arg date "$compat_date" \
      '{main_module: "worker.js", compatibility_date: $date}')
    part_ct="application/javascript+module"
    ;;
  service-worker)
    # shellcheck disable=SC2016  # single-quoted jq filter
    metadata=$(jq -n --arg date "$compat_date" \
      '{body_part: "script", compatibility_date: $date}')
    part_ct="application/javascript"
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
}

if (( apply == 0 )); then
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n --argjson metadata "$metadata" \
          --arg account "$CLOUDFLARE_ACCOUNT_ID" \
          --arg name "$name" \
          --arg from_file "$from_file" \
          --arg fmt "$fmt" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, account_id: $account, name: $name,
                 from_file: $from_file, format: $fmt,
                 would_put: {metadata: $metadata}}}'
    exit 0
  fi
  _render_summary_md "**Dry-run — no changes applied**"
  # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
  printf '\n**would PUT** `/accounts/%s/workers/scripts/%s`\n\n' "$CLOUDFLARE_ACCOUNT_ID" "$name"
  # shellcheck disable=SC2016  # literal backticks fence a markdown code block
  printf 'metadata:\n\n```json\n%s\n```\n\n' "$metadata"
  # shellcheck disable=SC2016  # literal backticks open a markdown code fence
  printf 'worker.js preview (first 20 lines):\n\n```javascript\n'
  head -20 "$from_file"
  printf '```\n'
  exit 0
fi

# Live upload. Multipart form-data with two parts:
#   * metadata (application/json) — the JSON we built above
#   * worker.js ($part_ct) — the script source
# curl's -F handles the multipart assembly and sets the
# Content-Type + boundary automatically. We write metadata to a
# temp file so curl's @-reference reads it byte-for-byte without
# shell re-quoting surprises.
meta_tmp=$(mktemp "${TMPDIR:-/tmp}/cf-worker-metadata.XXXXXX.json")
trap 'rm -f "$meta_tmp"' EXIT
printf '%s' "$metadata" > "$meta_tmp"

url_upload="$CF_API_BASE/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$name"
# Use curl directly — cf_api fixes Content-Type to application/json,
# which would conflict with the multipart boundary curl computes.
response=$(curl -sS -X PUT \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -F "metadata=@$meta_tmp;type=application/json" \
  -F "worker.js=@$from_file;type=$part_ct" \
  "$url_upload")

if ! printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
  echo "ERROR: CloudFlare API request failed: PUT /accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$name" >&2
  printf '%s' "$response" | jq '.errors // .' >&2 || printf '%s\n' "$response" >&2
  exit 1
fi

if [[ "$mode" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

_render_summary_md "**Worker uploaded**"
etag=$(printf '%s' "$response" | jq -r '.result.etag // "—"')
modified=$(printf '%s' "$response" | jq -r '.result.modified_on // "—"')
printf -- '- **etag:** %s\n' "$etag"
printf -- '- **modified_on:** %s\n' "$modified"
