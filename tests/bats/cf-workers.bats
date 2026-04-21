#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
}

@test "cf-workers.sh renders markdown table with count and script rows" {
  cf_mock "/workers/scripts" "workers_scripts.json"
  run bash "$SKILL_SCRIPTS/cf-workers.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Workers scripts (2)"* ]]
  [[ "$output" == *"| NAME | HANDLERS | MODIFIED_ON | USAGE_MODEL |"* ]]
  [[ "$output" == *"| --- | --- | --- | --- |"* ]]
  [[ "$output" == *"culture-dev-router"* ]]
  [[ "$output" == *"agentirc-redirect"* ]]
  [[ "$output" == *"standard"* ]]
  [[ "$output" == *"bundled"* ]]
}

@test "cf-workers.sh --json passes raw API response through" {
  cf_mock "/workers/scripts" "workers_scripts.json"
  run bash "$SKILL_SCRIPTS/cf-workers.sh" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result | length == 2'
  [[ "$output" != *"## Workers scripts"* ]]
}

@test "cf-workers.sh hits the account-scoped endpoint" {
  cf_mock "/workers/scripts" "workers_scripts.json"
  run bash "$SKILL_SCRIPTS/cf-workers.sh"
  [ "$status" -eq 0 ]
  cf_assert_called "/accounts/test-account-id/workers/scripts"
}

@test "cf-workers.sh exits 1 when CLOUDFLARE_ACCOUNT_ID is unset" {
  unset CLOUDFLARE_ACCOUNT_ID
  run bash "$SKILL_SCRIPTS/cf-workers.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLOUDFLARE_ACCOUNT_ID not set"* ]]
}

@test "cf-workers.sh exits 2 on unknown argument" {
  run bash "$SKILL_SCRIPTS/cf-workers.sh" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "cf-workers.sh propagates API error on success:false" {
  run bash "$SKILL_SCRIPTS/cf-workers.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CloudFlare API request failed"* ]]
}
