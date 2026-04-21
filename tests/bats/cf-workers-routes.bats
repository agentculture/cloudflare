#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
}

@test "cf-workers-routes.sh aggregates routes across all zones into a table" {
  # Mock order matters: specific per-zone substrings FIRST so they win
  # first-match against the broader /zones mock for the enumeration call.
  cf_mock "/zones/zone-id-culture-dev-" "routes_culture.json"
  cf_mock "/zones/zone-id-agentirc-dev-" "routes_agentirc.json"
  cf_mock "/zones" "zones.json"
  run bash "$SKILL_SCRIPTS/cf-workers-routes.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Workers routes across 2 zone(s) (2)"* ]]
  [[ "$output" == *"| ZONE | PATTERN | SCRIPT | ENABLED |"* ]]
  [[ "$output" == *"| --- | --- | --- | --- |"* ]]
  [[ "$output" == *"culture.dev"* ]]
  [[ "$output" == *"agentirc.dev"* ]]
  [[ "$output" == *"culture-dev-router"* ]]
  [[ "$output" == *"agentirc-redirect"* ]]
}

@test "cf-workers-routes.sh makes 1 /zones call plus 1 call per zone" {
  cf_mock "/zones/zone-id-culture-dev-" "routes_culture.json"
  cf_mock "/zones/zone-id-agentirc-dev-" "routes_agentirc.json"
  cf_mock "/zones" "zones.json"
  run bash "$SKILL_SCRIPTS/cf-workers-routes.sh"
  [ "$status" -eq 0 ]
  cf_assert_called "https://mock.cloudflare.test/client/v4/zones"
  cf_assert_called "/zones/zone-id-culture-dev-0123456789abcdef/workers/routes"
  cf_assert_called "/zones/zone-id-agentirc-dev-fedcba9876543210/workers/routes"
}

@test "cf-workers-routes.sh --json emits a synthetic envelope with all routes" {
  cf_mock "/zones/zone-id-culture-dev-" "routes_culture.json"
  cf_mock "/zones/zone-id-agentirc-dev-" "routes_agentirc.json"
  cf_mock "/zones" "zones.json"
  run bash "$SKILL_SCRIPTS/cf-workers-routes.sh" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result | length == 2'
  echo "$output" | jq -e '.result | map(.zone_name) | contains(["culture.dev", "agentirc.dev"])'
  echo "$output" | jq -e '.result | map(.pattern) | contains(["culture.dev/*", "agentirc.dev/*"])'
  [[ "$output" != *"## Workers routes"* ]]
}

@test "cf-workers-routes.sh handles zero zones without errors" {
  # Empty /zones response — loop never iterates; synthetic envelope has result: []
  cf_mock "/zones" "zone_lookup_empty.json"
  run bash "$SKILL_SCRIPTS/cf-workers-routes.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Workers routes across 0 zone(s) (0)"* ]]
  [[ "$output" == *"| ZONE | PATTERN | SCRIPT | ENABLED |"* ]]
}

@test "cf-workers-routes.sh exits 2 on unknown argument" {
  cf_mock "/zones" "zones.json"
  run bash "$SKILL_SCRIPTS/cf-workers-routes.sh" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown argument"* ]]
}
