#!/usr/bin/env bash
# Create a DNS record in a CloudFlare zone.
#
# Usage:
#   cf-dns-create.sh ZONE TYPE NAME CONTENT [--proxied] [--ttl=N] [--comment=STR] [--apply] [--json]
#
# Default is DRY-RUN: resolves the zone, checks no matching
# type+name+content record already exists, prints the JSON body
# it would POST, and exits 0 WITHOUT mutating anything. Pass
# --apply to actually create the record.
#
# Common use cases:
#   # Proxied A record at the apex (canonical "redirect-only" zone trick —
#   # 192.0.2.1 is TEST-NET-1, which CF intercepts at the edge before
#   # forwarding, so the origin IP is irrelevant):
#   cf-dns-create.sh agentculture.org A agentculture.org 192.0.2.1 --proxied --apply
#
#   # Proxied www subdomain pointing at the same edge:
#   cf-dns-create.sh agentculture.org A www.agentculture.org 192.0.2.1 --proxied --apply
#
# Flags:
#   --proxied       orange-cloud the record (CF intercepts HTTP traffic)
#   --ttl=N         TTL in seconds (default 1 = "automatic"; proxied records are forced to 1 by CF)
#   --comment=STR   free-text note attached to the record (shows in dashboard)
#   --apply         actually POST (without it, this is a dry-run)
#   --json          raw CloudFlare response envelope (or simulated body in dry-run)
#   --              end-of-options marker. Use when NAME or CONTENT legitimately
#                   starts with a dash (e.g. some TXT values). Anything after `--`
#                   is positional, regardless of leading characters.
#
# Idempotency key is type+name+content. Exits 1 if a record with the
# same three fields already exists on the zone. Records with the same
# type+name but different content (e.g. round-robin A records) are
# allowed — CF itself supports that shape.
#
# Exits 1 on: zone not found, matching record already exists, API
# error. Exits 2 on usage error.

set -euo pipefail
shopt -s inherit_errexit

mode=md
apply=0
proxied=0
ttl=1
comment="Managed by cf-dns-create.sh in agentculture/cloudflare"
positional=()
# `--` end-of-options marker: any arg after it is treated as
# positional, even if it begins with `-`. Needed for TXT record
# values (and occasionally content) that legitimately start with a
# dash — without this, the `-*` case arm would reject them.
after_ddash=0

for arg in "$@"; do
  if (( after_ddash )); then
    positional+=("$arg")
    continue
  fi
  case "$arg" in
    --)          after_ddash=1 ;;
    --json)      mode=json ;;
    --apply)     apply=1 ;;
    --proxied)   proxied=1 ;;
    --ttl=*)     ttl="${arg#*=}" ;;
    --comment=*) comment="${arg#*=}" ;;
    -h|--help)
      # Skip line 1 (shebang), strip `# ?`, stop at the first non-comment line.
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

