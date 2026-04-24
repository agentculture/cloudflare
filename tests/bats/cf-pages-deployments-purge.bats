#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cfafi-write/scripts"
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

# Tick every deployment task-list row (`- [ ] **<8 hex>** ...`) in a
# manifest. The canary row has a bare backtick-wrapped alnum string
# instead of `**short8**`, so it's left untouched.
_tick_all_non_canary() {
  sed -i -E 's/^- \[ \] (\*\*[a-f0-9]{8}\*\*)/- [x] \1/' "$1"
}

# Tick one specific row by its short_id.
_tick_short() {
  sed -i -E "s/^- \[ \] (\*\*$2\*\*)/- [x] \1/" "$1"
}

# Tick the canary row (to exercise the "sed all" shortcut refusal).
_tick_canary() {
  sed -i -E 's/^- \[ \] (`[A-Za-z0-9]{22}`)$/- [x] \1/' "$1"
}

_sign() {
  printf 'SIGNED: bats %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$1"
}

# Plan + tick all non-canary + sign. The helper callers from the v1
# era expected "every deployment in the manifest is approved for
# deletion" — preserve that behavior by ticking everything non-canary
# here, so the body of each test still reads the way it did.
_plan_and_sign() {
  local project="${1:-agentirc-dev}"
  shift || true
  bash "$PURGE_SCRIPT" "$project" --manifest-dir "$MANIFEST_DIR" "$@" >/dev/null
  local manifest
  manifest=$(ls -1 "$MANIFEST_DIR"/*.md | head -n 1)
  _tick_all_non_canary "$manifest"
  _sign "$manifest"
  printf '%s' "$manifest"
}

# Plan only (no tick, no sign). For tests that need a manifest in a
# specific intermediate state (e.g. test the "no ticks" refusal).
_plan_only() {
  local project="${1:-agentirc-dev}"
  shift || true
  bash "$PURGE_SCRIPT" "$project" --manifest-dir "$MANIFEST_DIR" "$@" >/dev/null
  ls -1 "$MANIFEST_DIR"/*.md | head -n 1
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

@test "purge plan writes a v2 manifest with a canary header and canary list row" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest-dir "$MANIFEST_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Manifest written — tick + sign to apply**"* ]]
  [[ "$output" == *"**count:** 2"* ]]
  [[ "$output" == *"**canonical_deployment_id:** aaaaaaaa"* ]]
  [[ "$output" == *"**canary:**"* ]]
  _assert_no_delete

  local manifest
  manifest=$(ls -1 "$MANIFEST_DIR"/*.md | head -n 1)
  # v2 header present
  run grep -c '^# cf-purge-manifest v2$' "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  # Header carries a 22-char alnum canary
  run grep -cE '^- \*\*canary:\*\* [A-Za-z0-9]{22}$' "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  # Exactly one deployment line per row, all initially unticked
  run grep -cE '^- \[ \] \*\*[a-f0-9]{8}\*\* · `[a-f0-9-]{36}`' "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  # Canary row present and unticked, backticks wrap a 22-char alnum
  run grep -cE '^- \[ \] `[A-Za-z0-9]{22}`$' "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  # Canary header value matches canary list-row value
  local h="" l=""
  h=$(grep -E '^- \*\*canary:\*\* ' "$manifest" | sed -E 's/^- \*\*canary:\*\* //')
  l=$(grep -E '^- \[ \] `[A-Za-z0-9]{22}`$' "$manifest" | sed -E 's/^.*`([A-Za-z0-9]{22})`$/\1/')
  [ "$h" = "$l" ]
}

@test "purge plan --include-canonical records it in header and includes canonical task-list row" {
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
  # Canonical row is in the task list and carries the CANONICAL marker
  run grep -cE '^- \[ \] \*\*aaaaaaaa\*\* · `aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa` · .* · CANONICAL$' "$manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "purge plan --json emits structured envelope with canary field" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest-dir "$MANIFEST_DIR" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.count == 2'
  echo "$output" | jq -e '.result.manifest | test("\\.md$")'
  echo "$output" | jq -e '.result.canary | test("^[A-Za-z0-9]{22}$")'
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

@test "purge apply exits 1 when manifest is missing v2 header" {
  local bad="$BATS_TEST_TMPDIR/bad.md"
  printf 'not a manifest\n' > "$bad"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$bad" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing v2 header"* ]]
  _assert_no_delete
}

@test "purge apply surfaces v1→v2 hint when handed an old manifest" {
  local old="$BATS_TEST_TMPDIR/v1.md"
  printf '# cf-purge-manifest v1\n- **project:** agentirc-dev\n' > "$old"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$old" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"v1"* ]]
  [[ "$output" == *"v2"* ]]
  _assert_no_delete
}

@test "purge apply exits 1 when manifest is unsigned" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_only)
  _tick_all_non_canary "$manifest"
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
  local manifest
  manifest=$(_plan_only)
  _tick_all_non_canary "$manifest"
  printf 'SIGNED: bats 2020-01-01T00:00:00Z\n' >> "$manifest"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"expired"* ]]
  _assert_no_delete
}

@test "purge apply exits 1 when SIGNED timestamp is far in the future" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_only)
  _tick_all_non_canary "$manifest"
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

@test "purge apply exits 1 when ids_sha256 no longer matches the task list (tampered)" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  # Remove one deployment row — breaks the SHA.
  sed -i '/bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb/d' "$manifest"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"ids_sha256 mismatch"* ]] || [[ "$output" == *"count"* ]]
  _assert_no_delete
}

# --- APPLY phase: canary validation ---

@test "purge apply refuses to proceed when the canary row is ticked" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_only)
  # Simulate the "sed -i 's/[ ]/[x]/g'" shortcut: tick everything,
  # including the canary row.
  sed -i -E 's/^- \[ \]/- [x]/' "$manifest"
  _sign "$manifest"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"Canary is ticked"* ]]
  _assert_no_delete
}

@test "purge apply refuses when the canary line's random string is edited" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  # Replace the canary list row's string (but not the header), breaking
  # the cross-check. The replacement has to be a valid 22-char alnum so
  # the row regex still matches — otherwise the "canary line count"
  # check would fire first with a less informative message.
  sed -i -E 's/^(- \[ \] )`[A-Za-z0-9]{22}`$/\1`Zzzzzzzzzzzzzzzzzzzzzz`/' "$manifest"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"canary string on the canary row does not match"* ]]
  _assert_no_delete
}

@test "purge apply refuses when the canary row is missing" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  # Delete the canary list row.
  sed -i -E '/^- \[ \] `[A-Za-z0-9]{22}`$/d' "$manifest"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"canary rows"* ]] || [[ "$output" == *"expected exactly 1"* ]]
  _assert_no_delete
}

@test "purge apply refuses when no deployment boxes are ticked" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_only)
  # Sign but don't tick anything.
  _sign "$manifest"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"No lines are ticked"* ]]
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

@test "purge apply deletes every ticked deployment and writes applied-log" {
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

@test "purge apply always sends ?force=true on EVERY DELETE (guards against issue #1 follow-up)" {
  # CF Pages marks both the canonical deployment AND every per-branch
  # preview deployment (aliases like `<branch>.<project>.pages.dev`)
  # as aliased. A force-free DELETE on any of them returns CF code
  # 8000035. The manifest-tick gate is the real consent layer, so the
  # script unconditionally forces — this test stops a regression that
  # would silently halt a purge partway through (which happened live
  # on `agentirc-dev` with 41 aliased deployments in the 137-row set).
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_and_sign)
  cf_mock "/pages/projects/agentirc-dev/deployments/bbbbbbbb" "pages_deployment_delete_ok.json"
  cf_mock "/pages/projects/agentirc-dev/deployments/ffffffff" "pages_deployment_delete_ok.json"
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 0 ]
  # Use `grep -c` directly — it reports an accurate count (0 for no
  # match, correct non-zero exit code). The earlier `echo "$var" | wc -l`
  # pattern would double-count a trailing newline and mask the case
  # where there are zero DELETEs but zero ?force=true either (both
  # pipelines would report 1). (Copilot caught this on PR #14.)
  run grep -cF -- '-X	DELETE' "$BATS_TEST_TMPDIR/curl.log"
  [ "$status" -eq 0 ]
  local total_deletes="$output"
  [ "$total_deletes" -gt 0 ]
  # Count DELETE lines that ALSO carry ?force=true. Filter first on
  # DELETE so we don't false-match a ?force=true that happened to
  # appear in some other logged curl argv (defensive — there's no
  # such path today, but belt + suspenders).
  run bash -c "grep -F -- '-X	DELETE' \"$BATS_TEST_TMPDIR/curl.log\" | grep -cF -- '?force=true'"
  [ "$status" -eq 0 ]
  [ "$total_deletes" = "$output" ]
}

@test "purge apply deletes ONLY the ticked subset, leaves others untouched" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  local manifest
  manifest=$(_plan_only)
  # Tick only one of the two non-canonical lines. The "ffffffff" row
  # stays unticked and must NOT receive a DELETE.
  _tick_short "$manifest" bbbbbbbb
  _sign "$manifest"
  cf_mock "/pages/projects/agentirc-dev/deployments/bbbbbbbb" "pages_deployment_delete_ok.json"
  # Intentionally do NOT mock ffffffff's DELETE — if the script tries to
  # hit it, the stub returns a synthetic success:false and this test
  # fails on a real DELETE attempt. Belt and suspenders: assert
  # curl.log doesn't contain that id either.
  run bash "$PURGE_SCRIPT" agentirc-dev --manifest "$manifest" --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**deleted:** 1"* ]]
  cf_assert_called "/deployments/bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
  # No DELETE on the unticked one.
  run grep -F "/deployments/ffffffff-ffff-4fff-ffff-ffffffffffff" "$BATS_TEST_TMPDIR/curl.log"
  [ "$status" -ne 0 ]
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
