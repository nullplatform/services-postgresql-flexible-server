#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

SECRET="SUPERSECRETPASSWORD0123456789abcd"
JDBC="jdbc:postgresql://db-9f8e.postgres.database.azure.com:5432/conciliation?sslmode=require"

run_write_link_outputs() {
  (
    export PATH="$SCRIPT_DIR/stub-bin:$PATH"
    export NP_STUB_LOG="$TMP/np.log" TOFU_STUB_LOG="$TMP/tofu.log"
    export OUTPUT_DIR="$TMP/out"; mkdir -p "$OUTPUT_DIR"
    export CONTEXT='{"link":{"id":"lnk-77","slug":"db-main"}}'
    export TOFU_STUB_OUTPUT_username="${1-}"
    export TOFU_STUB_OUTPUT_password="${2-}"
    export TOFU_STUB_OUTPUT_jdbc_url="${3-}"
    # Debug-only outputs of the module; the step must never patch them.
    export TOFU_STUB_OUTPUT_hostname="db-9f8e.postgres.database.azure.com"
    export TOFU_STUB_OUTPUT_database_name="conciliation"
    bash "$SERVICE_PATH/scripts/azure/write_link_outputs" 2>&1
  )
}

echo "== happy path =="
: > "$TMP/np.log"
OUT=$(run_write_link_outputs "u_conciliation_api_eeeeeeee" "$SECRET" "$JDBC")
NP_CALL=$(grep 'link patch' "$TMP/np.log" | head -1)
assert_contains "$NP_CALL" "--id lnk-77" "patches the right link"
BODY=$(printf '%s' "$NP_CALL" | sed 's/.*--body //')
assert_eq "u_conciliation_api_eeeeeeee" "$(printf '%s' "$BODY" | jq -r '.attributes.username')" "username patched"
assert_eq "$SECRET" "$(printf '%s' "$BODY" | jq -r '.attributes.password')" "password patched"
assert_eq "$JDBC" "$(printf '%s' "$BODY" | jq -r '.attributes.jdbc_url')" "jdbc_url patched"

echo "== only the three link-owned attributes are patched =="
assert_eq "jdbc_url password username" "$(printf '%s' "$BODY" | jq -r '.attributes | keys | join(" ")')" "no service attributes duplicated onto the link"

echo "== the password is never printed to the log =="
if printf '%s' "$OUT" | grep -q "SUPERSECRETPASSWORD"; then
  echo "  FAIL the password was written to stdout" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   the password is not printed"
fi
assert_contains "$OUT" "****" "the password is masked in the log"

echo "== no username means no patch =="
: > "$TMP/np.log"
OUT=$(run_write_link_outputs "" "" "")
assert_contains "$OUT" "Skipping" "warns and skips"
if grep -q 'link patch' "$TMP/np.log"; then
  echo "  FAIL patched with no outputs available" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   did not patch when tofu produced no outputs"
fi

echo "== username present but password empty: patch what is present =="
: > "$TMP/np.log"
OUT=$(run_write_link_outputs "u_conciliation_api_eeeeeeee" "" "$JDBC")
NP_CALL=$(grep 'link patch' "$TMP/np.log" | head -1)
BODY=$(printf '%s' "$NP_CALL" | sed 's/.*--body //')
assert_eq "jdbc_url username" "$(printf '%s' "$BODY" | jq -r '.attributes | keys | join(" ")')" \
  "empty password is omitted, not sent as an empty string"
assert_contains "$OUT" "password" "log mentions the empty password"

echo "== NP_SKIP_TOFU=true no-ops without touching OUTPUT_DIR or tofu =="
: > "$TMP/np.log"
: > "$TMP/tofu.log"
SKIP_OUT=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH"
  export NP_STUB_LOG="$TMP/np.log" TOFU_STUB_LOG="$TMP/tofu.log"
  export CONTEXT='{"link":{"id":"lnk-77","slug":"db-main"}}'
  export NP_SKIP_TOFU=true
  export OUTPUT_DIR="$TMP/does-not-exist"
  bash "$SERVICE_PATH/scripts/azure/write_link_outputs" 2>&1
) && SKIP_RC=0 || SKIP_RC=$?
assert_eq "0" "$SKIP_RC" "exits 0 when NP_SKIP_TOFU=true"
assert_eq "0" "$(wc -l < "$TMP/tofu.log" | tr -d '[:space:]')" "tofu was never invoked"
if grep -q 'link patch' "$TMP/np.log"; then
  echo "  FAIL patched the link despite NP_SKIP_TOFU=true" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   did not patch the link"
fi

echo "== tofu missing from PATH fails loudly instead of silently skipping =="
NO_TOFU_BIN="$TMP/no-tofu-bin"
mkdir -p "$NO_TOFU_BIN"
cp "$SCRIPT_DIR/stub-bin/np" "$NO_TOFU_BIN/np"
: > "$TMP/np.log"
NOTOFU_OUT=$(
  export PATH="$NO_TOFU_BIN:/usr/bin:/bin"
  export NP_STUB_LOG="$TMP/np.log"
  export OUTPUT_DIR="$TMP/out-notofu"; mkdir -p "$OUTPUT_DIR"
  export CONTEXT='{"link":{"id":"lnk-77","slug":"db-main"}}'
  bash "$SERVICE_PATH/scripts/azure/write_link_outputs" 2>&1
) && NOTOFU_RC=0 || NOTOFU_RC=$?
assert_eq "1" "$NOTOFU_RC" "exits non-zero when tofu is not on PATH"
assert_contains "$NOTOFU_OUT" "not on PATH" "names the cause instead of warning-and-skipping"

finish_tests
