#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
}

@test "cf-whoami.sh renders markdown key-value with CloudFlare-token heading" {
  cf_mock "/user/tokens/verify" "token_verify.json"
  run bash "$SKILL_SCRIPTS/cf-whoami.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"**CloudFlare token**"* ]]
  [[ "$output" == *"- **id:**"* ]]
  [[ "$output" == *"- **status:** active"* ]]
  [[ "$output" == *"- **expires_on:** 2027-01-01T00:00:00Z"* ]]
}

@test "cf-whoami.sh --json passes raw API response through" {
  cf_mock "/user/tokens/verify" "token_verify.json"
  run bash "$SKILL_SCRIPTS/cf-whoami.sh" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.status == "active"'
  # No markdown scaffolding when --json
  [[ "$output" != *"**CloudFlare token**"* ]]
}

@test "cf-whoami.sh hits the /user/tokens/verify endpoint" {
  cf_mock "/user/tokens/verify" "token_verify.json"
  run bash "$SKILL_SCRIPTS/cf-whoami.sh"
  [ "$status" -eq 0 ]
  cf_assert_called "/user/tokens/verify"
}

@test "cf-whoami.sh exits 2 on unknown argument" {
  cf_mock "/user/tokens/verify" "token_verify.json"
  run bash "$SKILL_SCRIPTS/cf-whoami.sh" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "cf-whoami.sh propagates the API error path on success:false" {
  run bash "$SKILL_SCRIPTS/cf-whoami.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CloudFlare API request failed"* ]]
}
