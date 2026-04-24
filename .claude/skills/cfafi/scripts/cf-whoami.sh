#!/usr/bin/env bash
# Verify the configured CloudFlare API token is active.
#
# Usage: cf-whoami.sh [--json]
#
# Calls /user/tokens/verify. The endpoint reports whether the token is
# active/expired/disabled and when it expires; it does NOT enumerate the
# token's scopes (that requires /user/tokens/:id which a scoped read-only
# token cannot reach).

set -euo pipefail

mode=md
for arg in "$@"; do
  case "$arg" in
    --json) mode=json ;;
    -h|--help)
      sed -n 's/^# \{0,1\}//p' "$0" | head -12
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

# shellcheck source=_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

response=$(cf_api /user/tokens/verify)

# Single object → markdown key-value. /user/tokens/verify does NOT return
# the token's scopes; enumerating them requires /user/tokens/:id which a
# scoped read-only token cannot reach. So we report status + expiry only.
[[ "$mode" == "md" ]] && echo "**CloudFlare token**"
# shellcheck disable=SC2016  # single-quoted jq filter — $r is a jq var, not a shell var
cf_output_kv "$response" "$mode" '
  .result as $r |
  [["id",         $r.id],
   ["status",     $r.status],
   ["not_before", ($r.not_before // "—")],
   ["expires_on", ($r.expires_on // "never")]]
  | .[] | @tsv
'
