#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cfafi-write/scripts"
}

# Helper — asserts curl was NEVER invoked with `-X POST` (literal tabs).
_assert_no_post() {
  if grep -qF '	-X	POST	' "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
    echo "expected no POST, but curl.log contains one:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2
    return 1
  fi
  return 0
}

# --- usage errors ---

@test "cf-pages-domain-add exits 2 when positional args missing" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected PROJECT and DOMAIN"* ]]
}

@test "cf-pages-domain-add exits 2 with only one positional arg" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected PROJECT and DOMAIN"* ]]
}

@test "cf-pages-domain-add exits 2 on unknown flag" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan culture.dev --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-pages-domain-add exits 2 on invalid project name" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" 'bad name!' culture.dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid project name"* ]]
}

@test "cf-pages-domain-add exits 2 on invalid domain" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan 'not a domain!'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid domain"* ]]
}

# --- dry-run (default, no --apply) ---

@test "cf-pages-domain-add dry-run prints banner and would-POST body, no POST call" {
  cf_mock "/pages/projects/katvan/domains?per_page" "pages_domains_katvan.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan culture.dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"**project:** katvan"* ]]
  [[ "$output" == *"**domain:** culture.dev"* ]]
  [[ "$output" == *"**would POST**"* ]]
  [[ "$output" == *'"name": "culture.dev"'* ]]
  _assert_no_post
}

@test "cf-pages-domain-add --json dry-run emits synthetic envelope" {
  cf_mock "/pages/projects/katvan/domains?per_page" "pages_domains_katvan.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan culture.dev --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.project == "katvan"'
  echo "$output" | jq -e '.result.domain == "culture.dev"'
  echo "$output" | jq -e '.result.would_post.name == "culture.dev"'
  [[ "$output" != *"Dry-run — no changes applied"* ]]
  _assert_no_post
}

# --- apply path ---

@test "cf-pages-domain-add --apply POSTs the domain body and reports status" {
  cf_mock "/pages/projects/katvan/domains?per_page" "pages_domains_katvan.json"
  cf_mock "/pages/projects/katvan/domains"          "pages_domain_add_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan culture.dev --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Custom domain added**"* ]]
  [[ "$output" == *"**status:** pending"* ]]
  cf_assert_called "-X	POST"
  cf_assert_called "/accounts/test-account-id/pages/projects/katvan/domains"
}

@test "cf-pages-domain-add --apply --json passes CF response envelope through" {
  cf_mock "/pages/projects/katvan/domains?per_page" "pages_domains_katvan.json"
  cf_mock "/pages/projects/katvan/domains"          "pages_domain_add_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" katvan culture.dev --apply --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.name == "culture.dev"'
  [[ "$output" != *"Custom domain added"* ]]
}

# --- idempotency & resolution errors ---

@test "cf-pages-domain-add exits 1 when domain already attached" {
  cf_mock "/pages/projects/culture-dev/domains?per_page" "pages_domains_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" culture-dev culture.dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"already attached"* ]]
  _assert_no_post
}

@test "cf-pages-domain-add exits 1 when project does not exist and surfaces the CF error" {
  cf_mock "/pages/projects/nosuch/domains" "pages_project_not_found.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-add.sh" nosuch culture.dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"Project not found"* ]]
  [[ "$output" == *"could not resolve Pages project"* ]]
  _assert_no_post
}
