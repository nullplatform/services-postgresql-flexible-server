#!/bin/bash
# Level 2 test: runs build_context and do_tofu against a REAL Azure session,
# without an agent or the nullplatform API.
#
# This CREATES REAL AZURE RESOURCES and costs money. It requires an active
# "az login" session and a values.yaml with real placement.
#
# Usage: full-test.sh [fixture.json] [apply|destroy]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
CONTEXT_FILE="${1:-$SCRIPT_DIR/create.json}"
ACTION="${2:-apply}"

if [[ ! "$ACTION" =~ ^(apply|destroy)$ ]]; then
  echo "ERROR: action must be apply or destroy, got '$ACTION'" >&2
  exit 1
fi

if [ ! -f "$CONTEXT_FILE" ]; then
  echo "ERROR: fixture not found: $CONTEXT_FILE" >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: the az CLI is required for a full test." >&2
  exit 1
fi

if ! az account show --only-show-errors >/dev/null 2>&1; then
  echo "ERROR: no active Azure session. Run:" >&2
  echo "  az login && az account set --subscription <subscription-id>" >&2
  exit 1
fi

echo "=== FULL TEST (creates real Azure resources) ==="
echo "Fixture:      $CONTEXT_FILE"
echo "Action:       $ACTION"
echo "Subscription: $(az account show --query name -o tsv)"
echo

read -r -p "This will $ACTION real Azure resources. Continue? [y/N] " reply
if [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
  echo "Aborted."
  exit 0
fi

CONTEXT=$(jq '.notification' "$CONTEXT_FILE")
export CONTEXT
LINK=$(echo "$CONTEXT" | jq '.link')
export LINK
export SERVICE_PATH
export VALUES="${VALUES:-$SERVICE_PATH/values.yaml}"

ACTION_SOURCE=service
if [ "$(echo "$CONTEXT" | jq '.link != null')" = "true" ]; then
  ACTION_SOURCE=link
fi
export ACTION_SOURCE

echo "=== 1. resolve_azure_credentials ==="
# shellcheck source=/dev/null
source "$SERVICE_PATH/scripts/azure/resolve_azure_credentials"
echo

echo "=== 2. build_context ==="
# shellcheck source=/dev/null
source "$SERVICE_PATH/scripts/azure/build_context"
echo

if [ "$ACTION_SOURCE" = "link" ]; then
  echo "=== 3. build_permissions_context ==="
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_permissions_context"
  echo
fi

echo "=== 4. do_tofu ($ACTION) ==="
export TOFU_ACTION="$ACTION"

# do_tofu runs as a SUBPROCESS here, not sourced, for two reasons.
#
# 1. Failure handling. Sourcing it means a failing `tofu apply` trips this
#    script's own `set -e` and kills the process at that line — so the cleanup
#    guidance below never prints, in exactly the situation where the operator
#    most needs it: a partial apply that may have left real Azure resources
#    behind. And `source X || rc=$?` does NOT rescue that: the `||` never gets
#    to run, because the failure is raised inside the sourced script and exits
#    the current shell first. Verified both ways.
# 2. Fidelity. The nullplatform agent runs each workflow step as its own
#    process, so a subprocess is what production actually does.
#
# do_tofu carries its own `set -euo pipefail`, so it exits non-zero on failure.
# It has no unconditional export statements — the one exception is the
# on-agent tofu-install fallback, which exports an extended PATH so a
# just-downloaded binary is found by later steps in that same process; that
# would not reach this parent shell as a subprocess, but it never fires here
# (tofu is preinstalled) and never fires on a real agent either (this harness
# doesn't run there).
TOFU_RC=0
bash "$SERVICE_PATH/scripts/azure/do_tofu" || TOFU_RC=$?

if [ "$TOFU_RC" -ne 0 ]; then
  echo
  echo "!!! tofu ${ACTION} FAILED (exit ${TOFU_RC})."
  echo "    Azure resources may have been PARTIALLY created."
  echo "    Terraform state is in: ${OUTPUT_DIR}"
  echo "    Clean up with:"
  echo "      bash $0 $CONTEXT_FILE destroy"
  exit "$TOFU_RC"
fi
echo

if [ "$ACTION" = "apply" ]; then
  echo "=== 5. Terraform outputs ==="
  (cd "$OUTPUT_DIR" && tofu output)
  echo
  echo "Note: outputs were NOT written to nullplatform — write_service_outputs"
  echo "and write_link_outputs need a real service or link ID."
  echo
  echo "Clean up with:"
  echo "  bash $0 $CONTEXT_FILE destroy"
fi

echo "=== FULL TEST COMPLETE ==="
