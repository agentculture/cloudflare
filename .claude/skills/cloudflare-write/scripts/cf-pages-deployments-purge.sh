#!/usr/bin/env bash
# Bulk-delete CloudFlare Pages deployments for a project, gated by a
# signed manifest.
#
# Two-phase workflow (see the Signed-manifest safety gate section in
# SKILL.md for why):
#
#   Phase A — PLAN (default, no --apply):
#     cf-pages-deployments-purge.sh PROJECT [--include-canonical]
#                                           [--manifest-dir DIR]
#                                           [--json]
#
#   Phase B — SIGN: human/agent opens the manifest file, inspects the
#   table, and appends exactly one line of the form:
#     SIGNED: <signer-name> <ISO-8601-UTC-timestamp>
#   Example: SIGNED: ori 2026-04-22T14:10:00Z
#
#   Phase C — APPLY:
#     cf-pages-deployments-purge.sh PROJECT --manifest PATH --apply
#                                           [--continue-on-error] [--json]
#
# The apply path refuses to run unless the manifest exists, passes
# tamper / signature / drift checks, and still matches the live
# project state. New non-canonical deployments created between plan
# and apply cause a hard drift rejection (re-plan required). Ids
# already gone are skipped (idempotent re-runs).
#
# Flags:
#   --include-canonical   include the canonical (aliased) deployment
#                         in the manifest. The final DELETE for that
#                         id uses ?force=true. Recorded in the
#                         manifest header, signed explicitly.
#   --manifest-dir DIR    directory for the plan's manifest file
#                         (default: ./.cf-purge-manifests)
#   --manifest PATH       (apply only) path to a signed manifest
#   --apply               actually DELETE. Requires --manifest.
#   --continue-on-error   keep deleting when a single DELETE fails.
#                         Default halts on first failure so the rest
#                         of the list can be re-signed and retried.
#   --json                JSON envelope output instead of markdown
#
# Env:
#   CF_PURGE_SIG_TTL   signature TTL in seconds (default 3600)
#   CF_PURGE_SLEEP     inter-delete sleep in seconds (default 0.25);
#                      set to 0 to disable pacing (tests).
#
# Exits 1 on: API error / manifest invalid / signature invalid /
#   drift / any failed DELETE. Exits 2 on usage error.

set -euo pipefail
shopt -s inherit_errexit

mode=md
apply=0
include_canonical=0
continue_on_error=0
manifest_path=""
manifest_dir="./.cf-purge-manifests"
positional=()

