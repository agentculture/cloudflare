#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
}

# --- list mode (no project arg) ---

@test "cf-pages.sh lists projects with markdown heading and count" {
  cf_mock "/pages/projects" "pages_projects.json"
  run bash "$SKILL_SCRIPTS/cf-pages.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Pages projects (2)"* ]]
  [[ "$output" == *"| NAME | BRANCH | SUBDOMAIN | LATEST |"* ]]
  [[ "$output" == *"culture-dev-site"* ]]
  [[ "$output" == *"agentirc-dev"* ]]
  [[ "$output" == *"culture-dev-site.pages.dev"* ]]
}

@test "cf-pages.sh --json passes raw projects response through" {
  cf_mock "/pages/projects" "pages_projects.json"
  run bash "$SKILL_SCRIPTS/cf-pages.sh" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result | length == 2'
  echo "$output" | jq -e '.result | map(.name) | contains(["agentirc-dev"])'
  [[ "$output" != *"## Pages projects"* ]]
}

@test "cf-pages.sh list mode hits the account-scoped projects endpoint" {
  cf_mock "/pages/projects" "pages_projects.json"
  run bash "$SKILL_SCRIPTS/cf-pages.sh"
  [ "$status" -eq 0 ]
  cf_assert_called "/accounts/test-account-id/pages/projects"
}

# --- single-project mode (project arg) ---

@test "cf-pages.sh PROJECT lists deployments with heading and count" {
  # Specific path uniquely identifies the deployments call; the broader
  # "/pages/projects" mock matches only the bare listing call. Stub uses
  # longest-match-wins so registration order doesn't matter.
  cf_mock "/pages/projects/agentirc-dev/deployments" "pages_deployments.json"
  cf_mock "/pages/projects" "pages_projects.json"
  run bash "$SKILL_SCRIPTS/cf-pages.sh" agentirc-dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Deployments for agentirc-dev (3)"* ]]
  [[ "$output" == *"| SHORT_ID | ENV | BRANCH | STATUS | CREATED |"* ]]
  [[ "$output" == *"7777ffff"* ]]
  [[ "$output" == *"production"* ]]
  [[ "$output" == *"preview"* ]]
  [[ "$output" == *"success"* ]]
}

@test "cf-pages.sh PROJECT hits the deployments endpoint for that project" {
  cf_mock "/pages/projects/agentirc-dev/deployments" "pages_deployments.json"
  cf_mock "/pages/projects" "pages_projects.json"
  run bash "$SKILL_SCRIPTS/cf-pages.sh" agentirc-dev
  [ "$status" -eq 0 ]
  cf_assert_called "/accounts/test-account-id/pages/projects/agentirc-dev/deployments"
}

@test "cf-pages.sh PROJECT --json passes raw deployments response through" {
  cf_mock "/pages/projects/agentirc-dev/deployments" "pages_deployments.json"
  cf_mock "/pages/projects" "pages_projects.json"
  run bash "$SKILL_SCRIPTS/cf-pages.sh" agentirc-dev --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result | length == 3'
  [[ "$output" != *"## Deployments"* ]]
}

# --- errors ---

@test "cf-pages.sh exits 1 when CLOUDFLARE_ACCOUNT_ID is unset" {
  unset CLOUDFLARE_ACCOUNT_ID
  run bash "$SKILL_SCRIPTS/cf-pages.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLOUDFLARE_ACCOUNT_ID not set"* ]]
}

@test "cf-pages.sh exits 2 on unknown flag" {
  run bash "$SKILL_SCRIPTS/cf-pages.sh" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-pages.sh exits 2 on extra positional argument" {
  run bash "$SKILL_SCRIPTS/cf-pages.sh" project-a project-b
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected extra argument"* ]]
}

@test "cf-pages.sh URL-encodes the project argument so '/' cannot alter the path" {
  cf_mock "/pages/projects/agentirc-dev/deployments" "pages_deployments.json"
  cf_mock "/pages/projects" "pages_projects.json"
  run bash "$SKILL_SCRIPTS/cf-pages.sh" 'has/slash'
  # Slash must be encoded as %2F so it stays in the project segment
  cf_assert_called "/pages/projects/has%2Fslash/deployments"
}
