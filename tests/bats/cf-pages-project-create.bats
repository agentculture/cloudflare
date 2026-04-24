#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cfafi-write/scripts"
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

@test "cf-pages-project-create.sh dry-run prints banner, source summary, and would-POST body" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"**name:** culture"* ]]
  [[ "$output" == *"**source:** github:agentculture/culture"* ]]
  [[ "$output" == *"**production_branch:** main"* ]]
  [[ "$output" == *"**would POST**"* ]]
  [[ "$output" == *'"type": "github"'* ]]
  [[ "$output" == *'"owner": "agentculture"'* ]]
  [[ "$output" == *'"repo_name": "culture"'* ]]
  _assert_no_post
}

@test "cf-pages-project-create.sh dry-run --json emits synthetic envelope" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.account_id == "test-account-id"'
  echo "$output" | jq -e '.result.would_post.name == "culture"'
  echo "$output" | jq -e '.result.would_post.source.config.owner == "agentculture"'
  echo "$output" | jq -e '.result.would_post.source.config.repo_name == "culture"'
  echo "$output" | jq -e '.result.would_post.source.config.preview_deployment_setting == "all"'
  [[ "$output" != *"Dry-run — no changes applied"* ]]
  _assert_no_post
}

# --- --clone-from ---

@test "cf-pages-project-create.sh --clone-from lifts build_config and compatibility_date" {
  cf_mock "/pages/projects?per_page"        "pages_projects_with_culture_dev.json"
  cf_mock "/pages/projects/culture-dev"     "pages_project_culture_dev_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture \
    --clone-from=culture-dev --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.would_post.build_config.build_command | contains("jekyll build")'
  echo "$output" | jq -e '.result.would_post.build_config.destination_dir == "_site_culture"'
  echo "$output" | jq -e '.result.would_post.build_config.root_dir == ""'
  echo "$output" | jq -e '.result.would_post.deployment_configs.production.compatibility_date == "2026-04-10"'
  echo "$output" | jq -e '.result.would_post.deployment_configs.preview.compatibility_date == "2026-04-10"'
  echo "$output" | jq -e '.result.would_post.deployment_configs.production.build_image_major_version == 3'
}

@test "cf-pages-project-create.sh explicit --build-command overrides --clone-from" {
  cf_mock "/pages/projects?per_page"        "pages_projects_with_culture_dev.json"
  cf_mock "/pages/projects/culture-dev"     "pages_project_culture_dev_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture \
    --clone-from=culture-dev --build-command="echo override" --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.would_post.build_config.build_command == "echo override"'
  # Other cloned fields still present.
  echo "$output" | jq -e '.result.would_post.build_config.destination_dir == "_site_culture"'
}

@test "cf-pages-project-create.sh exits 1 when --clone-from target does not exist" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture \
    --clone-from=nosuch-project
  [ "$status" -eq 1 ]
  [[ "$output" == *"--clone-from project 'nosuch-project' not found"* ]]
  _assert_no_post
}

# --- apply path ---

@test "cf-pages-project-create.sh --apply POSTs the project body and reports new id" {
  cf_mock "/pages/projects?per_page"    "pages_projects_with_culture_dev.json"
  cf_mock "/pages/projects/culture-dev" "pages_project_culture_dev_detail.json"
  cf_mock "/pages/projects"             "pages_project_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture \
    --clone-from=culture-dev --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Pages project created**"* ]]
  [[ "$output" == *"proj-id-culture-new-99999999"* ]]
  [[ "$output" == *"https://culture.pages.dev"* ]]
  cf_assert_called "-X	POST"
  cf_assert_called "/accounts/test-account-id/pages/projects"
}

@test "cf-pages-project-create.sh --apply --json passes CF response envelope through" {
  cf_mock "/pages/projects?per_page"    "pages_projects_with_culture_dev.json"
  cf_mock "/pages/projects/culture-dev" "pages_project_culture_dev_detail.json"
  cf_mock "/pages/projects"             "pages_project_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture \
    --clone-from=culture-dev --apply --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.id == "proj-id-culture-new-99999999"'
  echo "$output" | jq -e '.result.subdomain == "culture.pages.dev"'
  [[ "$output" != *"Pages project created"* ]]
}

@test "cf-pages-project-create.sh --apply sends the resolved build_command in the request body" {
  cf_mock "/pages/projects?per_page"    "pages_projects_with_culture_dev.json"
  cf_mock "/pages/projects/culture-dev" "pages_project_culture_dev_detail.json"
  cf_mock "/pages/projects"             "pages_project_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture \
    --clone-from=culture-dev --apply
  [ "$status" -eq 0 ]
  # curl.log captures the full argv tab-separated. The --data-binary
  # argument contains the JSON body; grep for the cloned build command.
  grep -qF 'bundle exec jekyll build --config _config.base.yml,_config.culture.yml -d _site_culture' \
    "$BATS_TEST_TMPDIR/curl.log"
}

# --- idempotency & errors ---

@test "cf-pages-project-create.sh exits 1 when a project with NAME already exists" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists in this account"* ]]
  [[ "$output" == *"proj-id-culture-already-exists"* ]]
  _assert_no_post
}

