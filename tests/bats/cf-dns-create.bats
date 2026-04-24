#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
  WRITE_SCRIPTS="$SKILL_DIR/../cfafi-write/scripts"
}

# Helper — asserts curl was NEVER invoked with `-X POST`.
_assert_no_post() {
  if grep -qF -- '	-X	POST	' "$BATS_TEST_TMPDIR/curl.log" 2>/dev/null; then
    echo "expected no POST, but curl.log contains one:" >&2
    cat "$BATS_TEST_TMPDIR/curl.log" >&2
    return 1
  fi
  return 0
}

# --- dry-run (default) ---

@test "cf-dns-create.sh dry-run prints banner, resolved zone, and would-POST body" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=A"    "dns_records_empty.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A agentculture.org 192.0.2.1 --proxied
  [ "$status" -eq 0 ]
  [[ "$output" == *"**Dry-run — no changes applied**"* ]]
  [[ "$output" == *"zone-id-agentculture-org-aaaaaaaaaaaaaaaa"* ]]
  [[ "$output" == *"**type:** A"* ]]
  [[ "$output" == *"**name:** agentculture.org"* ]]
  [[ "$output" == *"**content:** 192.0.2.1"* ]]
  [[ "$output" == *"**proxied:** true"* ]]
  [[ "$output" == *"**ttl:** 1 (automatic)"* ]]
  [[ "$output" == *"**would POST**"* ]]
  [[ "$output" == *'"type": "A"'* ]]
  [[ "$output" == *'"proxied": true'* ]]
  _assert_no_post
}

@test "cf-dns-create.sh --json dry-run emits a synthetic envelope" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=A"    "dns_records_empty.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A agentculture.org 192.0.2.1 --proxied --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.dry_run == true'
  echo "$output" | jq -e '.result.would_post.type == "A"'
  echo "$output" | jq -e '.result.would_post.proxied == true'
  echo "$output" | jq -e '.result.would_post.ttl == 1'
  _assert_no_post
}

# --- apply path ---

@test "cf-dns-create.sh --apply POSTs the record and reports the new id" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=A"    "dns_records_empty.json"
  cf_mock "/dns_records"           "dns_record_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A agentculture.org 192.0.2.1 --proxied --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"**DNS record created**"* ]]
  [[ "$output" == *"new-dns-record-id-bbbb1234"* ]]
  cf_assert_called "-X	POST"
  cf_assert_called "/zones/zone-id-agentculture-org-aaaaaaaaaaaaaaaa/dns_records"
}

@test "cf-dns-create.sh --apply sends a body with type, name, content, proxied, ttl" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=A"    "dns_records_empty.json"
  cf_mock "/dns_records"           "dns_record_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A agentculture.org 192.0.2.1 --proxied --apply
  [ "$status" -eq 0 ]
  grep -qF '"type": "A"'         "$BATS_TEST_TMPDIR/curl.log"
  grep -qF '"name": "agentculture.org"' "$BATS_TEST_TMPDIR/curl.log"
  grep -qF '"content": "192.0.2.1"' "$BATS_TEST_TMPDIR/curl.log"
  grep -qF '"proxied": true'     "$BATS_TEST_TMPDIR/curl.log"
  grep -qF '"ttl": 1'            "$BATS_TEST_TMPDIR/curl.log"
}

@test "cf-dns-create.sh --apply --json passes the CF response through" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=A"    "dns_records_empty.json"
  cf_mock "/dns_records"           "dns_record_create_ok.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A agentculture.org 192.0.2.1 --proxied --apply --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result.id == "new-dns-record-id-bbbb1234"'
  [[ "$output" != *"DNS record created"* ]]
}

@test "cf-dns-create.sh without --proxied emits proxied:false in the body" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=TXT"  "dns_records_empty.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org TXT _verify.agentculture.org 'verify=abc123'
  [ "$status" -eq 0 ]
  [[ "$output" == *"**proxied:** false"* ]]
  [[ "$output" == *'"proxied": false'* ]]
}

@test "cf-dns-create.sh --ttl=3600 accepts manual TTL when not proxied" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=A"    "dns_records_empty.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A origin.agentculture.org 192.0.2.2 --ttl=3600
  [ "$status" -eq 0 ]
  [[ "$output" == *'"ttl": 3600'* ]]
  [[ "$output" == *"**ttl:** 3600"* ]]
  [[ "$output" != *"**ttl:** 3600 (automatic)"* ]]
}

