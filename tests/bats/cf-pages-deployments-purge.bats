#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cloudflare-write/scripts"
  PURGE_SCRIPT="$WRITE_SCRIPTS/cf-pages-deployments-purge.sh"
  # Dedicated per-test manifest dir so runs don't stomp on each other.
  MANIFEST_DIR="$BATS_TEST_TMPDIR/manifests"
  # Disable inter-delete sleep so apply tests don't take 10× longer than
  # the CF mock round-trip.
  export CF_PURGE_SLEEP=0
}

_assert_no_delete() {
  if grep -qF -- '-X	DELETE' "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
    echo "expected no DELETE, but curl.log contains one:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2
    return 1
  fi
  return 0
}

# Build a signed manifest by running the plan phase against canned
# mocks, then appending a SIGNED: line with the current UTC timestamp.
# Emits the manifest path on stdout so callers can `manifest=$(_plan_and_sign …)`.
_plan_and_sign() {
  local project="${1:-agentirc-dev}"
  shift || true
  bash "$PURGE_SCRIPT" "$project" --manifest-dir "$MANIFEST_DIR" "$@" >/dev/null
  local manifest
  manifest=$(ls -1 "$MANIFEST_DIR"/*.md | head -n 1)
  printf 'SIGNED: bats %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$manifest"
  printf '%s' "$manifest"
}

# --- usage errors ---

@test "cf-pages-deployments-purge exits 2 when PROJECT is missing" {
  run bash "$PURGE_SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected PROJECT"* ]]
}

@test "cf-pages-deployments-purge exits 2 on unknown flag" {
  run bash "$PURGE_SCRIPT" agentirc-dev --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-pages-deployments-purge exits 2 when --apply is used without --manifest" {
  run bash "$PURGE_SCRIPT" agentirc-dev --apply
  [ "$status" -eq 2 ]
  [[ "$output" == *"--apply requires --manifest"* ]]
}

@test "cf-pages-deployments-purge exits 2 when --manifest is used without --apply" {
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest /tmp/nowhere.md
  [ "$status" -eq 2 ]
  [[ "$output" == *"--manifest is only valid with --apply"* ]]
}

@test "cf-pages-deployments-purge exits 2 when --manifest path is missing its value" {
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest --apply
  [ "$status" -eq 2 ]
}

# --- PLAN phase ---

@test "purge plan writes a manifest with the non-canonical deployments" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest-dir "$MANIFEST_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Manifest written — sign to apply**"* ]]
  [[ "$output" == *"**count:** 2"* ]]
  [[ "$output" == *"**canonical_deployment_id:** aaaaaaaa"* ]]
  _assert_no_delete
  # Manifest file exists and has the expected shape.
  run ls -1 "$MANIFEST_DIR"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local manifest
  manifest="$MANIFEST_DIR/$output"
  run grep -c "^- \*\*project:\*\* agentirc-dev$" "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run grep -c "^| bbbbbbbb | bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb " "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "purge plan --include-canonical records it in header and includes canonical row" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest-dir "$MANIFEST_DIR" --include-canonical
  [ "$status" -eq 0 ]
  [[ "$output" == *"**include_canonical:** true"* ]]
  [[ "$output" == *"**count:** 3"* ]]
  local manifest
  manifest=$(ls -1 "$MANIFEST_DIR"/*.md | head -n 1)
  run grep -c "^- \*\*include_canonical:\*\* true$" "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  # Canonical row flagged in table
  run grep -c "^| aaaaaaaa | aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa .* | yes |$" "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "purge plan --json emits structured envelope" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest-dir "$MANIFEST_DIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.count == 2'
  echo "$output" | jq -e '.result.manifest | test("\\.md$")'
}

@test "purge plan exits 0 with 'nothing to delete' when only canonical exists" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_only_canonical.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  # Fixture that lists only the canonical deployment.
  cat > "$CF_FIXTURES_DIR/pages_deployments_only_canonical.json" <<'JSON'
{"success":true,"errors":[],"messages":[],"result":[
  {"id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","short_id":"aaaaaaaa",
   "project_name":"agentirc-dev","environment":"production",
   "created_on":"2025-09-01T08:00:00.000000Z",
   "latest_stage":{"name":"deploy","status":"success"}}
],"result_info":{"page":1,"per_page":10,"total_pages":1,"count":1,"total_count":1}}
JSON
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest-dir "$MANIFEST_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to delete"* ]]
  # No manifest written.
  run ls -1 "$MANIFEST_DIR"
  [ "$status" -ne 0 ] || [ -z "$output" ]
  rm -f "$CF_FIXTURES_DIR/pages_deployments_only_canonical.json"
}

# --- APPLY phase: manifest validation errors ---

@test "purge apply exits 1 when manifest file does not exist" {
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest /tmp/does-not-exist-$$.md --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"manifest not found"* ]]
  _assert_no_delete
}

@test "purge apply exits 1 when manifest is missing v1 header" {
  local bad="$BATS_TEST_TMPDIR/bad.md"
  printf 'not a manifest\n' > "$bad"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$bad" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing v1 header"* ]]
  _assert_no_delete
}

@test "purge apply exits 1 when manifest is unsigned" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  # Plan, but don't sign.
  bash "$PURGE_SCRIPT" agentirc-dev --manifest-dir "$MANIFEST_DIR" >/dev/null
  local manifest
  manifest=$(ls -1 "$MANIFEST_DIR"/*.md | head -n 1)
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsigned"* ]]
  _assert_no_delete
}

@test "purge apply exits 1 on ambiguous (multiple SIGNED) lines" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  printf 'SIGNED: someone-else 2026-04-22T14:00:00Z\n' >> "$manifest"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"ambiguous"* ]] || [[ "$output" == *"expected 1"* ]]
  _assert_no_delete
}

@test "purge apply exits 1 when SIGNED timestamp is too old" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  bash "$PURGE_SCRIPT" agentirc-dev --manifest-dir "$MANIFEST_DIR" >/dev/null
  local manifest
  manifest=$(ls -1 "$MANIFEST_DIR"/*.md | head -n 1)
  # Sign with a very stale timestamp.
  printf 'SIGNED: bats 2020-01-01T00:00:00Z\n' >> "$manifest"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"expired"* ]]
  _assert_no_delete
}

@test "purge apply exits 1 when SIGNED timestamp is far in the future" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  bash "$PURGE_SCRIPT" agentirc-dev --manifest-dir "$MANIFEST_DIR" >/dev/null
  local manifest
  manifest=$(ls -1 "$MANIFEST_DIR"/*.md | head -n 1)
  printf 'SIGNED: bats 2099-01-01T00:00:00Z\n' >> "$manifest"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"future"* ]]
  _assert_no_delete
}

@test "purge apply exits 1 when manifest project name differs from positional arg" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  run bash "$PURGE_SCRIPT" some-other-project --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"project"* ]]
  [[ "$output" == *"does not match"* ]]
  _assert_no_delete
}

@test "purge apply exits 1 when ids_sha256 no longer matches the table (tampered)" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  # Delete one deployment row — tamper, breaks the SHA.
  sed -i '/| bbbbbbbb | bbbbbbbb-bbbb/d' "$manifest"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"ids_sha256 mismatch"* ]] || [[ "$output" == *"count"* ]]
  _assert_no_delete
}

# --- APPLY phase: drift detection ---

@test "purge apply detects a new non-canonical deployment and rejects" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  # Re-mock with the drift fixture for the apply-side re-fetch.
  : > "$BATS_TEST_TMPDIR/mocks.txt"
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc_drift.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"new non-canonical deployment"* ]] || [[ "$output" == *"drift"* ]]
  [[ "$output" == *"cccccccc"* ]]
  _assert_no_delete
}

# --- APPLY phase: happy path and variants ---

@test "purge apply deletes every non-canonical deployment and writes applied-log" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  cf_mock "/pages/projects/agentirc-dev/deployments/bbbbbbbb" "pages_deployment_delete_ok.json"
  cf_mock "/pages/projects/agentirc-dev/deployments/ffffffff" "pages_deployment_delete_ok.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Purge complete**"* ]]
  [[ "$output" == *"**deleted:** 2"* ]]
  [[ "$output" == *"**failed:** 0"* ]]
  # Two DELETE calls to the right paths.
  cf_assert_called "-X	DELETE"
  cf_assert_called "/deployments/bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
  cf_assert_called "/deployments/ffffffff-ffff-4fff-ffff-ffffffffffff"
  # applied.log exists next to the manifest and records the deletes.
  [ -f "${manifest}.applied.log" ]
  run grep -c $'\tdeleted\t' "${manifest}.applied.log"
  [ "$output" = "2" ]
}

@test "purge apply --include-canonical passes ?force=true on the canonical DELETE" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign agentirc-dev --include-canonical)
  cf_mock "/pages/projects/agentirc-dev/deployments/aaaaaaaa" "pages_deployment_delete_ok.json"
  cf_mock "/pages/projects/agentirc-dev/deployments/bbbbbbbb" "pages_deployment_delete_ok.json"
  cf_mock "/pages/projects/agentirc-dev/deployments/ffffffff" "pages_deployment_delete_ok.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**deleted:** 3"* ]]
  cf_assert_called "?force=true"
  cf_assert_called "/deployments/aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
}

@test "purge apply halts on first DELETE failure by default" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  # Let the first (older, bbbbbbbb) succeed and the second (ffffffff) fail.
  cf_mock "/pages/projects/agentirc-dev/deployments/bbbbbbbb" "pages_deployment_delete_ok.json"
  cf_mock "/pages/projects/agentirc-dev/deployments/ffffffff" "pages_deployment_delete_err.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"**deleted:** 1"* ]]
  [[ "$output" == *"**failed:** 1"* ]]
}

@test "purge apply --continue-on-error attempts all deletes even after a failure" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  # bbbbbbbb fails first; ffffffff should still be attempted.
  cf_mock "/pages/projects/agentirc-dev/deployments/bbbbbbbb" "pages_deployment_delete_err.json"
  cf_mock "/pages/projects/agentirc-dev/deployments/ffffffff" "pages_deployment_delete_ok.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply --continue-on-error
  [ "$status" -eq 1 ]
  [[ "$output" == *"**deleted:** 1"* ]]
  [[ "$output" == *"**failed:** 1"* ]]
  cf_assert_called "/deployments/ffffffff-ffff-4fff-ffff-ffffffffffff"
}

@test "purge apply --json emits a structured summary with failures array" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  cf_mock "/pages/projects/agentirc-dev/deployments/bbbbbbbb" "pages_deployment_delete_ok.json"
  cf_mock "/pages/projects/agentirc-dev/deployments/ffffffff" "pages_deployment_delete_ok.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.summary.deleted == 2'
  echo "$output" | jq -e '.result.summary.failed == 0'
  echo "$output" | jq -e '.result.failures | length == 0'
}