@test "cf-pages-project-create.sh exits 2 when positional args are missing" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected NAME, GITHUB_OWNER, and REPO_NAME"* ]]
}

@test "cf-pages-project-create.sh exits 2 with only two positional args" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected NAME, GITHUB_OWNER, and REPO_NAME"* ]]
}

@test "cf-pages-project-create.sh exits 2 on unknown flag" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-pages-project-create.sh exits 2 on invalid project name (uppercase)" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" Culture agentculture culture
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid project name"* ]]
}

@test "cf-pages-project-create.sh exits 2 on invalid project name (leading hyphen)" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" -culture agentculture culture
  [ "$status" -eq 2 ]
  # Leading hyphen gets parsed as unknown flag before the name check
  # fires — either outcome is a usage error we want to surface.
  [[ "$output" == *"unknown flag"* || "$output" == *"invalid project name"* ]]
}

@test "cf-pages-project-create.sh exits 2 on invalid github owner" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture 'bad owner' culture
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid GitHub identifier"* ]]
}

@test "cf-pages-project-create.sh exits 2 on malformed --compatibility-date" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture \
    --compatibility-date=2026/04/22
  [ "$status" -eq 2 ]
  [[ "$output" == *"YYYY-MM-DD"* ]]
}

@test "cf-pages-project-create.sh exits 2 on --build-image-version out of range" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture \
    --build-image-version=99
  [ "$status" -eq 2 ]
  [[ "$output" == *"must be 1, 2, or 3"* ]]
}

# --- overrides without --clone-from ---

@test "cf-pages-project-create.sh without --clone-from uses built-in defaults" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.would_post.production_branch == "main"'
  echo "$output" | jq -e '.result.would_post.build_config.build_command == ""'
  echo "$output" | jq -e '.result.would_post.build_config.root_dir == ""'
  echo "$output" | jq -e '.result.would_post.deployment_configs.production.build_image_major_version == 3'
  # No compatibility_date set → field omitted entirely, not emitted as ""
  echo "$output" | jq -e '.result.would_post.deployment_configs.production | has("compatibility_date") | not'
}

@test "cf-pages-project-create.sh explicit empty --build-command clears cloned value" {
  cf_mock "/pages/projects?per_page"    "pages_projects_with_culture_dev.json"
  cf_mock "/pages/projects/culture-dev" "pages_project_culture_dev_detail.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture \
    --clone-from=culture-dev --build-command= --json
  [ "$status" -eq 0 ]
  # Explicit empty flag must beat the cloned build_command — otherwise
  # users can't unset a cloned value short of editing the clone source.
  echo "$output" | jq -e '.result.would_post.build_config.build_command == ""'
  # Other cloned fields still inherited.
  echo "$output" | jq -e '.result.would_post.build_config.destination_dir == "_site_culture"'
}

@test "cf-pages-project-create.sh --production-branch overrides default" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" culture agentculture culture \
    --production-branch=develop --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.would_post.production_branch == "develop"'
  echo "$output" | jq -e '.result.would_post.source.config.production_branch == "develop"'
}

# --- --direct-upload ---

@test "cf-pages-project-create.sh --direct-upload dry-run omits source and reports direct_upload" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" afi --direct-upload \
    --compatibility-date=2026-04-20
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"**name:** afi"* ]]
  [[ "$output" == *"**source:** direct_upload"* ]]
  [[ "$output" != *'"type": "github"'* ]]
  [[ "$output" != *'"source":'* ]]
  _assert_no_post
}

@test "cf-pages-project-create.sh --direct-upload --json has no source key" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" afi --direct-upload --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.would_post.name == "afi"'
  echo "$output" | jq -e '.result.would_post | has("source") | not'
  echo "$output" | jq -e '.result.would_post.production_branch == "main"'
  _assert_no_post
}

@test "cf-pages-project-create.sh --direct-upload rejects extra positional args" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" afi agentculture afi-cli --direct-upload
  [ "$status" -eq 2 ]
  [[ "$output" == *"--direct-upload takes exactly one positional arg"* ]]
}

@test "cf-pages-project-create.sh --direct-upload requires NAME" {
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" --direct-upload
  [ "$status" -eq 2 ]
  [[ "$output" == *"--direct-upload takes exactly one positional arg"* ]]
}

@test "cf-pages-project-create.sh --direct-upload --apply POSTs source-less body" {
  cf_mock "/pages/projects?per_page" "pages_projects_with_culture_dev.json"
  cf_mock "/pages/projects"          "pages_project_create_direct_upload_ok.json"
  run bash "$WRITE_SCRIPTS/cf-pages-project-create.sh" afi --direct-upload \
    --compatibility-date=2026-04-20 --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Pages project created**"* ]]
  [[ "$output" == *"proj-id-afi-new-12345678"* ]]
  [[ "$output" == *"https://afi.pages.dev"* ]]
  cf_assert_called "-X	POST"
  cf_assert_called "/accounts/test-account-id/pages/projects"
  # The request body must not contain a source field — grep the full
  # curl.log for "source" and confirm it's absent.
  if grep -F '"source"' "$BATS_TEST_TMPDIR/curl.log"; then
    echo "--direct-upload must not include source field in POST body" >&2
    return 1
  fi
}
