#!/usr/bin/env bash
# Shared helpers for cloudflare skill scripts.
# Source this file from every cf-*.sh; do not execute directly.
#
# Exposes:
#   cf_api PATH [CURL_OPTS...]        — GET CloudFlare API, error on success:false
#   cf_output JSON MODE FILTER [HDR]  — render raw JSON or tab-aligned table
#
# Env:
#   CLOUDFLARE_API_TOKEN  (required) — set via .env or exported
#   CLOUDFLARE_ACCOUNT_ID (optional) — required by Workers/Pages scripts only
#   CF_API_BASE           (optional) — override API base (tests)
#   CF_SKIP_ENV           (optional) — set to 1 to bypass .env loading (tests)
#   CF_ENV_FILE           (optional) — path to .env, defaults to repo root

set -euo pipefail

_CF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_REPO_ROOT="$(cd "$_CF_LIB_DIR/../../../.." && pwd)"

cf_load_env() {
  [[ "${CF_SKIP_ENV:-0}" == "1" ]] && return 0
  local env_file="${CF_ENV_FILE:-$CF_REPO_ROOT/.env}"
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
}

cf_load_env

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN not set. Copy .env.example to .env and add your token." >&2
  exit 1
fi

CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

cf_api() {
  local path="$1"; shift
  local response
  response=$(curl -sS \
    -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    -H "Content-Type: application/json" \
    "$@" \
    "$CF_API_BASE$path")

  if ! printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "ERROR: CloudFlare API request failed: $path" >&2
    printf '%s' "$response" | jq '.errors // .' >&2 || printf '%s\n' "$response" >&2
    exit 1
  fi
  printf '%s\n' "$response"
}

cf_output() {
  # cf_output JSON MODE JQ_TSV_FILTER HEADER
  # MODE   : md | json
  # FILTER : jq expression producing tab-separated rows (@tsv)
  # HEADER : tab-separated column names
  local json="$1" mode="$2" filter="$3" header="${4:-}"
  case "$mode" in
    json)
      printf '%s\n' "$json"
      ;;
    md)
      local -a cols
      local ncols i c
      if [[ -n "$header" ]]; then
        IFS=$'\t' read -ra cols <<<"$header"
        ncols=${#cols[@]}
        printf '|'; for c in "${cols[@]}"; do printf ' %s |' "$c"; done; printf '\n'
        printf '|'; for ((i=0; i<ncols; i++)); do printf ' --- |'; done; printf '\n'
      fi
      printf '%s' "$json" | jq -r "$filter" | sed 's/\t/ | /g; s/^/| /; s/$/ |/'
      ;;
    *)
      echo "ERROR: cf_output: unknown mode '$mode' (expected md|json)" >&2
      exit 1
      ;;
  esac
}

cf_output_kv() {
  # cf_output_kv JSON MODE JQ_FIELDS_FILTER
  # FILTER: jq expression producing tab-separated "key\tvalue" lines
  # md mode renders as "- **key:** value" list; json passes through.
  local json="$1" mode="$2" filter="$3"
  case "$mode" in
    json)
      printf '%s\n' "$json"
      ;;
    md)
      printf '%s' "$json" | jq -r "$filter" | awk -F'\t' '{printf "- **%s:** %s\n", $1, $2}'
      ;;
    *)
      echo "ERROR: cf_output_kv: unknown mode '$mode' (expected md|json)" >&2
      exit 1
      ;;
  esac
}

cf_require_account_id() {
  if [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    echo "ERROR: CLOUDFLARE_ACCOUNT_ID not set. Required for account-scoped endpoints (Workers, Pages)." >&2
    exit 1
  fi
}
