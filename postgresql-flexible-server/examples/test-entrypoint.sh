#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

export PATH="$SCRIPT_DIR/stub-bin:$PATH"

# run_handler <handler> <action_type> <action_slug>
# Runs a handler with a stub np on PATH and echoes the np invocation it made.
run_handler() {
  local handler="$1" action_type="$2" action_slug="$3"
  local log
  log=$(mktemp)
  (
    export NP_STUB_LOG="$log"
    export SERVICE_PATH
    export OVERRIDES_PATH="$SERVICE_PATH/overrides"
    export SERVICE_ACTION="$action_slug"
    export SERVICE_ACTION_TYPE="$action_type"
    bash "$SERVICE_PATH/entrypoint/$handler" >/dev/null 2>&1
  ) || true
  grep 'service workflow exec' "$log" 2>/dev/null | head -1
  rm -f "$log"
}

echo "== service handler maps action type to workflow =="
assert_contains "$(run_handler service create create-postgresql-flexible-server)" \
  "workflows/azure/create.yaml" "create -> create.yaml"
assert_contains "$(run_handler service update update-postgresql-flexible-server)" \
  "workflows/azure/update.yaml" "update -> update.yaml"
assert_contains "$(run_handler service delete delete-postgresql-flexible-server)" \
  "workflows/azure/delete.yaml" "delete -> delete.yaml"
assert_contains "$(run_handler service custom read)" \
  "workflows/azure/read.yaml" "custom uses the action slug"

echo "== link handler remaps create/update/delete =="
assert_contains "$(run_handler link create create-connect)" \
  "workflows/azure/link.yaml" "create -> link.yaml"
assert_contains "$(run_handler link update update-connect)" \
  "workflows/azure/link-update.yaml" "update -> link-update.yaml"
assert_contains "$(run_handler link delete delete-connect)" \
  "workflows/azure/unlink.yaml" "delete -> unlink.yaml"

echo "== handlers pass values.yaml =="
assert_contains "$(run_handler service create create-postgresql-flexible-server)" \
  "--values" "values.yaml is passed to the engine"

echo "== handlers reject an unsafe action name =="
LOG=$(mktemp)
(
  export NP_STUB_LOG="$LOG" SERVICE_PATH OVERRIDES_PATH="$SERVICE_PATH/overrides"
  export SERVICE_ACTION='../../etc/passwd' SERVICE_ACTION_TYPE=custom
  bash "$SERVICE_PATH/entrypoint/service" >/dev/null 2>&1
) && { echo "  FAIL path traversal accepted" >&2; FAILURES=$((FAILURES + 1)); } \
  || echo "  ok   path traversal in the action name is rejected"
rm -f "$LOG"

echo "== entrypoint bridges the API key and builds CONTEXT =="
BRIDGE=$(
  export NP_STUB_LOG="$(mktemp)"
  export NP_API_KEY="key.value"
  unset NULLPLATFORM_API_KEY
  export NP_ACTION_CONTEXT="'"'{"notification":{"slug":"create-postgresql-flexible-server","type":"create","action":"service:action:create","link":null,"service":{"id":"svc-1"}}}'"'"
  bash -c '
    source '"$SERVICE_PATH"'/entrypoint/entrypoint --service-path='"$SERVICE_PATH"' >/dev/null 2>&1
    echo "$NULLPLATFORM_API_KEY|$ACTION_SOURCE|$SERVICE_ACTION_TYPE|$SERVICE_PATH"
  '
) || true
assert_contains "$BRIDGE" "key.value" "NP_API_KEY bridged to NULLPLATFORM_API_KEY"
assert_contains "$BRIDGE" "service" "ACTION_SOURCE is service when link is null"
assert_contains "$BRIDGE" "create" "SERVICE_ACTION_TYPE parsed"

echo "== entrypoint detects a link action =="
LINKED=$(
  export NP_STUB_LOG="$(mktemp)"
  export NP_API_KEY="key.value"
  export NP_ACTION_CONTEXT='{"notification":{"slug":"create-connect","type":"create","action":"link:action:create","link":{"id":"lnk-1"},"service":{"id":"svc-1"}}}'
  bash -c '
    source '"$SERVICE_PATH"'/entrypoint/entrypoint --service-path='"$SERVICE_PATH"' >/dev/null 2>&1
    echo "$ACTION_SOURCE"
  '
) || true
assert_contains "$LINKED" "link" "ACTION_SOURCE is link when .link is present"

echo "== entrypoint fails fast without a context =="
assert_fails "missing NP_ACTION_CONTEXT exits non-zero" \
  env -u NP_ACTION_CONTEXT bash "$SERVICE_PATH/entrypoint/entrypoint"

finish_tests
