#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
}

@test "cf-zones.sh renders markdown table with heading and zone count" {
  cf_mock "/zones" "zones.json"
  run bash "$SKILL_SCRIPTS/cf-zones.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Zones (2)"* ]]
  [[ "$output" == *"| ID | NAME | STATUS | PLAN |"* ]]
  [[ "$output" == *"| --- | --- | --- | --- |"* ]]
  [[ "$output" == *"culture.dev"* ]]
  [[ "$output" == *"agentirc.dev"* ]]
  [[ "$output" == *"Free Website"* ]]
}

@test "cf-zones.sh --json passes raw API response through" {
  cf_mock "/zones" "zones.json"
  run bash "$SKILL_SCRIPTS/cf-zones.sh" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result | length == 2'
  echo "$output" | jq -e '.result | map(.name) | contains(["culture.dev"])'
  # No markdown scaffolding when --json
  [[ "$output" != *"## Zones"* ]]
}

@test "cf-zones.sh hits the /zones endpoint" {
  cf_mock "/zones" "zones.json"
  run bash "$SKILL_SCRIPTS/cf-zones.sh"
  [ "$status" -eq 0 ]
  cf_assert_called "https://mock.cloudflare.test/client/v4/zones"
}

@test "cf-zones.sh exits 2 on unknown argument" {
  cf_mock "/zones" "zones.json"
  run bash "$SKILL_SCRIPTS/cf-zones.sh" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "cf-zones.sh propagates the API error path on success:false" {
  run bash "$SKILL_SCRIPTS/cf-zones.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CloudFlare API request failed"* ]]
}
