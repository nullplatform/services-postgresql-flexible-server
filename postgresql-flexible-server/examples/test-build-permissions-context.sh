#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/values.yaml" <<'YAML'
resource_group_name: "rg-pg-test"
location: "eastus2"
allowed_ips: "20.1.2.3"
tfstate_storage_account: "npstatetest"
tfstate_resource_group: "rg-state-test"
tfstate_container: "services-tfstate"
YAML

# load_link <jq_patch> — runs build_context then build_permissions_context and
# echoes the resulting environment.
load_link() {
  local patch="${1:-.}"
  (
    export PATH="$SCRIPT_DIR/stub-bin:$PATH"
    export AZ_STUB_LOG="$TMP/az.log" NP_STUB_LOG="$TMP/np.log"
    CONTEXT=$(jq "$patch" <(jq '.notification' "$SCRIPT_DIR/link.json"))
    export CONTEXT
    LINK=$(echo "$CONTEXT" | jq '.link')
    export LINK
    export SERVICE_PATH VALUES="$TMP/values.yaml" ACTION_SOURCE=link
    # shellcheck source=/dev/null
    source "$SERVICE_PATH/scripts/azure/build_context" >/dev/null 2>&1
    # shellcheck source=/dev/null
    source "$SERVICE_PATH/scripts/azure/build_permissions_context" >/dev/null 2>&1
    for v in OUTPUT_DIR TOFU_MODULE_DIR TOFU_INIT_VARIABLES TOFU_VARIABLES; do
      printf '%s=%s\n' "$v" "${!v:-}"
    done
  )
}

get() { printf '%s' "$1" | grep "^$2=" | head -1 | cut -d= -f2-; }

echo "== link action =="
ENV_OUT=$(load_link)

assert_contains "$(get "$ENV_OUT" TOFU_MODULE_DIR)" "/permissions" "module dir points at permissions/"
assert_contains "$(get "$ENV_OUT" OUTPUT_DIR)" "np-link-eeeeeeee" "output dir is per link"

echo "== link state key is nested under the service prefix =="
BACKEND="$(get "$ENV_OUT" OUTPUT_DIR)/backend.hcl"
assert_eq "yes" "$([ -f "$BACKEND" ] && echo yes || echo no)" "backend.hcl written into OUTPUT_DIR"
BH=$(cat "$BACKEND" 2>/dev/null)
assert_contains "$BH" 'container_name       = "services-tfstate"' "reuses the shared tfstate container"
assert_contains "$BH" 'key                  = "postgresql-flexible-server/9f8e7d6c-1234-4321-abcd-000000000000/links/eeeeeeee-1111-2222-3333-444444444444.tfstate"' "per-link state key nested under the service prefix"
assert_contains "$BH" 'use_azuread_auth     = true' "backend authenticates via Azure AD, not shared key"

echo "== tfvars match the permissions module variables exactly =="
TFVARS=$(get "$ENV_OUT" TOFU_VARIABLES)
assert_eq "ok" "$(printf '%s' "$TFVARS" | jq -e . >/dev/null 2>&1 && echo ok || echo bad)" "TOFU_VARIABLES is valid JSON"
EXPECTED_KEYS="access_level deployment_state_key link_id tfstate_container_name tfstate_resource_group_name tfstate_storage_account_name username"
assert_eq "$EXPECTED_KEYS" "$(printf '%s' "$TFVARS" | jq -r 'keys | join(" ")')" "no extra or missing keys"
assert_eq "u_conciliation_api_eeeeeeee" "$(printf '%s' "$TFVARS" | jq -r '.username')" "role name derived by build_context"
assert_eq "admin" "$(printf '%s' "$TFVARS" | jq -r '.access_level')" "access level from link parameters"
assert_eq "postgresql-flexible-server/9f8e7d6c-1234-4321-abcd-000000000000/deployment.tfstate" "$(printf '%s' "$TFVARS" | jq -r '.deployment_state_key')" "points the module at the server's own state"
assert_eq "npstatetest" "$(printf '%s' "$TFVARS" | jq -r '.tfstate_storage_account_name')" "state account passed through"
assert_eq "services-tfstate" "$(printf '%s' "$TFVARS" | jq -r '.tfstate_container_name')" "state container passed through"
assert_eq "rg-state-test" "$(printf '%s' "$TFVARS" | jq -r '.tfstate_resource_group_name')" "state resource group passed through"

echo "== no credential or hostname travels as a variable =="
for forbidden in admin_password password hostname; do
  assert_eq "null" "$(printf '%s' "$TFVARS" | jq -r --arg k "$forbidden" '.[$k]')" "$forbidden is not a tfvar"
done

echo "== missing hostname is a clear, actionable error =="
ERR=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az2.log" NP_STUB_LOG="$TMP/np2.log"
  CONTEXT=$(jq '.notification | .service.attributes = {}' "$SCRIPT_DIR/link.json")
  export CONTEXT
  LINK=$(echo "$CONTEXT" | jq '.link'); export LINK
  export SERVICE_PATH VALUES="$TMP/values.yaml" ACTION_SOURCE=link
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_context" >/dev/null 2>&1
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_permissions_context" 2>&1
) || true
assert_contains "$ERR" "hostname" "error names the missing attribute"
assert_contains "$ERR" "create" "error points at the incomplete create action"

echo "== unlink on a service that was never created exits cleanly =="
UNLINK_OUT=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az4.log" NP_STUB_LOG="$TMP/np4.log"
  CONTEXT=$(jq '.notification | .type = "delete" | .parameters = {} | .service.attributes = {} | .link.attributes = {}' "$SCRIPT_DIR/link.json")
  export CONTEXT
  LINK=$(echo "$CONTEXT" | jq '.link'); export LINK
  export SERVICE_PATH VALUES="$TMP/values.yaml" ACTION_SOURCE=link
  # build_permissions_context calls "exit 0" on this branch, which ends this
  # subshell immediately — a trap is the only way to still observe the
  # variables it exported right before exiting.
  trap 'printf "NP_SKIP_TOFU=%s\nTOFU_MODULE_DIR=%s\n" "${NP_SKIP_TOFU:-}" "${TOFU_MODULE_DIR:-}"' EXIT
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_context" >/dev/null 2>&1
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_permissions_context" 2>&1
) && UNLINK_RC=0 || UNLINK_RC=$?
assert_eq "0" "$UNLINK_RC" "unlink with no server does not fail the workflow"
assert_contains "$UNLINK_OUT" "never fully created" "explains that there is nothing to destroy"
assert_eq "true" "$(get "$UNLINK_OUT" NP_SKIP_TOFU)" \
  "NP_SKIP_TOFU is set so do_tofu and write_link_outputs no-op instead of running tofu destroy"

UNLINK_MODULE_DIR="$(get "$UNLINK_OUT" TOFU_MODULE_DIR)"
case "$UNLINK_MODULE_DIR" in
  */deployment)
    echo "  FAIL TOFU_MODULE_DIR still points at deployment/ (got: '$UNLINK_MODULE_DIR') — the next" >&2
    echo "       step (do_tofu) would see this and could destroy the server" >&2
    FAILURES=$((FAILURES + 1))
    ;;
  *)
    echo "  ok   TOFU_MODULE_DIR does not point at deployment/ (got: '$UNLINK_MODULE_DIR')"
    ;;
esac

finish_tests
