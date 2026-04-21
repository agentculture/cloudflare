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
