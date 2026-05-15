#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cfafi-write/scripts"
}

# Helper — asserts curl was NEVER invoked with `-X DELETE` (literal tab).
_assert_no_delete() {
  if grep -qF -- '-X	DELETE' "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
    echo "expected no DELETE, but curl.log contains one:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2
    return 1
  fi
  return 0
}

# --- usage errors ---

@test "cf-pages-domain-remove exits 2 when positional args missing" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected PROJECT and DOMAIN"* ]]
}

@test "cf-pages-domain-remove exits 2 on unknown flag" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev culture.dev --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-pages-domain-remove exits 2 on invalid project name" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" 'bad name!' culture.dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid project name"* ]]
}

@test "cf-pages-domain-remove exits 2 on invalid domain" {
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev 'not a domain!'
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid domain"* ]]
}

# --- dry-run (default, no --apply) ---

@test "cf-pages-domain-remove dry-run prints loud banner and would-DELETE, no DELETE call" {
  cf_mock "/pages/projects/culture-dev/domains?per_page" "pages_domains_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev culture.dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"will stop serving from project"* ]]
  [[ "$output" == *"**project:** culture-dev"* ]]
  [[ "$output" == *"**domain:** culture.dev"* ]]
  [[ "$output" == *"would DELETE"* ]]
  [[ "$output" == *"/pages/projects/culture-dev/domains/culture.dev"* ]]
  _assert_no_delete
}

@test "cf-pages-domain-remove --json dry-run emits synthetic envelope" {
  cf_mock "/pages/projects/culture-dev/domains?per_page" "pages_domains_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev culture.dev --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.project == "culture-dev"'
  echo "$output" | jq -e '.result.domain == "culture.dev"'
  echo "$output" | jq -e '.result.would_delete | endswith("/domains/culture.dev")'
  _assert_no_delete
}

# --- apply path ---

@test "cf-pages-domain-remove --apply DELETEs the domain" {
  cf_mock "/pages/projects/culture-dev/domains?per_page"    "pages_domains_culture_dev.json"
  cf_mock "/pages/projects/culture-dev/domains/culture.dev" "pages_domain_remove_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev culture.dev --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Custom domain removed**"* ]]
  cf_assert_called "-X	DELETE"
  cf_assert_called "/pages/projects/culture-dev/domains/culture.dev"
}

@test "cf-pages-domain-remove --apply --json passes CF response envelope through" {
  cf_mock "/pages/projects/culture-dev/domains?per_page"    "pages_domains_culture_dev.json"
  cf_mock "/pages/projects/culture-dev/domains/culture.dev" "pages_domain_remove_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" culture-dev culture.dev --apply --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  [[ "$output" != *"Custom domain removed"* ]]
}

# --- idempotency & resolution errors ---

@test "cf-pages-domain-remove exits 1 when domain not attached" {
  cf_mock "/pages/projects/katvan/domains?per_page" "pages_domains_katvan.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" katvan culture.dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"not attached"* ]]
  [[ "$output" == *"nothing to remove"* ]]
  _assert_no_delete
}

@test "cf-pages-domain-remove exits 1 when project does not exist and surfaces the CF error" {
  cf_mock "/pages/projects/nosuch/domains" "pages_project_not_found.json"
  run bash "$WRITE_SCRIPTS/cf-pages-domain-remove.sh" nosuch culture.dev
  [ "$status" -eq 1 ]
  [[ "$output" == *"Project not found"* ]]
  [[ "$output" == *"could not resolve Pages project"* ]]
  _assert_no_delete
}
