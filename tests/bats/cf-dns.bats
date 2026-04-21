#!/usr/bin/env bats

load test_helper

setup() {
  cf_bats_setup
}

@test "cf-dns.sh renders markdown table with zone heading and record count" {
  cf_mock "/zones?name=" "zone_lookup.json"
  cf_mock "/dns_records" "dns_records.json"
  run bash "$SKILL_SCRIPTS/cf-dns.sh" culture.dev
  [ "$status" -eq 0 ]
  [[ "$output" == *"## DNS records for culture.dev (4)"* ]]
  [[ "$output" == *"| TYPE | NAME | CONTENT | PROXIED | TTL |"* ]]
  [[ "$output" == *"| --- | --- | --- | --- | --- |"* ]]
  [[ "$output" == *"culture.dev"* ]]
  [[ "$output" == *"192.0.2.10"* ]]
  [[ "$output" == *"proxied"* ]]
  [[ "$output" == *"v=spf1"* ]]
}

@test "cf-dns.sh resolves zone name to id before fetching records" {
  cf_mock "/zones?name=" "zone_lookup.json"
  cf_mock "/dns_records" "dns_records.json"
  run bash "$SKILL_SCRIPTS/cf-dns.sh" culture.dev
  [ "$status" -eq 0 ]
  cf_assert_called "/zones?name=culture.dev"
  cf_assert_called "/zones/zone-id-culture-dev-0123456789abcdef/dns_records"
}

@test "cf-dns.sh --json emits the raw records response" {
  cf_mock "/zones?name=" "zone_lookup.json"
  cf_mock "/dns_records" "dns_records.json"
  run bash "$SKILL_SCRIPTS/cf-dns.sh" culture.dev --json
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.success == true'
  echo "$output" | jq -e '.result | length == 4'
  echo "$output" | jq -e '.result | map(.type) | contains(["A", "CNAME", "MX", "TXT"])'
  [[ "$output" != *"## DNS records"* ]]
}

@test "cf-dns.sh exits 1 with a clear message when zone is not found" {
  cf_mock "/zones?name=" "zone_lookup_empty.json"
  run bash "$SKILL_SCRIPTS/cf-dns.sh" nonexistent.example
  [ "$status" -eq 1 ]
  [[ "$output" == *"zone 'nonexistent.example' not found"* ]]
}

@test "cf-dns.sh exits 2 when no zone argument is given" {
  run bash "$SKILL_SCRIPTS/cf-dns.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"zone name is required"* ]]
}

@test "cf-dns.sh exits 2 on unknown flag" {
  run bash "$SKILL_SCRIPTS/cf-dns.sh" --bogus culture.dev
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown flag"* ]]
}

@test "cf-dns.sh exits 2 on extra positional argument" {
  run bash "$SKILL_SCRIPTS/cf-dns.sh" culture.dev also.example
  [ "$status" -eq 2 ]
  [[ "$output" == *"unexpected extra argument"* ]]
}

@test "cf-dns.sh URL-encodes the zone argument so '&' cannot inject query params" {
  cf_mock "/zones?name=" "zone_lookup.json"
  cf_mock "/dns_records" "dns_records.json"
  run bash "$SKILL_SCRIPTS/cf-dns.sh" 'evil.com&status=active'
  # The encoded request URL should contain %26, NOT the literal &status=
  cf_assert_called "evil.com%26status%3Dactive"
}
