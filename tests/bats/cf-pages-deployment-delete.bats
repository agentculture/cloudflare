#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cfafi-write/scripts"
  # Project-detail GET, deployments list, and DELETE all go through the
  # same /accounts/.../pages/projects/agentirc-dev/... prefix. The stub's
  # longest-substring-wins policy disambiguates by URL suffix.
}

_assert_no_delete() {
  if grep -qF -- '-X	DELETE' "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
    echo "expected no DELETE, but curl.log contains one:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2
    return 1
  fi
  return 0
}

# --- usage errors ---

@test "cf-pages-deployment-delete exits 2 when positional args missing" {
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected PROJECT and SHORT_ID_OR_ID"* ]]
}

@test "cf-pages-deployment-delete exits 2 on unknown flag" {
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev bbbbbbbb --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-pages-deployment-delete exits 2 on invalid project name" {
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" 'bad name!' bbbbbbbb
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid project name"* ]]
}

@test "cf-pages-deployment-delete exits 2 on invalid deployment id (non-hex)" {
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev 'not a real id!'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid deployment id"* ]]
}

# --- dry-run, non-canonical ---

@test "cf-pages-deployment-delete dry-run on non-canonical short_id prints would-DELETE, no DELETE call" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev bbbbbbbb
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"bbbbbbbb"* ]]
  [[ "$output" == *"**canonical:** no"* ]]
  [[ "$output" == *"would DELETE"* ]]
  [[ "$output" == *"/deployments/bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"* ]]
  [[ "$output" != *"?force=true"* ]]
  _assert_no_delete
}

@test "cf-pages-deployment-delete --json dry-run emits synthetic envelope" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev bbbbbbbb --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.short_id == "bbbbbbbb"'
  echo "$output" | jq -e '.result.canonical == false'
  _assert_no_delete
}

# --- apply path, non-canonical ---

@test "cf-pages-deployment-delete --apply on non-canonical DELETEs without force=true" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev/deployments/bbbbbbbb" "pages_deployment_delete_ok.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev bbbbbbbb --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Deployment deleted**"* ]]
  cf_assert_called "-X	DELETE"
  cf_assert_called "/deployments/bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb"
  run grep -F "?force=true" "$BATS_TEST_TMPDIR/curl.log"
  [ "$status" -ne 0 ]
}

@test "cf-pages-deployment-delete --apply accepts full UUID too" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev/deployments/bbbbbbbb" "pages_deployment_delete_ok.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Deployment deleted**"* ]]
}

# --- canonical guard ---

@test "cf-pages-deployment-delete refuses canonical without --force-canonical (dry-run)" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev aaaaaaaa
  [ "$status" -eq 1 ]
  [[ "$output" == *"canonical (aliased) deployment"* ]]
  [[ "$output" == *"--force-canonical"* ]]
  _assert_no_delete
}

@test "cf-pages-deployment-delete refuses canonical --apply without --force-canonical" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev aaaaaaaa --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"canonical (aliased) deployment"* ]]
  _assert_no_delete
}

@test "cf-pages-deployment-delete --force-canonical dry-run shows force=true in would-DELETE" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev aaaaaaaa --force-canonical
  [ "$status" -eq 0 ]
  [[ "$output" == *"**canonical:** yes (force=true)"* ]]
  [[ "$output" == *"?force=true"* ]]
  _assert_no_delete
}

@test "cf-pages-deployment-delete --force-canonical --apply DELETEs with ?force=true" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev/deployments/aaaaaaaa" "pages_deployment_delete_ok.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev aaaaaaaa --force-canonical --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Deployment deleted**"* ]]
  cf_assert_called "-X	DELETE"
  cf_assert_called "?force=true"
}

# --- resolution errors ---

@test "cf-pages-deployment-delete exits 1 when project does not exist and surfaces the underlying CF error" {
  cf_mock "/pages/projects/nosuch" "pages_project_not_found.json"
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" nosuch bbbbbbbb
  [ "$status" -eq 1 ]
  # cf_api's own error output is preserved (not swallowed with 2>/dev/null),
  # so both the CF-side message and our locally-added hint are visible.
  [[ "$output" == *"Project not found"* ]]
  [[ "$output" == *"could not resolve Pages project"* ]]
  _assert_no_delete
}

@test "cf-pages-deployment-delete exits 1 when short_id does not match" {
  cf_mock "/pages/projects/agentirc-dev/deployments?per_page" "pages_deployments_agentirc.json"
  cf_mock "/pages/projects/agentirc-dev" "pages_project_agentirc_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-deployment-delete.sh" agentirc-dev 99999999
  [ "$status" -eq 1 ]
  [[ "$output" == *"deployment not found"* ]]
  _assert_no_delete
}