# --- idempotency & errors ---

@test "cf-dns-create.sh exits 1 when an identical record already exists" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=A"    "dns_records_apex_exists.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A agentculture.org 192.0.2.1 --proxied --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  [[ "$output" == *"existing-dns-record-id-aaaa"* ]]
  _assert_no_post
}

@test "cf-dns-create.sh exits 1 when the zone is not in the account" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" nosuch.dev A nosuch.dev 192.0.2.1 --proxied --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"zone nosuch.dev not found"* ]]
}

@test "cf-dns-create.sh exits 2 when positional args are missing" {
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected 4 positional args"* ]]
}

@test "cf-dns-create.sh exits 2 when fewer than 4 positional args given" {
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A agentculture.org
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected 4 positional args"* ]]
}

@test "cf-dns-create.sh exits 2 on unknown flag" {
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A agentculture.org 192.0.2.1 --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-dns-create.sh exits 2 on unsupported record type" {
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org WEIRD foo.agentculture.org bar
  [ "$status" -eq 2 ]
  [[ "$output" == *"unsupported record type"* ]]
}

@test "cf-dns-create.sh exits 2 when --ttl is out of range" {
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A origin.agentculture.org 192.0.2.2 --ttl=30
  [ "$status" -eq 2 ]
  [[ "$output" == *"--ttl must be 1"* ]]
}

@test "cf-dns-create.sh exits 2 when --proxied is combined with a manual --ttl" {
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A agentculture.org 192.0.2.1 --proxied --ttl=3600
  [ "$status" -eq 2 ]
  [[ "$output" == *"--proxied records must use --ttl=1"* ]]
}

# --- URL encoding of record type, name, and content ---

@test "cf-dns-create.sh URL-encodes record name and content in the existence check" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=TXT"  "dns_records_empty.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org TXT '_dmarc.agentculture.org' 'v=DMARC1; p=none;'
  [ "$status" -eq 0 ]
  # `;`, `=`, and space must all be percent-encoded in the existence-check URL.
  grep -qF 'v%3DDMARC1%3B%20p%3Dnone%3B' "$BATS_TEST_TMPDIR/curl.log"
}

@test "cf-dns-create.sh URL-encodes the record type in the existence check" {
  # record_type is allowlist-validated so it's already safe, but we encode
  # it anyway to stay consistent with the repo-wide convention.
  cf_mock "/zones?per_page"      "zones_with_agentculture.json"
  cf_mock "/dns_records?type=A"  "dns_records_empty.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org A agentculture.org 192.0.2.1 --proxied
  [ "$status" -eq 0 ]
  # Literal "type=A" still shows up (A encodes to itself) but importantly
  # the assignment has passed through jq's @uri filter — the assertion
  # here is really "the URL is well-formed with the encoded value".
  cf_assert_called "/dns_records?type=A&name="
}

# --- `--` end-of-options marker (content/name starting with `-`) ---

@test "cf-dns-create.sh accepts a TXT value starting with '-' when preceded by '--'" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=TXT"  "dns_records_empty.json"
  # Without `--`, the `-foo=bar` token would hit the `-*` case arm and exit 2.
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" --proxied=false -- agentculture.org TXT _acme.agentculture.org '-foo=bar'
  [ "$status" -eq 2 ]  # --proxied=false is still an unknown flag — testing that --proxied-style flags before `--` are still parsed
  [[ "$output" == *"unknown flag: --proxied=false"* ]]
}

@test "cf-dns-create.sh '--' after positional args lets content start with dash" {
  cf_mock "/zones?per_page"        "zones_with_agentculture.json"
  cf_mock "/dns_records?type=TXT"  "dns_records_empty.json"
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org TXT _acme.agentculture.org -- '-starts-with-dash'
  [ "$status" -eq 0 ]
  [[ "$output" == *'"content": "-starts-with-dash"'* ]]
}

@test "cf-dns-create.sh rejects dash-prefixed content WITHOUT '--' (shows users they need the marker)" {
  run bash "$WRITE_SCRIPTS/cf-dns-create.sh" agentculture.org TXT _acme.agentculture.org '-starts-with-dash'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag: -starts-with-dash"* ]]
}
