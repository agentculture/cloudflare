#!/usr/bin/env bats
# Unit tests for .claude/skills/cloudflare/scripts/_lib.sh

load test_helper

setup() {
  cf_bats_setup
}

@test "_lib.sh exits with clear message when CLOUDFLARE_API_TOKEN is unset" {
  unset CLOUDFLARE_API_TOKEN
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLOUDFLARE_API_TOKEN not set"* ]]
}

@test "cf_api returns raw JSON on success:true" {
  cf_mock "/user/tokens/verify" "token_verify.json"
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_api /user/tokens/verify"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
}

@test "cf_api sends Authorization header with bearer token" {
  cf_mock "/user/tokens/verify" "token_verify.json"
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_api /user/tokens/verify"
  [ "$status" -eq 0 ]
  cf_assert_called "Authorization: Bearer test-token-placeholder"
}

@test "cf_api targets CF_API_BASE + path" {
  cf_mock "/zones" "token_verify.json"
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_api /zones"
  [ "$status" -eq 0 ]
  cf_assert_called "https://mock.cloudflare.test/client/v4/zones"
}

@test "cf_api exits 1 when API responds success:false" {
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_api /missing"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CloudFlare API request failed"* ]]
}

@test "cf_output json mode passes raw JSON through unchanged" {
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_output '{\"a\":1}' json '.a'"
  [ "$status" -eq 0 ]
  [ "$output" = '{"a":1}' ]
}

@test "cf_output md mode renders a markdown table with header + separator" {
  local json='[{"name":"culture.dev","status":"active"},{"name":"agentirc.dev","status":"active"}]'
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_output '$json' md '.[] | [.name, .status] | @tsv' \"\$(printf 'NAME\tSTATUS')\""
  [ "$status" -eq 0 ]
  # Header row
  [[ "$output" == *"| NAME | STATUS |"* ]]
  # Separator row
  [[ "$output" == *"| --- | --- |"* ]]
  # Data rows
  [[ "$output" == *"| culture.dev | active |"* ]]
  [[ "$output" == *"| agentirc.dev | active |"* ]]
}

@test "cf_output md mode with no header still renders rows" {
  local json='[{"name":"foo"}]'
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_output '$json' md '.[] | [.name] | @tsv'"
  [ "$status" -eq 0 ]
  [[ "$output" == "| foo |" ]]
}

@test "cf_output exits on unknown mode" {
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_output '{}' csv '.' ''"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown mode"* ]]
}

@test "cf_output_kv md mode renders markdown key-value list" {
  local json='{"status":"active","id":"abc"}'
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_output_kv '$json' md '[[\"id\", .id], [\"status\", .status]] | .[] | @tsv'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"- **id:** abc"* ]]
  [[ "$output" == *"- **status:** active"* ]]
}

@test "cf_output_kv json mode passes raw JSON through" {
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_output_kv '{\"a\":1}' json '.'"
  [ "$status" -eq 0 ]
  [ "$output" = '{"a":1}' ]
}

@test "cf_require_account_id exits 1 when CLOUDFLARE_ACCOUNT_ID is unset" {
  unset CLOUDFLARE_ACCOUNT_ID
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_require_account_id"
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLOUDFLARE_ACCOUNT_ID not set"* ]]
}

@test "cf_require_account_id is silent when account id is set" {
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_require_account_id"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- cf_load_env: safe KEY=VALUE parser ---

@test "cf_load_env parses KEY=VALUE into exported env vars (bare, double, single quotes)" {
  local env_file="$BATS_TEST_TMPDIR/test.env"
  printf 'CF_TEST_BARE=hello\nCF_TEST_QUOTED="quoted value"\nCF_TEST_SINGLE='"'"'single'"'"'\n' > "$env_file"
  unset CF_SKIP_ENV
  run bash -c "export CF_ENV_FILE='$env_file'; source '$SKILL_SCRIPTS/_lib.sh' && printf '%s|%s|%s\n' \"\$CF_TEST_BARE\" \"\$CF_TEST_QUOTED\" \"\$CF_TEST_SINGLE\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"hello|quoted value|single"* ]]
}

@test "cf_load_env tolerates leading 'export ' on assignments" {
  local env_file="$BATS_TEST_TMPDIR/test.env"
  printf 'export CF_TEST_EXPORTED=yes\n' > "$env_file"
  unset CF_SKIP_ENV
  run bash -c "export CF_ENV_FILE='$env_file'; source '$SKILL_SCRIPTS/_lib.sh' && printf '%s\n' \"\$CF_TEST_EXPORTED\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"yes"* ]]
}

@test "cf_load_env skips comments and blank lines" {
  local env_file="$BATS_TEST_TMPDIR/test.env"
  printf '# top comment\n\nCF_TEST_SET=ok\n   # indented comment\n\n' > "$env_file"
  unset CF_SKIP_ENV
  run bash -c "export CF_ENV_FILE='$env_file'; source '$SKILL_SCRIPTS/_lib.sh' && printf '%s\n' \"\$CF_TEST_SET\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok"* ]]
}

