#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  # Every happy-path test needs at least: zones list, rulesets list, ruleset create.
  # GET URLs include `?per_page=...` via cf_api_paginated; POST is a bare path.
  # Longest-substring-wins differentiates the rulesets GET vs POST mocks
  # without teaching the stub about HTTP methods.
  WRITE_SCRIPTS="$SKILL_DIR/../cloudflare-write/scripts"
}

# Helper — asserts curl was NEVER invoked with `-X POST`.
_assert_no_post() {
  if grep -qF '	-X	POST	' "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
    echo "expected no POST, but curl.log contains one:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2
    return 1
  fi
  return 0
}

# --- dry-run (default, no --apply) ---

@test "cf-redirect-create.sh dry-run prints banner, resolved zone, and would-POST body" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  cf_mock "/rulesets?per_page"  "rulesets_empty.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev --www
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"zone-id-agentculture-org-aaaaaaaaaaaaaaaa"* ]]
  [[ "$output" == *"agentculture.org (apex + www)"* ]]
  [[ "$output" == *"https://culture.dev"* ]]
  [[ "$output" == *"**would POST**"* ]]
  [[ "$output" == *'"http_request_dynamic_redirect"'* ]]
  [[ "$output" == *'"preserve_query_string": true'* ]]
  _assert_no_post
}

@test "cf-redirect-create.sh dry-run without --www only matches apex" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  cf_mock "/rulesets?per_page"  "rulesets_empty.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev
  [ "$status" -eq 0 ]
  [[ "$output" == *'(http.host eq \"agentculture.org\")'* ]]
  [[ "$output" != *"www."* ]]
  _assert_no_post
}

@test "cf-redirect-create.sh --json dry-run emits a synthetic envelope" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  cf_mock "/rulesets?per_page"  "rulesets_empty.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev --www --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.zone_id == "zone-id-agentculture-org-aaaaaaaaaaaaaaaa"'
  echo "$output" | jq -e '.result.would_post.phase == "http_request_dynamic_redirect"'
  echo "$output" | jq -e '.result.would_post.rules[0].action_parameters.from_value.status_code == 301'
  [[ "$output" != *"Dry-run — no changes applied"* ]]
  _assert_no_post
}

# --- apply path ---

@test "cf-redirect-create.sh --apply POSTs the ruleset and reports the new id" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  cf_mock "/rulesets?per_page"  "rulesets_empty.json"
  cf_mock "/rulesets"           "ruleset_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev --www --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Redirect created**"* ]]
  [[ "$output" == *"new-ruleset-id-77777777"* ]]
  cf_assert_called "-X	POST"
  cf_assert_called "/zones/zone-id-agentculture-org-aaaaaaaaaaaaaaaa/rulesets"
}

@test "cf-redirect-create.sh --apply sends a body with apex+www expression when --www set" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  cf_mock "/rulesets?per_page"  "rulesets_empty.json"
  cf_mock "/rulesets"           "ruleset_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev --www --apply
  [ "$status" -eq 0 ]
  # curl.log captures the full argv (tab-separated). The --data-binary
  # argument contains the JSON body; we grep for the apex+www or-clause.
  grep -qF 'or (http.host eq \"www.agentculture.org\")' "$BATS_TEST_TMPDIR/curl.log"
}

@test "cf-redirect-create.sh --apply --json passes the CF response envelope through" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  cf_mock "/rulesets?per_page"  "rulesets_empty.json"
  cf_mock "/rulesets"           "ruleset_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev --www --apply --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.id == "new-ruleset-id-77777777"'
  [[ "$output" != *"Redirect created"* ]]
}

@test "cf-redirect-create.sh --status=302 overrides the default" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  cf_mock "/rulesets?per_page"  "rulesets_empty.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev --status=302
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status_code": 302'* ]]
  [[ "$output" == *"**status:** 302"* ]]
}

# --- idempotency & errors ---

@test "cf-redirect-create.sh exits 1 when a redirect ruleset already exists on the zone" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  cf_mock "/rulesets?per_page"  "rulesets_existing_redirect.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev --www --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"redirect ruleset already exists"* ]]
  [[ "$output" == *"existing-redirect-ruleset-id-0001"* ]]
  _assert_no_post
}

@test "cf-redirect-create.sh exits 1 when the FROM_HOST zone is not in the account" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" nosuch.dev culture.dev --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"zone nosuch.dev not found"* ]]
}

@test "cf-redirect-create.sh exits 2 when positional args are missing" {
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected FROM_HOST and TO_HOST"* ]]
}

@test "cf-redirect-create.sh exits 2 when only one positional arg is given" {
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected FROM_HOST and TO_HOST"* ]]
}

@test "cf-redirect-create.sh exits 2 on unknown flag" {
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-redirect-create.sh exits 2 on invalid hostname" {
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" 'has"quote' culture.dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid hostname"* ]]
}

@test "cf-redirect-create.sh exits 2 on out-of-range --status" {
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev --status=200
  [ "$status" -eq 2 ]
  [[ "$output" == *"3xx HTTP code"* ]]
}

@test "cf-redirect-create.sh accepts --status with leading zeros and normalizes to a JSON-valid int" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  cf_mock "/rulesets?per_page"  "rulesets_empty.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev --status=0302
  [ "$status" -eq 0 ]
  # Body must contain the normalized integer, NOT the leading-zero form.
  [[ "$output" == *'"status_code": 302'* ]]
  [[ "$output" != *'"status_code": 0302'* ]]
  [[ "$output" == *"**status:** 302"* ]]
}

@test "cf-redirect-create.sh exits 2 when --www is combined with a FROM_HOST starting with 'www.'" {
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" www.agentculture.org culture.dev --www
  [ "$status" -eq 2 ]
  [[ "$output" == *"--www cannot be combined"* ]]
  [[ "$output" == *"drop the 'www.' prefix"* ]]
}

@test "cf-redirect-create.sh accepts FROM_HOST starting with 'www.' WITHOUT --www" {
  # Mocks won't match this hostname (not in zones fixture) but we're only
  # verifying the pre-validation passes; the zone lookup will fail after
  # that with exit 1, which is the expected downstream behaviour.
  cf_mock "/zones?per_page"  "zones_with_agentculture.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" www.agentculture.org culture.dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"zone www.agentculture.org not found"* ]]
}

# --- zone lookup uses pagination ---

@test "cf-redirect-create.sh resolves FROM_HOST via paginated /zones" {
  cf_mock "/zones?per_page"     "zones_with_agentculture.json"
  cf_mock "/rulesets?per_page"  "rulesets_empty.json"
  run bash "$WRITE_SCRIPTS/cf-redirect-create.sh" agentculture.org culture.dev
  [ "$status" -eq 0 ]
  cf_assert_called "/zones?per_page=50&page=1"
}
