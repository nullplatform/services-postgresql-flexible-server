#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

SAN="$SERVICE_PATH/scripts/azure/server_name"
SID="9f8e7d6c-1234-4321-abcd-000000000000"

echo "== happy path =="
assert_eq "conciliation-db-9f8e7d6c" "$("$SAN" "Conciliation DB" "$SID")" "spaces become hyphens, case stripped, id suffix appended"

echo "== hyphens survive, runs collapse, edges are trimmed =="
assert_eq "orders-payments-9f8e7d6c" "$("$SAN" "orders-payments" "$SID")" "hyphens kept"
assert_eq "orders-payments-9f8e7d6c" "$("$SAN" "--orders___payments--" "$SID")" "runs collapsed and edges trimmed"

echo "== length cap is 63 and the id suffix survives =="
LONG=$("$SAN" "averyveryverylongservicenamethatoverflowsthesixtythreecharacterlimitbyfar" "$SID")
assert_eq "63" "${#LONG}" "result is exactly 63 chars"
assert_eq "9f8e7d6c" "${LONG: -8}" "id suffix preserved at the end"
assert_eq "-" "${LONG:54:1}" "base and suffix are joined by a hyphen"

echo "== empty and unusable names fall back =="
assert_eq "nppg-9f8e7d6c" "$("$SAN" "" "$SID")" "empty name falls back to nppg"
assert_eq "nppg-9f8e7d6c" "$("$SAN" "!!!___###" "$SID")" "name that sanitizes to nothing falls back"

echo "== output always satisfies the Azure pattern =="
for name in "" "a" "ab" "Conciliation DB" "!!!" "averyveryverylongservicenamethatoverflowsthesixtythreecharacterlimitbyfar" "UPPER-CASE-99" "trailing-"; do
  out=$("$SAN" "$name" "$SID")
  if [[ "$out" =~ ^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])?$ ]] && [ "${#out}" -ge 3 ] && [ "${#out}" -le 63 ]; then
    echo "  ok   valid for input [$name] -> $out"
  else
    echo "  FAIL invalid for input [$name] -> $out" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

echo "== missing service_id is an error =="
assert_fails "no service_id exits non-zero" "$SAN" "some-name"

finish_tests