if (( ${#positional[@]} != 4 )); then
  echo "ERROR: expected 4 positional args (ZONE TYPE NAME CONTENT), got ${#positional[@]}" >&2
  echo "usage: cf-dns-create.sh ZONE TYPE NAME CONTENT [--proxied] [--ttl=N] [--comment=STR] [--apply] [--json]" >&2
  exit 2
fi
zone_name="${positional[0]}"
record_type="${positional[1]}"
record_name="${positional[2]}"
record_content="${positional[3]}"

# Validate record type against CF's supported set. Not exhaustive —
# this is the subset that covers the redirect/web/mail/auth use cases
# we actually hit. If you need PTR, URI, TLSA, etc., extend here.
case "$record_type" in
  A|AAAA|CNAME|TXT|MX|NS|SRV|CAA) ;;
  *)
    echo "ERROR: unsupported record type: $record_type (allowed: A AAAA CNAME TXT MX NS SRV CAA)" >&2
    exit 2
    ;;
esac

# Validate TTL: CF accepts 1 ("automatic") or 60-86400 for manual TTLs.
if ! [[ "$ttl" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --ttl must be an integer, got: $ttl" >&2
  exit 2
fi
ttl=$((10#$ttl))
if (( ttl != 1 && (ttl < 60 || ttl > 86400) )); then
  echo "ERROR: --ttl must be 1 (automatic) or between 60 and 86400, got: $ttl" >&2
  exit 2
fi

# Proxied records must use TTL=1 per CF. Fail loudly instead of
# silently overriding the user's choice.
if (( proxied && ttl != 1 )); then
  echo "ERROR: --proxied records must use --ttl=1 (CloudFlare ignores manual TTL on proxied records)" >&2
  exit 2
fi

# shellcheck source=../../cloudflare/scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Resolve ZONE to a zone ID.
zones_json=$(cf_api_paginated /zones)
# shellcheck disable=SC2016  # single-quoted jq filter
zone_id=$(printf '%s' "$zones_json" | jq -r --arg name "$zone_name" \
  '[.result[] | select(.name == $name) | .id] | .[0] // ""')

if [[ -z "$zone_id" ]]; then
  echo "ERROR: zone $zone_name not found in this account" >&2
  exit 1
fi

# Idempotency: bail if a record with the same type+name+content
# already exists on the zone. CF accepts a `match=all` query string
# that narrows server-side; we use it to keep the response small even
# on zones with hundreds of records. Every user-supplied value that
# ends up in the query string is URL-encoded — even `record_type`,
# which is already allowlist-validated, so we stay consistent with
# the repo-wide "encode everything from outside" convention.
type_encoded=$(jq -rn --arg v "$record_type"       '$v|@uri')
name_encoded=$(jq -rn --arg v "$record_name"       '$v|@uri')
content_encoded=$(jq -rn --arg v "$record_content" '$v|@uri')
existing_json=$(cf_api_paginated \
  "/zones/$zone_id/dns_records?type=$type_encoded&name=$name_encoded&content=$content_encoded&match=all")

# shellcheck disable=SC2016  # single-quoted jq filter
existing_id=$(printf '%s' "$existing_json" | jq -r '[.result[].id] | .[0] // ""')

if [[ -n "$existing_id" ]]; then
  echo "ERROR: DNS record already exists on $zone_name: $record_type $record_name $record_content (id=$existing_id)" >&2
  echo "       nothing to do. Use cf-dns-update.sh (not yet implemented) to change content." >&2
  exit 1
fi

# Build the request body.
# shellcheck disable=SC2016  # single-quoted jq filter
body=$(jq -n \
  --arg type    "$record_type" \
  --arg name    "$record_name" \
  --arg content "$record_content" \
  --argjson ttl "$ttl" \
  --argjson proxied "$([[ $proxied -eq 1 ]] && echo true || echo false)" \
  --arg comment "$comment" \
  '{
    type: $type,
    name: $name,
    content: $content,
    ttl: $ttl,
    proxied: $proxied,
    comment: $comment
  }')

render_summary_kv() {
  printf -- '- **zone:** %s (id=%s)\n' "$zone_name" "$zone_id"
  printf -- '- **type:** %s\n' "$record_type"
  printf -- '- **name:** %s\n' "$record_name"
  printf -- '- **content:** %s\n' "$record_content"
  printf -- '- **ttl:** %s%s\n' "$ttl" "$([[ $ttl -eq 1 ]] && echo ' (automatic)')"
  printf -- '- **proxied:** %s\n' "$([[ $proxied -eq 1 ]] && echo true || echo false)"
}

if (( apply == 0 )); then
  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016  # single-quoted jq filter
    jq -n --argjson body "$body" --arg zone_id "$zone_id" \
      '{success: true, errors: [], messages: ["dry-run: no changes applied"],
        result: {dry_run: true, zone_id: $zone_id, would_post: $body}}'
    exit 0
  fi
  printf '**Dry-run — no changes applied**\n\n'
  render_summary_kv
  # shellcheck disable=SC2016  # single-quoted literal backticks wrap markdown inline code
  printf '\n**would POST** `/zones/%s/dns_records`:\n\n' "$zone_id"
  printf '```json\n'
  printf '%s\n' "$body"
  printf '```\n'
  exit 0
fi

# Apply path.
response=$(cf_api "/zones/$zone_id/dns_records" -X POST --data-binary "$body")

if [[ "$mode" == "json" ]]; then
  printf '%s\n' "$response"
  exit 0
fi

new_id=$(printf '%s' "$response" | jq -r '.result.id // "—"')
printf '**DNS record created**\n\n'
render_summary_kv
printf -- '- **record_id:** %s\n' "$new_id"