i=0
args=("$@")
while (( i < ${#args[@]} )); do
  arg="${args[i]}"
  case "$arg" in
    --json)               mode=json ;;
    --apply)              apply=1 ;;
    --include-canonical)  include_canonical=1 ;;
    --continue-on-error)  continue_on_error=1 ;;
    --manifest)
      i=$((i+1))
      if (( i >= ${#args[@]} )); then
        echo "ERROR: --manifest requires a path argument" >&2
        exit 2
      fi
      manifest_path="${args[i]}"
      ;;
    --manifest=*)         manifest_path="${arg#*=}" ;;
    --manifest-dir)
      i=$((i+1))
      if (( i >= ${#args[@]} )); then
        echo "ERROR: --manifest-dir requires a path argument" >&2
        exit 2
      fi
      manifest_dir="${args[i]}"
      ;;
    --manifest-dir=*)     manifest_dir="${arg#*=}" ;;
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
  i=$((i+1))
done

if (( ${#positional[@]} != 1 )); then
  echo "ERROR: expected PROJECT positional arg, got ${#positional[@]}" >&2
  echo "usage (plan):  cf-pages-deployments-purge.sh PROJECT [--include-canonical] [--manifest-dir DIR] [--json]" >&2
  echo "usage (apply): cf-pages-deployments-purge.sh PROJECT --manifest PATH --apply [--continue-on-error] [--json]" >&2
  exit 2
fi
project="${positional[0]}"

if [[ ! "$project" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo "ERROR: invalid project name: $project" >&2
  exit 2
fi

if (( apply == 1 )) && [[ -z "$manifest_path" ]]; then
  echo "ERROR: --apply requires --manifest PATH" >&2
  exit 2
fi
if (( apply == 0 )) && [[ -n "$manifest_path" ]]; then
  echo "ERROR: --manifest is only valid with --apply" >&2
  exit 2
fi

# shellcheck source=../../cloudflare/scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
cf_require_account_id

project_encoded=$(jq -rn --arg v "$project" '$v|@uri')

# -----------------------------------------------------------------------------
# Shared helpers used by both phases
# -----------------------------------------------------------------------------

# Emit the project's current canonical_deployment.id (may be empty).
fetch_canonical_id() {
  local pj
  pj=$(cf_api "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded") || return 1
  printf '%s' "$pj" | jq -r '.result.canonical_deployment.id // ""'
  return 0
}

# Fetch the full deployment list for the project (Pages per_page cap = 10).
fetch_deployments_json() {
  CF_PAGE_SIZE=10 cf_api_paginated "/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/deployments"
  return 0
}

# Compute a stable SHA-256 over a JSON array of ids (sorted, newline-
# separated). Used as the manifest tamper-check.
ids_sha256() {
  local ids_json="$1"
  printf '%s' "$ids_json" | jq -r 'sort | .[]' | sha256sum | awk '{print $1}'
  return 0
}

# Length of a JSON array passed as the first argument. Centralizes
# the `jq 'length'` idiom used for every count in this script so the
# literal isn't duplicated four times.
json_array_length() {
  local json="$1"
  printf '%s' "$json" | jq 'length'
  return 0
}

# -----------------------------------------------------------------------------
# PLAN PHASE
# -----------------------------------------------------------------------------

if (( apply == 0 )); then
  canonical_id=$(fetch_canonical_id) || {
    echo "ERROR: Pages project not found: $project" >&2
    exit 1
  }
  deployments_json=$(fetch_deployments_json)

  # Build the purge set. Exclude canonical unless --include-canonical.
  # shellcheck disable=SC2016  # single-quoted jq filter
  purge_json=$(printf '%s' "$deployments_json" | jq \
    --arg canonical "$canonical_id" \
    --argjson include_canonical "$include_canonical" '
    [.result[]
      | select($include_canonical == 1 or .id != $canonical)
      | {id, short_id,
         environment: (.environment // "—"),
         status: (.latest_stage.status // "unknown"),
         created_on,
         is_canonical: (.id == $canonical)}
    ] | sort_by(.created_on)
  ')
  purge_count=$(json_array_length "$purge_json")

  if (( purge_count == 0 )); then
    if [[ "$mode" == "json" ]]; then
      # shellcheck disable=SC2016
      jq -n --arg project "$project" \
        '{success: true, errors: [], messages: ["nothing to delete"],
          result: {project: $project, purge_count: 0}}'
    else
      printf '**Nothing to delete** — project %s has no deployments matching the purge criteria.\n' "$project"
    fi
    exit 0
  fi

  ids_json=$(printf '%s' "$purge_json" | jq '[.[].id]')
  hash=$(ids_sha256 "$ids_json")

  # Canary: a random 22-char alnum string that appears in BOTH the
  # header and the canary list row. The apply path cross-checks the
  # two and refuses to proceed if the canary list row is ticked.
  # That defeats the lazy "sed -i 's/[ ]/[x]/g'" shortcut — ticking
  # everything also ticks the canary, which aborts the apply.
  #
  # Read a fixed-size block first and slice in bash instead of piping
  # `tr | head -c 22`. With `set -o pipefail` the second head closing
  # the pipe SIGPIPEs tr, and the whole script exits 141. Use a
  # generous 256-byte sample so the alnum filter reliably yields at
  # least 22 characters — 128 bytes flaked ~2% in practice
  # (binomial(128, 62/256), P(X < 22) ≈ 3%), which was enough to break
  # one CI run out of ~30.
  _canary_alnum=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
  canary="${_canary_alnum:0:22}"
  if (( ${#canary} != 22 )); then
    echo "ERROR: canary generation yielded fewer than 22 alphanumeric characters after filtering random input" >&2
    exit 1
  fi
  unset _canary_alnum

  # Generate an ISO-8601 UTC timestamp without colons — filenames on
  # some filesystems (especially Windows-shared mounts) don't tolerate
  # colons, so use YYYYMMDDTHHMMSSZ.
  ts_file=$(date -u +%Y%m%dT%H%M%SZ)
  ts_human=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  mkdir -p "$manifest_dir"
  out_path="$manifest_dir/${ts_file}-${project}.md"

  {
    printf '# cf-purge-manifest v2\n\n'
    printf -- '- **project:** %s\n' "$project"
    printf -- '- **account_id:** %s\n' "$CLOUDFLARE_ACCOUNT_ID"
    printf -- '- **generated_at:** %s\n' "$ts_human"
    printf -- '- **canonical_deployment_id:** %s\n' "${canonical_id:-—}"
    printf -- '- **include_canonical:** %s\n' "$([[ $include_canonical -eq 1 ]] && echo true || echo false)"
    printf -- '- **count:** %s\n' "$purge_count"
    printf -- '- **ids_sha256:** %s\n' "$hash"
    printf -- '- **canary:** %s\n' "$canary"
    printf '\n'
    printf '## Deployments to delete (%s)\n\n' "$purge_count"
    # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
    printf 'Tick `- [x]` on the lines you actually want deleted. Unticked lines\n'
    printf 'are not deleted now and remain in this manifest — to delete them\n'
    printf 'later, tick them and re-sign (or re-plan for a fresh manifest if\n'
    printf 'the project has drifted). Review each line before ticking — the\n'
    printf 'canary section below catches sloppy "tick everything" sed-replace\n'
    printf 'shortcuts.\n\n'
    # Emit each deployment as an unticked GFM task-list row.
    # Row shape (important — the apply parser depends on it):
    #   - [ ] **<short8>** · `<full-uuid>` · <env> · <status> · <created> [· CANONICAL]
    # The parser regex anchors on `- [ ]` / `- [x]` + `**<short8>**` +
    # backtick-wrapped UUID. Changing the separator changes the parser.
    printf '%s' "$purge_json" | jq -r '.[] |
      "- [ ] **\(.short_id)** · `\(.id)` · \(.environment) · \(.status) · \(.created_on)" +
      (if .is_canonical then " · CANONICAL" else "" end)'
    printf '\n\n'
    printf '## Canary — do NOT tick\n\n'
    # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
    printf 'This box must stay unchecked. It exists to defeat "sed-replace all\n'
    # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
    printf '`[ ]` with `[x]`" shortcuts that skip per-line review. If it is\n'
    printf 'ticked at apply-time, the purge is refused and zero deletions occur.\n'
    # shellcheck disable=SC2016  # literal backticks wrap markdown inline code
    printf 'The random string matches the `canary:` header value above; editing\n'
    printf 'one without the other is detected and rejected.\n\n'
    # shellcheck disable=SC2016  # literal backticks wrap the canary string
    printf -- '- [ ] `%s`\n\n' "$canary"
    printf '## Signature\n\n'
    printf 'To approve this purge, append a single line below exactly like:\n\n'
    printf '    SIGNED: <your-name-or-agent-id> <ISO-8601-UTC-timestamp>\n\n'
    # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
    printf 'Example: `SIGNED: ori %s`\n\n' "$ts_human"
    printf 'Rules:\n\n'
    # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
    printf -- '- **Exactly one** `SIGNED:` line; multiples are rejected as ambiguous.\n'
    printf -- '- Timestamp must be within the last %s seconds at apply-time (clock-skew future cap: 5 min).\n' "${CF_PURGE_SIG_TTL:-3600}"
    # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
    printf -- '- The `ids_sha256` above must still match both the deployment list and the live set.\n'
    # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
    printf -- '- The canary row must be untouched (`- [ ]`) and match the `canary:` header.\n'
    printf -- '- At least one deployment line must be ticked.\n'
    printf -- '- No new non-canonical deployments may have been added since signing.\n\n'
    printf '<!-- sign on the line below -->\n'
  } > "$out_path"

  if [[ "$mode" == "json" ]]; then
    # shellcheck disable=SC2016
    jq -n \
      --arg project "$project" \
      --arg manifest "$out_path" \
      --arg hash "$hash" \
      --arg canary "$canary" \
      --arg canonical_id "$canonical_id" \
      --argjson include_canonical "$include_canonical" \
      --argjson count "$purge_count" \
      '{success: true, errors: [], messages: ["dry-run: manifest written, tick + sign to apply"],
        result: {dry_run: true, project: $project, manifest: $manifest,
                 count: $count, ids_sha256: $hash, canary: $canary,
                 canonical_deployment_id: $canonical_id,
                 include_canonical: ($include_canonical == 1)}}'
    exit 0
  fi

  printf '**Manifest written — tick + sign to apply**\n\n'
  printf -- '- **project:** %s\n' "$project"
  printf -- '- **canonical_deployment_id:** %s\n' "${canonical_id:-—}"
  printf -- '- **include_canonical:** %s\n' "$([[ $include_canonical -eq 1 ]] && echo true || echo false)"
  printf -- '- **count:** %s\n' "$purge_count"
  printf -- '- **manifest:** %s\n' "$out_path"
  printf -- '- **ids_sha256:** %s\n' "$hash"
  printf -- '- **canary:** %s\n' "$canary"
  printf '\n'
  printf 'Next steps:\n\n'
  # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
  printf '1. Open `%s` and inspect the deployment list.\n' "$out_path"
  # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
  printf '2. Tick `- [x]` on the lines you want deleted. Leave the canary row under `## Canary` untouched.\n'
  # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
  printf '3. Append a single line: `SIGNED: <name> <ISO-UTC-timestamp>`.\n'
  # shellcheck disable=SC2016  # literal backticks below wrap markdown inline code
  printf '4. Run: `%s %s --manifest %s --apply`.\n' "$(basename "$0")" "$project" "$out_path"
  exit 0
fi

# -----------------------------------------------------------------------------
# APPLY PHASE
# -----------------------------------------------------------------------------

if [[ ! -f "$manifest_path" ]]; then
  echo "ERROR: manifest not found: $manifest_path" >&2
  exit 1
fi
if [[ ! -s "$manifest_path" ]]; then
  echo "ERROR: manifest is empty: $manifest_path" >&2
  exit 1
fi

# Header sanity. v1 manifests (old table format, no canary) are
# incompatible with the task-list + canary parser below; they were
# per-run throwaways anyway so there's nothing to migrate.
if ! grep -q '^# cf-purge-manifest v2$' "$manifest_path"; then
  if grep -q '^# cf-purge-manifest v1$' "$manifest_path"; then
    echo "ERROR: manifest is v1; this script requires v2. Regenerate with the current plan command." >&2
  else
    echo "ERROR: manifest missing v2 header: $manifest_path" >&2
  fi
  exit 1
fi

manifest_read_kv() {
  # $1 = key name (e.g. "project"). Extracts the value from a
  # `- **key:** value` line. Single match required; error otherwise.
  local key="$1" matches
  matches=$(grep -cE "^- \*\*${key}:\*\* " "$manifest_path" || true)
  if [[ "$matches" != "1" ]]; then
    echo "ERROR: manifest has $matches '$key' header lines (expected 1): $manifest_path" >&2
    exit 1
  fi
  grep -E "^- \*\*${key}:\*\* " "$manifest_path" | sed -E "s/^- \*\*${key}:\*\* //"
  return 0
}

m_project=$(manifest_read_kv project)
m_account=$(manifest_read_kv account_id)
m_canonical=$(manifest_read_kv canonical_deployment_id)
# include_canonical is captured here as a parsed header field but not
# referenced again: whether canonical is in the purge set is already
# decided by its membership in the id table, and the ?force=true flag
# is driven by per-id `is_canonical` built from the *live* project
# state below. Keep parsing it so a malformed header still fails fast.
_=$(manifest_read_kv include_canonical)
m_count=$(manifest_read_kv count)
m_hash=$(manifest_read_kv ids_sha256)
m_canary=$(manifest_read_kv canary)

if [[ ! "$m_canary" =~ ^[A-Za-z0-9]{22}$ ]]; then
  echo "ERROR: manifest canary header is not a 22-char alnum string: $m_canary" >&2
  exit 1
fi

if [[ "$m_project" != "$project" ]]; then
  echo "ERROR: manifest project ($m_project) does not match positional arg ($project)" >&2
  exit 1
fi
if [[ "$m_account" != "$CLOUDFLARE_ACCOUNT_ID" ]]; then
  echo "ERROR: manifest account_id ($m_account) does not match current CLOUDFLARE_ACCOUNT_ID" >&2
  exit 1
fi
if [[ ! "$m_count" =~ ^[0-9]+$ ]]; then
  echo "ERROR: manifest count is not an integer: $m_count" >&2
  exit 1
fi
if [[ ! "$m_hash" =~ ^[a-f0-9]{64}$ ]]; then
  echo "ERROR: manifest ids_sha256 is not a valid SHA-256 hex digest: $m_hash" >&2
  exit 1
fi

# Parse the GFM task list. Rows look like:
#   - [ ] **<short8>** · `<full-uuid>` · <env> · <status> · <created> [· CANONICAL]
#   - [x] **<short8>** · `<full-uuid>` · …
#
# The regex anchors on the checkbox, the bold short_id, and the
# backtick-wrapped UUID so we don't accidentally match the canary row
# or any other task-list item.
# shellcheck disable=SC2016  # literal regex anchors — backticks are grep pattern, not command substitution
deploy_line_re='^- \[[ xX]\] \*\*[a-f0-9]{8}\*\* · `[a-f0-9-]{36}`'
# shellcheck disable=SC2016
approved_line_re='^- \[[xX]\] \*\*[a-f0-9]{8}\*\* · `[a-f0-9-]{36}`'
# shellcheck disable=SC2016
uuid_extract_re='s/^.*\*\*[a-f0-9]{8}\*\* · `([a-f0-9-]{36})`.*$/\1/'

# Full superset (any tick state) — feeds the SHA tamper check + drift.
# `|| true` so grep's "no match → exit 1" path doesn't tank the
# script under `set -e`; the follow-up count-mismatch check below
# reports the real problem (zero rows) with a specific message.
manifest_ids_sorted=$(grep -E "$deploy_line_re" "$manifest_path" \
  | sed -E "$uuid_extract_re" | sort || true)
manifest_ids_count=$(printf '%s\n' "$manifest_ids_sorted" | grep -c . || true)

if [[ "$manifest_ids_count" != "$m_count" ]]; then
  echo "ERROR: manifest header count ($m_count) does not match parsed task-list rows ($manifest_ids_count)" >&2
  exit 1
fi

# shellcheck disable=SC2016
manifest_ids_json=$(printf '%s\n' "$manifest_ids_sorted" \
  | jq -R . | jq -s 'map(select(length > 0))')
computed_hash=$(ids_sha256 "$manifest_ids_json")
if [[ "$computed_hash" != "$m_hash" ]]; then
  echo "ERROR: manifest ids_sha256 mismatch — header says $m_hash but task list hashes to $computed_hash" >&2
  echo "       the manifest's deployment list has been edited after generation; regenerate it." >&2
  exit 1
fi

# Approved subset — only lines whose checkbox is `[x]`. This is the
# operator's explicit per-line approval; everything else is left alone.
approved_ids_sorted=$(grep -E "$approved_line_re" "$manifest_path" \
  | sed -E "$uuid_extract_re" | sort || true)
# shellcheck disable=SC2016
approved_ids_json=$(printf '%s\n' "$approved_ids_sorted" \
  | jq -R . | jq -s 'map(select(length > 0))')
approved_count=$(json_array_length "$approved_ids_json")

# Canary validation: exactly one bare `- [ ] \`<alnum22>\`` row,
# string equal to the `canary:` header, checkbox NOT ticked. Any
# failure short-circuits with zero DELETEs. The whole point of the
# canary is that a "sed replace all [ ] with [x]" shortcut ticks it
# too; the apply path refusing is what makes per-line review
# enforceable rather than just expected.
# shellcheck disable=SC2016  # literal regex — backticks are grep pattern
canary_line_re='^- \[[ xX]\] `[A-Za-z0-9]{22}`$'
canary_line_count=$(grep -cE "$canary_line_re" "$manifest_path" || true)
if [[ "$canary_line_count" != "1" ]]; then
  echo "ERROR: manifest has $canary_line_count canary rows (expected exactly 1)" >&2
  exit 1
fi
canary_line=$(grep -E "$canary_line_re" "$manifest_path")
# Extract the 22-char string between the backticks.
# shellcheck disable=SC2016  # literal sed pattern with backticks
canary_on_line=$(printf '%s' "$canary_line" | sed -E 's/^.*`([A-Za-z0-9]{22})`$/\1/')
if [[ "$canary_on_line" != "$m_canary" ]]; then
  echo "ERROR: canary string on the canary row does not match the canary: header" >&2
  echo "       header:      $m_canary" >&2
  echo "       canary row:  $canary_on_line" >&2
  echo "       both were random-generated at plan-time and must match." >&2
  exit 1
fi
if [[ "$canary_line" =~ ^-\ \[[xX]\] ]]; then
  echo "ERROR: Canary is ticked. Purge refused — someone ran a tick-everything" >&2
  echo "       shortcut (e.g. sed -i 's/[ ]/[x]/g'). Regenerate the manifest" >&2
  echo "       and tick each deployment individually." >&2
  exit 1
fi

if (( approved_count == 0 )); then
  echo "ERROR: No lines are ticked in the manifest. Tick the deployments you" >&2
  echo "       want to delete (\`- [x]\`) and re-run apply. Nothing was deleted." >&2
  exit 1
fi

# Signature validation.
sig_count=$(grep -cE '^SIGNED: ' "$manifest_path" || true)
if [[ "$sig_count" == "0" ]]; then
  echo "ERROR: manifest is unsigned (no 'SIGNED:' line): $manifest_path" >&2
  exit 1
fi
if [[ "$sig_count" != "1" ]]; then
  echo "ERROR: manifest has $sig_count SIGNED lines (expected 1, ambiguous)" >&2
  exit 1
fi

sig_line=$(grep -E '^SIGNED: ' "$manifest_path")
if [[ ! "$sig_line" =~ ^SIGNED:\ ([^[:space:]]+)\ ([0-9T:Z.+-]+)$ ]]; then
  echo "ERROR: SIGNED line malformed; expected 'SIGNED: <name> <ISO-UTC-timestamp>'" >&2
  echo "  got: $sig_line" >&2
  exit 1
fi
signer="${BASH_REMATCH[1]}"
sig_ts="${BASH_REMATCH[2]}"
if (( ${#signer} > 64 )); then
  echo "ERROR: SIGNED signer name too long (${#signer} > 64)" >&2
  exit 1
fi

# Parse signature timestamp into epoch. GNU `date -d` and BSD
# `date -j -f` have incompatible syntaxes — try the GNU form first
# (CI + most Linux agents) and fall back to BSD (macOS operators
# running the skill locally). Reject anything that doesn't parse
# either way — we treat that as tampering.
iso8601_to_epoch() {
  local ts="$1" out=""
  if out=$(date -u -d "$ts" +%s 2>/dev/null); then
    printf '%s' "$out"; return 0
  fi
  # BSD date: strip a trailing Z, then parse as "%Y-%m-%dT%H:%M:%S".
  local bsd_ts="${ts%Z}"
  if out=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$bsd_ts" +%s 2>/dev/null); then
    printf '%s' "$out"; return 0
  fi
  return 1
}

if ! sig_epoch=$(iso8601_to_epoch "$sig_ts"); then
  echo "ERROR: SIGNED timestamp not parseable: $sig_ts" >&2
  exit 1
fi
now_epoch=$(date -u +%s)
ttl="${CF_PURGE_SIG_TTL:-3600}"
if [[ ! "$ttl" =~ ^[0-9]+$ ]]; then
  echo "ERROR: CF_PURGE_SIG_TTL must be an integer number of seconds; got: $ttl" >&2
  exit 1
fi
age=$(( now_epoch - sig_epoch ))
if (( age > ttl )); then
  echo "ERROR: SIGNED timestamp expired (age ${age}s > TTL ${ttl}s): $sig_ts" >&2
  echo "       re-sign the manifest with a fresh timestamp." >&2
  exit 1
fi
# Clock-skew sanity: allow up to 5 min of future drift.
if (( age < -300 )); then
  echo "ERROR: SIGNED timestamp is more than 5 min in the future: $sig_ts (age ${age}s)" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# Live drift check
# -----------------------------------------------------------------------------

live_canonical=$(fetch_canonical_id) || {
  echo "ERROR: Pages project no longer exists: $project" >&2
  exit 1
}
live_deployments_json=$(fetch_deployments_json)

# If the manifest said the canonical was X and it's now Y, reject.
# Treat "manifest had no canonical" as matching "live has no canonical".
if [[ "$m_canonical" == "—" ]]; then m_canonical=""; fi
if [[ "$live_canonical" != "$m_canonical" ]]; then
  echo "ERROR: canonical deployment rotated since signing" >&2
  echo "       manifest: ${m_canonical:-<none>}" >&2
  echo "       live:     ${live_canonical:-<none>}" >&2
  echo "       regenerate the manifest to cover the new canonical." >&2
  exit 1
fi

# Build the live id set (full deployment ids).
live_ids_json=$(printf '%s' "$live_deployments_json" | jq '[.result[].id]')

# Drift detection: any live non-canonical id NOT in the manifest is
# unsigned state and must cause a hard reject.
# shellcheck disable=SC2016
drift_json=$(jq -n \
  --argjson live "$live_ids_json" \
  --argjson manifest "$manifest_ids_json" \
  --arg canonical "$live_canonical" \
  '($live - $manifest) - [$canonical] | map(select(length > 0))')
drift_count=$(json_array_length "$drift_json")
if (( drift_count > 0 )); then
  echo "ERROR: live project has $drift_count new non-canonical deployment(s) since the manifest was signed:" >&2
  printf '%s\n' "$drift_json" | jq -r '.[] | "  - " + .' >&2
  echo "       regenerate the manifest so the new deployment(s) can be reviewed." >&2
  exit 1
fi

# Intersection set: ids that are both APPROVED (ticked) in the
# manifest and still present in live. These are what we actually
# delete. Approved ids missing from live get skipped (already gone —
# happens on idempotent re-runs). Unticked ids aren't touched at all.
#
# Drift detection above operates on the full manifest superset;
# actual deletes operate on the ticked subset. That separation is
# intentional: the SHA check asks "was the deployment list tampered
# with?", while the tick check asks "which of those did the operator
# approve?".
# shellcheck disable=SC2016
intersect_json=$(jq -n \
  --argjson live "$live_ids_json" \
  --argjson approved "$approved_ids_json" \
  '$approved - ($approved - $live)')
# shellcheck disable=SC2016
skipped_json=$(jq -n \
  --argjson live "$live_ids_json" \
  --argjson approved "$approved_ids_json" \
  '$approved - $live')

# Enrich intersection with per-id metadata (short_id, canonical flag)
# from live; sort oldest-first so a halt-on-error leaves recent
# deployments intact. We need environment + created_on from live; do
# that with an index-hash lookup.
# shellcheck disable=SC2016
plan_json=$(printf '%s' "$live_deployments_json" | jq \
  --argjson ids "$intersect_json" \
  --arg canonical "$live_canonical" '
  [.result[]
    | select(.id as $x | $ids | index($x))
    | {id, short_id,
       environment: (.environment // "—"),
       created_on,
       is_canonical: (.id == $canonical)}
  ] | sort_by(.created_on)
')
plan_count=$(json_array_length "$plan_json")
skipped_count=$(json_array_length "$skipped_json")

# -----------------------------------------------------------------------------
# Apply-log setup + deletion loop
# -----------------------------------------------------------------------------

log_path="${manifest_path}.applied.log"
{
  printf '# cf-purge applied-log\n'
  printf '# manifest: %s\n' "$manifest_path"
  printf '# signer:   %s\n' "$signer"
  printf '# sig_ts:   %s\n' "$sig_ts"
  printf '# started:  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# plan:     %s (skipped-already-gone: %s)\n' "$plan_count" "$skipped_count"
  printf '# ---\n'
} >> "$log_path"

deleted=0
failed=0
failures_json='[]'

sleep_s="${CF_PURGE_SLEEP:-0.25}"

# Iterate the plan oldest-first.
while IFS=$'\t' read -r d_id d_short d_env d_canonical; do
  [[ -z "$d_id" ]] && continue
  delete_path="/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$project_encoded/deployments/$d_id"
  if [[ "$d_canonical" == "true" ]]; then
    delete_path="${delete_path}?force=true"
  fi

  # Brace group order matters: cmd >/dev/null first, then 2>&1 around
  # the group. Writing it the other way ('2>&1 >/dev/null') dup's
  # stderr to the *original* stdout before stdout gets sent to
  # /dev/null, so cf_api's .errors payload ends up on the terminal
  # instead of in `err` — exactly what audit logging needs to avoid.
  if err=$({ cf_api "$delete_path" -X DELETE >/dev/null; } 2>&1); then
    deleted=$((deleted + 1))
    printf '%s\tdeleted\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$d_short" "$d_id" "$d_env" >> "$log_path"
    # Sleep only between successes to stay under CF rate limits.
    if [[ "$sleep_s" != "0" ]]; then
      sleep "$sleep_s" || true
    fi
  else
    failed=$((failed + 1))
    # shellcheck disable=SC2016
    failures_json=$(jq -n --argjson prev "$failures_json" \
      --arg id "$d_id" --arg short "$d_short" --arg err "$err" \
      '$prev + [{id: $id, short_id: $short, error: $err}]')
    printf '%s\tFAILED\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$d_short" "$d_id" "$d_env" "${err//$'\n'/ }" >> "$log_path"
    if (( continue_on_error == 0 )); then
      echo "ERROR: DELETE failed on $d_short ($d_id); halting. Re-run with --continue-on-error to skip past failures." >&2
      break
    fi
  fi
done < <(printf '%s' "$plan_json" | jq -r '.[] | [.id, .short_id, .environment, (.is_canonical|tostring)] | @tsv')

{
  printf '# ---\n'
  printf '# finished: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# deleted:  %s\n' "$deleted"
  printf '# skipped:  %s\n' "$skipped_count"
  printf '# failed:   %s\n' "$failed"
} >> "$log_path"

# Exit code: zero only if zero failures AND we attempted the whole plan.
attempted=$(( deleted + failed ))
status=0
if (( failed > 0 )); then
  status=1
fi

if [[ "$mode" == "json" ]]; then
  # shellcheck disable=SC2016
  jq -n \
    --arg project "$project" \
    --arg manifest "$manifest_path" \
    --arg log "$log_path" \
    --argjson deleted "$deleted" \
    --argjson skipped "$skipped_count" \
    --argjson failed "$failed" \
    --argjson attempted "$attempted" \
    --argjson plan "$plan_count" \
    --argjson failures "$failures_json" \
    '{success: ($failed == 0),
      errors: (if $failed > 0 then [{code: 1, message: "one or more DELETEs failed"}] else [] end),
      messages: [],
      result: {project: $project, manifest: $manifest, log: $log,
               summary: {plan: $plan, attempted: $attempted,
                          deleted: $deleted,
                          skipped_already_gone: $skipped,
                          failed: $failed},
               failures: $failures}}'
  exit $status
fi

if (( failed == 0 )); then
  printf '**Purge complete**\n\n'
else
  printf '**Purge finished with errors**\n\n'
fi
printf -- '- **project:** %s\n' "$project"
printf -- '- **manifest:** %s\n' "$manifest_path"
printf -- '- **log:** %s\n' "$log_path"
printf -- '- **plan:** %s\n' "$plan_count"
printf -- '- **attempted:** %s\n' "$attempted"
printf -- '- **deleted:** %s\n' "$deleted"
printf -- '- **skipped_already_gone:** %s\n' "$skipped_count"
printf -- '- **failed:** %s\n' "$failed"
if (( failed > 0 )); then
  printf '\n## Failures\n\n'
  printf '| SHORT_ID | ID | ERROR |\n'
  printf '| --- | --- | --- |\n'
  printf '%s' "$failures_json" | jq -r '.[] | [.short_id, .id, (.error | gsub("\n"; " "))] | @tsv' \
    | sed 's/|/\\|/g; s/\t/ | /g; s/^/| /; s/$/ |/'
fi
exit $status
