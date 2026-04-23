#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cloudflare-write/scripts"
  # Minimal worker source used across tests. Content is irrelevant
  # for the curl-stub harness — it only shows up in the source
  # preview (markdown mode) and in --from-file byte-count reporting.
  WORKER_SRC="$BATS_TEST_TMPDIR/worker.js"
  cat > "$WORKER_SRC" <<'EOF'
// test worker
export default { async fetch(req) { return new Response("hi"); } };
EOF
}

_assert_no_mutation() {
  # No -X POST, -X PUT, or -X DELETE should have been issued.
  for method in POST PUT DELETE; do
    if grep -qF -- "-X	$method" "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
      echo "expected no $method, but curl.log contains one:" >&2
      cat "$BATS_TEST_TMPDIR/curl.log" >&2
      return 1
    fi
  done
  return 0
}

# --- dry-run (default, no --apply) ---

@test "cf-worker-create.sh dry-run prints metadata + source preview" {
  cf_mock "/workers/scripts?per_page" "workers_scripts_empty.json"
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy \
    --from-file="$WORKER_SRC" --compatibility-date=2026-04-20
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"**name:** afi-proxy"* ]]
  [[ "$output" == *"**format:** module"* ]]
  [[ "$output" == *"**compatibility_date:** 2026-04-20"* ]]
  [[ "$output" == *'"main_module": "worker.js"'* ]]
  [[ "$output" == *"would PUT"* ]]
  [[ "$output" == *"test worker"* ]]
  _assert_no_mutation
}

@test "cf-worker-create.sh dry-run --json emits synthetic envelope" {
  cf_mock "/workers/scripts?per_page" "workers_scripts_empty.json"
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy \
    --from-file="$WORKER_SRC" --compatibility-date=2026-04-20 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.name == "afi-proxy"'
  echo "$output" | jq -e '.result.format == "module"'
  echo "$output" | jq -e '.result.would_put.metadata.main_module == "worker.js"'
  echo "$output" | jq -e '.result.would_put.metadata.compatibility_date == "2026-04-20"'
  [[ "$output" != *"Dry-run — no changes applied"* ]]
  _assert_no_mutation
}

@test "cf-worker-create.sh --service-worker changes metadata and content-type" {
  cf_mock "/workers/scripts?per_page" "workers_scripts_empty.json"
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" my-worker \
    --from-file="$WORKER_SRC" --service-worker \
    --compatibility-date=2026-04-20 --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.format == "service-worker"'
  echo "$output" | jq -e '.result.would_put.metadata.body_part == "script"'
  echo "$output" | jq -e '.result.would_put.metadata | has("main_module") | not'
}

# --- apply ---

@test "cf-worker-create.sh --apply PUTs the script, enables workers.dev, reports etag" {
  cf_mock "/workers/scripts?per_page"               "workers_scripts_empty.json"
  cf_mock "/workers/scripts/afi-proxy"              "workers_script_create_ok.json"
  cf_mock "/workers/scripts/afi-proxy/subdomain"    "workers_script_subdomain_enabled.json"
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy \
    --from-file="$WORKER_SRC" --compatibility-date=2026-04-20 --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Worker uploaded**"* ]]
  [[ "$output" == *"test-etag-afi-proxy-12345"* ]]
  [[ "$output" == *"**workers_dev_enabled:** true"* ]]
  cf_assert_called "-X	PUT"
  cf_assert_called "/accounts/test-account-id/workers/scripts/afi-proxy"
  cf_assert_called "/accounts/test-account-id/workers/scripts/afi-proxy/subdomain"
  # Multipart parts — -F flags are present with the filename override
  # that forces CF to match main_module by filename, not by source path.
  cf_assert_called "metadata=@"
  cf_assert_called "worker.js=@"
  cf_assert_called "application/javascript+module"
  cf_assert_called ";filename=worker.js"
}

@test "cf-worker-create.sh --apply --json merges upload + subdomain envelopes" {
  cf_mock "/workers/scripts?per_page"            "workers_scripts_empty.json"
  cf_mock "/workers/scripts/afi-proxy"           "workers_script_create_ok.json"
  cf_mock "/workers/scripts/afi-proxy/subdomain" "workers_script_subdomain_enabled.json"
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy \
    --from-file="$WORKER_SRC" --apply --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.upload.id == "afi-proxy"'
  echo "$output" | jq -e '.result.upload.etag == "test-etag-afi-proxy-12345"'
  echo "$output" | jq -e '.result.subdomain.enabled == true'
}

