# Shared setup for bats tests. Load with `load test_helper` from any .bats file.

cf_bats_setup() {
  export CLOUDFLARE_API_TOKEN="test-token-placeholder"
  export CLOUDFLARE_ACCOUNT_ID="test-account-id"
  export CF_SKIP_ENV=1
  export CF_API_BASE="https://mock.cloudflare.test/client/v4"
  export CF_FIXTURES_DIR="$BATS_TEST_DIRNAME/../fixtures"

  # Put stub curl first on PATH so it wins the lookup.
  export PATH="$BATS_TEST_DIRNAME/stubs:$PATH"

  : > "$BATS_TEST_TMPDIR/curl.log"
  : > "$BATS_TEST_TMPDIR/mocks.txt"

  # Paths the tests reach into, exposed as globals for brevity in @test blocks.
  # shellcheck disable=SC2034  # consumed by bats files that `load test_helper`
  SKILL_DIR="$BATS_TEST_DIRNAME/../../.claude/skills/cfafi"
  # shellcheck disable=SC2034  # consumed by bats files that `load test_helper`
  SKILL_SCRIPTS="$SKILL_DIR/scripts"
  return 0
}

# cf_mock URL_SUBSTRING FIXTURE_FILE
cf_mock() {
  local pattern="$1"
  local fixture="$2"
  printf '%s\t%s\n' "$pattern" "$fixture" >> "$BATS_TEST_TMPDIR/mocks.txt"
  return 0
}

cf_assert_called() {
  local pattern="$1"
  # `--` separator so patterns starting with `-` (e.g. `-X\tPOST`) aren't
  # parsed as grep flags.
  if ! grep -qF -- "$pattern" "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
    echo "expected curl invocation matching '$pattern', got:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2 || true
    return 1
  fi
  return 0
}
