#!/usr/bin/env bash
# Shared helpers for cloudflare skill scripts.
# Source this file from every cf-*.sh; do not execute directly.
#
# Exposes:
#   cf_api PATH [CURL_OPTS...]        — GET CloudFlare API, error on transport/success:false
#   cf_output JSON MODE FILTER [HDR]  — render markdown table or raw JSON
#   cf_output_kv JSON MODE FILTER     — render markdown key-value or raw JSON
#   cf_require_account_id             — assert CLOUDFLARE_ACCOUNT_ID is set
#
# Env:
#   CLOUDFLARE_API_TOKEN  (required) — set via .env or exported
#   CLOUDFLARE_ACCOUNT_ID (optional) — required by Workers/Pages endpoints
#   CF_API_BASE           (optional) — override API base (tests)
#   CF_SKIP_ENV           (optional) — set to 1 to bypass .env loading (tests)
#   CF_ENV_FILE           (optional) — path to .env, defaults to repo root

set -euo pipefail

_CF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CF_REPO_ROOT="$(cd "$_CF_LIB_DIR/../../../.." && pwd)"

# Parse a .env file as KEY=VALUE assignments. Does NOT `source` the file —
# that would execute arbitrary shell code on script startup. Supports:
#   KEY=value              # bare value
#   KEY="value"            # double-quoted (quotes stripped)
#   KEY='value'            # single-quoted (quotes stripped)
#   export KEY=value       # leading "export " tolerated
#   # comment              # blank lines and '#'-prefixed lines skipped
# KEY must match [A-Za-z_][A-Za-z0-9_]*. Malformed lines warn to stderr
# and are skipped.
cf_load_env() {
  [[ "${CF_SKIP_ENV:-0}" == "1" ]] && return 0
  local env_file="${CF_ENV_FILE:-$CF_REPO_ROOT/.env}"
  [[ -f "$env_file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    line="${line#export }"
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      export "$key=$value"
    else
      echo "WARNING: $env_file: ignoring malformed line: $line" >&2
    fi
  done < "$env_file"
  return 0
}

cf_load_env

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN not set. Copy .env.example to .env and add your token." >&2
  exit 1
fi

CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

# cf_api PATH [CURL_OPTS...]
# GET CF_API_BASE$PATH with the bearer token. Exits 1 on transport-level
# failure (DNS/TLS/timeout) with the raw curl output for diagnosis, or on
# CloudFlare's success:false with the structured .errors payload.
cf_api() {
  local path="$1"; shift
  local response url
  url="$CF_API_BASE$path"

  if ! response=$(curl -sS \
      -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
      -H "Content-Type: application/json" \
      "$@" \
      "$url" 2>&1); then
    echo "ERROR: CloudFlare API transport failure: $url" >&2
    printf '%s\n' "$response" >&2
    exit 1
  fi

  if ! printf '%s' "$response" | jq -e '.success == true' >/dev/null 2>&1; then
    echo "ERROR: CloudFlare API request failed: $path" >&2
    printf '%s' "$response" | jq '.errors // .' >&2 || printf '%s\n' "$response" >&2
    exit 1
  fi
  printf '%s\n' "$response"
  return 0
}

# cf_output JSON MODE JQ_TSV_FILTER [HEADER]
# MODE   : md | json
# FILTER : jq expression producing tab-separated rows (@tsv)
# HEADER : tab-separated column names
# Pipes and newlines inside cell values are escaped ('|' → '\|') so
# they don't corrupt the surrounding table structure. jq @tsv already
# escapes embedded tabs/newlines as literal '\t'/'\n', so we only need
# to handle the pipe itself here.
cf_output() {
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
      printf '%s' "$json" | jq -r "$filter" | sed 's/|/\\|/g; s/\t/ | /g; s/^/| /; s/$/ |/'
      ;;
    *)
      echo "ERROR: cf_output: unknown mode '$mode' (expected md|json)" >&2
      exit 1
      ;;
  esac
  return 0
}

# cf_output_kv JSON MODE JQ_FIELDS_FILTER
# FILTER: jq expression producing tab-separated "key\tvalue" lines
# md mode renders as "- **key:** value" list; json passes through.
cf_output_kv() {
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
  return 0
}

cf_require_account_id() {
  if [[ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    echo "ERROR: CLOUDFLARE_ACCOUNT_ID not set. Required for account-scoped endpoints (Workers, Pages)." >&2
    exit 1
  fi
  return 0
}
