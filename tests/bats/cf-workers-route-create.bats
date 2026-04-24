#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cfafi-write/scripts"
}

_assert_no_post() {
  if grep -qF -- "-X	POST" "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
    echo "expected no POST, but curl.log contains one:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2
    return 1
  fi
  return 0
}

# --- dry-run (default, no --apply) ---

@test "cf-workers-route-create.sh dry-run resolves zone and prints would-POST body" {
  cf_mock "/zones?per_page"                                              "zones.json"
  cf_mock "/zones/zone-id-culture-dev-0123456789abcdef/workers/routes?per_page" "routes_empty.json"
  run bash "$WRITE_SCRIPTS/cf-workers-route-create.sh" culture.dev 'culture.dev/afi*' afi-proxy
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"**zone:** culture.dev"* ]]
  [[ "$output" == *"**pattern:** culture.dev/afi*"* ]]
  [[ "$output" == *"**script:** afi-proxy"* ]]
  [[ "$output" == *'"pattern": "culture.dev/afi*"'* ]]
  [[ "$output" == *'"script": "afi-proxy"'* ]]
  _assert_no_post
}

@test "cf-workers-route-create.sh dry-run --json emits synthetic envelope" {
  cf_mock "/zones?per_page"                                              "zones.json"
  cf_mock "/zones/zone-id-culture-dev-0123456789abcdef/workers/routes?per_page" "routes_empty.json"
  run bash "$WRITE_SCRIPTS/cf-workers-route-create.sh" culture.dev 'culture.dev/afi*' afi-proxy --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.zone == "culture.dev"'
  echo "$output" | jq -e '.result.would_post.pattern == "culture.dev/afi*"'
  echo "$output" | jq -e '.result.would_post.script == "afi-proxy"'
  _assert_no_post
}

# --- apply path ---

@test "cf-workers-route-create.sh --apply POSTs and reports new route id" {
  cf_mock "/zones?per_page"                                              "zones.json"
  cf_mock "/zones/zone-id-culture-dev-0123456789abcdef/workers/routes?per_page" "routes_empty.json"
  cf_mock "/zones/zone-id-culture-dev-0123456789abcdef/workers/routes"        "workers_route_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-workers-route-create.sh" culture.dev 'culture.dev/afi*' afi-proxy --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Workers route created**"* ]]
  [[ "$output" == *"route-culture-dev-afi-99999999"* ]]
  cf_assert_called "-X	POST"
  cf_assert_called "/zones/zone-id-culture-dev-0123456789abcdef/workers/routes"
}

# --- idempotency & validation ---

@test "cf-workers-route-create.sh exits 1 when zone not found" {
  cf_mock "/zones?per_page" "zone_lookup_empty.json"
  run bash "$WRITE_SCRIPTS/cf-workers-route-create.sh" nosuch.dev 'nosuch.dev/foo*' afi-proxy
  [ "$status" -eq 1 ]
  [[ "$output" == *"zone nosuch.dev not found"* ]]
  _assert_no_post
}

@test "cf-workers-route-create.sh exits 1 when identical route already exists" {
  cf_mock "/zones?per_page"                                              "zones.json"
  cf_mock "/zones/zone-id-culture-dev-0123456789abcdef/workers/routes?per_page" "routes_culture.json"
  # routes_culture.json contains {pattern:"culture.dev/*", script:"culture-dev-router"}.
  run bash "$WRITE_SCRIPTS/cf-workers-route-create.sh" culture.dev 'culture.dev/*' culture-dev-router
  [ "$status" -eq 1 ]
  [[ "$output" == *"Workers route already exists"* ]]
  [[ "$output" == *"culture.dev/*"* ]]
  _assert_no_post
}

@test "cf-workers-route-create.sh exits 2 when positional args missing" {
  run bash "$WRITE_SCRIPTS/cf-workers-route-create.sh" culture.dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected ZONE, PATTERN, and SCRIPT"* ]]
}

@test "cf-workers-route-create.sh exits 2 when pattern has a scheme" {
  run bash "$WRITE_SCRIPTS/cf-workers-route-create.sh" culture.dev 'https://culture.dev/afi*' afi-proxy
  [ "$status" -eq 2 ]
  [[ "$output" == *"scheme-less"* ]]
}

@test "cf-workers-route-create.sh exits 2 on invalid script name" {
  run bash "$WRITE_SCRIPTS/cf-workers-route-create.sh" culture.dev 'culture.dev/afi*' 'Bad_Name'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid script name"* ]]
}

@test "cf-workers-route-create.sh exits 2 on unknown flag" {
  run bash "$WRITE_SCRIPTS/cf-workers-route-create.sh" culture.dev 'culture.dev/afi*' afi-proxy --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}