@test "cf-worker-create.sh --apply --no-workers-dev sets subdomain disabled" {
  cf_mock "/workers/scripts?per_page"            "workers_scripts_empty.json"
  cf_mock "/workers/scripts/afi-proxy"           "workers_script_create_ok.json"
  cf_mock "/workers/scripts/afi-proxy/subdomain" "workers_script_subdomain_disabled.json"
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy \
    --from-file="$WORKER_SRC" --apply --no-workers-dev --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.result.subdomain.enabled == false'
  # The request body must carry `enabled: false` — grep the curl log
  # (jq's default output uses ": " with a space, not the compact form).
  grep -qE '"enabled":[[:space:]]*false' "$BATS_TEST_TMPDIR/curl.log" \
    || { echo "expected enabled:false in PUT body, curl log:" >&2; cat "$BATS_TEST_TMPDIR/curl.log" >&2; return 1; }
}

# --- idempotency & validation ---

@test "cf-worker-create.sh exits 1 when a worker with NAME already exists" {
  cf_mock "/workers/scripts?per_page" "workers_scripts_with_afi_proxy.json"
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy --from-file="$WORKER_SRC"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists in account"* ]]
  [[ "$output" == *"afi-proxy"* ]]
  _assert_no_mutation
}

@test "cf-worker-create.sh exits 2 when positional NAME is missing" {
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" --from-file="$WORKER_SRC"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected NAME"* ]]
}

@test "cf-worker-create.sh exits 2 when --from-file is missing" {
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy
  [ "$status" -eq 2 ]
  [[ "$output" == *"--from-file=PATH is required"* ]]
}

@test "cf-worker-create.sh exits 1 when --from-file target does not exist" {
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy \
    --from-file=/nonexistent/path/to/worker.js
  [ "$status" -eq 1 ]
  [[ "$output" == *"--from-file not found"* ]]
}

@test "cf-worker-create.sh exits 2 on invalid worker name (uppercase)" {
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" AfiProxy --from-file="$WORKER_SRC"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid worker name"* ]]
}

@test "cf-worker-create.sh exits 2 on malformed --compatibility-date" {
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy \
    --from-file="$WORKER_SRC" --compatibility-date=20260420
  [ "$status" -eq 2 ]
  [[ "$output" == *"YYYY-MM-DD"* ]]
}

@test "cf-worker-create.sh exits 2 on unknown flag" {
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy \
    --from-file="$WORKER_SRC" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-worker-create.sh exits 2 when both --module and --service-worker are given" {
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy \
    --from-file="$WORKER_SRC" --module --service-worker
  [ "$status" -eq 2 ]
  [[ "$output" == *"mutually exclusive"* ]]
}

@test "cf-worker-create.sh --service-worker --apply sends part named 'script'" {
  cf_mock "/workers/scripts?per_page"            "workers_scripts_empty.json"
  cf_mock "/workers/scripts/my-worker"           "workers_script_create_ok.json"
  cf_mock "/workers/scripts/my-worker/subdomain" "workers_script_subdomain_enabled.json"
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" my-worker \
    --from-file="$WORKER_SRC" --service-worker --apply
  [ "$status" -eq 0 ]
  # metadata.body_part="script" — the multipart part MUST be named
  # "script" with filename="script", not "worker.js". Otherwise CF
  # rejects with a module-not-found error (service-worker format).
  cf_assert_called "script=@"
  cf_assert_called "application/javascript"
  cf_assert_called ";filename=script"
  # Negative: the old bug (always sending worker.js) must not regress.
  if grep -qF 'worker.js=@' "$BATS_TEST_TMPDIR/curl.log"; then
    echo "--service-worker leaked worker.js=@ form field; curl log:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2
    return 1
  fi
}

@test "cf-worker-create.sh uses today's date when --compatibility-date omitted" {
  cf_mock "/workers/scripts?per_page" "workers_scripts_empty.json"
  run bash "$WRITE_SCRIPTS/cf-worker-create.sh" afi-proxy \
    --from-file="$WORKER_SRC" --json
  [ "$status" -eq 0 ]
  # Today-in-UTC format — check it's a plausible 2026 date, not a
  # hard-coded string (tests shouldn't break on the next UTC tick).
  echo "$output" | jq -e '.result.would_put.metadata.compatibility_date | test("^20[0-9][0-9]-[0-9]{2}-[0-9]{2}$")'
}