@test "cf_load_env warns on malformed lines but keeps parsing" {
  local env_file="$BATS_TEST_TMPDIR/test.env"
  printf 'this is not a valid assignment\nCF_TEST_AFTER=still_parsed\n' > "$env_file"
  unset CF_SKIP_ENV
  run bash -c "export CF_ENV_FILE='$env_file'; source '$SKILL_SCRIPTS/_lib.sh' && printf '%s\n' \"\$CF_TEST_AFTER\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"ignoring malformed line"* ]]
  [[ "$output" == *"still_parsed"* ]]
}

@test "cf_load_env does NOT execute shell code in .env (security regression)" {
  local env_file="$BATS_TEST_TMPDIR/test.env"
  local evidence="$BATS_TEST_TMPDIR/pwned.txt"
  # If the old `source` behaviour returned, this line would create pwned.txt.
  printf '$(touch %q)\nCF_TEST_SAFE=ok\n' "$evidence" > "$env_file"
  unset CF_SKIP_ENV
  run bash -c "export CF_ENV_FILE='$env_file'; source '$SKILL_SCRIPTS/_lib.sh' && printf '%s\n' \"\$CF_TEST_SAFE\""
  [ "$status" -eq 0 ]
  [ ! -e "$evidence" ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"ok"* ]]
}

# --- cf_output: markdown cell escaping ---

@test "cf_output md mode escapes '|' inside cell values" {
  local json='[{"name":"rec","content":"v=spf1 include:_spf.example.com -all | legacy"}]'
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_output '$json' md '.[] | [.name, .content] | @tsv' \"\$(printf 'NAME\tCONTENT')\""
  [ "$status" -eq 0 ]
  # Data pipe escaped as '\|'; structural pipes around cells still present
  [[ "$output" == *"\\|"* ]]
  [[ "$output" == *"| NAME | CONTENT |"* ]]
}

# --- cf_api_paginated: walk total_pages ---

@test "cf_api_paginated concatenates .result across all pages" {
  cf_mock "&page=1" "paginated_page1.json"
  cf_mock "&page=2" "paginated_page2.json"
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_api_paginated /zones"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result | length == 3'
  echo "$output" | jq -e '.result | map(.name) | . == ["alpha","bravo","charlie"]'
}

@test "cf_api_paginated issues one request per page (follows total_pages)" {
  cf_mock "&page=1" "paginated_page1.json"
  cf_mock "&page=2" "paginated_page2.json"
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_api_paginated /zones"
  [ "$status" -eq 0 ]
  cf_assert_called "per_page=50&page=1"
  cf_assert_called "per_page=50&page=2"
}

@test "cf_api_paginated stops after page 1 when total_pages is 1" {
  cf_mock "/zones" "zones.json"
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_api_paginated /zones"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result | length == 2'
  cf_assert_called "per_page=50&page=1"
  run grep -F "page=2" "$BATS_TEST_TMPDIR/curl.log"
  [ "$status" -ne 0 ]
}

@test "cf_api_paginated appends &per_page=... when path already has a query string" {
  cf_mock "/zones?name=" "zone_lookup.json"
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_api_paginated '/zones?name=culture.dev'"
  [ "$status" -eq 0 ]
  cf_assert_called "/zones?name=culture.dev&per_page=50&page=1"
}

@test "cf_api_paginated returns synthetic result_info (page=1 total_pages=1 count=sum)" {
  cf_mock "&page=1" "paginated_page1.json"
  cf_mock "&page=2" "paginated_page2.json"
  run bash -c "source '$SKILL_SCRIPTS/_lib.sh' && cf_api_paginated /zones"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result_info.page == 1'
  echo "$output" | jq -e '.result_info.total_pages == 1'
  echo "$output" | jq -e '.result_info.count == 3'
  echo "$output" | jq -e '.result_info.total_count == 3'
}

@test "cf_api_paginated honors CF_PAGE_SIZE env var" {
  cf_mock "/zones" "zones.json"
  run bash -c "export CF_PAGE_SIZE=25; source '$SKILL_SCRIPTS/_lib.sh' && cf_api_paginated /zones"
  [ "$status" -eq 0 ]
  cf_assert_called "per_page=25&page=1"
}
