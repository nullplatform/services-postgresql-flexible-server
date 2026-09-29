#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A values.yaml with placement filled in, so the test does not depend on the
# committed (intentionally empty) one.
cat > "$TMP/values.yaml" <<'YAML'
subscription_id: "sub-1234"
client_id: ""
tenant_id: ""
resource_group_name: "rg-pg-test"
location: "eastus2"
allowed_ips: "20.1.2.3, 10.0.0.1-10.0.0.9"
tfstate_storage_account: "npstatetest"
tfstate_resource_group: "rg-state-test"
tfstate_container: "services-tfstate"
YAML

# load_context <fixture> — sources build_context in a subshell and echoes the
# resulting environment as KEY=VALUE lines.
load_context() {
  local fixture="$1"
  (
    export PATH="$SCRIPT_DIR/stub-bin:$PATH"
    export AZ_STUB_LOG="$TMP/az.log"
    export NP_STUB_LOG="$TMP/np.log"
    export CONTEXT
    CONTEXT=$(jq '.notification' "$fixture")
    export LINK
    LINK=$(echo "$CONTEXT" | jq '.link')
    export SERVICE_PATH VALUES="$TMP/values.yaml"
    export ACTION_SOURCE
    ACTION_SOURCE=$([ "$(echo "$CONTEXT" | jq '.link != null')" = "true" ] && echo link || echo service)
    unset SERVICES_PG_ALLOWED_IPS || true
    # shellcheck source=/dev/null
    source "$SERVICE_PATH/scripts/azure/build_context" >/dev/null 2>&1
    for v in SERVICE_ID SERVICE_NAME SERVER_NAME DATABASE_NAME RESOURCE_GROUP_NAME LOCATION ALLOWED_IPS \
             TFSTATE_STORAGE_ACCOUNT TFSTATE_RESOURCE_GROUP TFSTATE_CONTAINER TFSTATE_KEY \
             OUTPUT_DIR TOFU_MODULE_DIR TOFU_INIT_VARIABLES TOFU_VARIABLES \
             LINK_ID LINK_USERNAME LINK_ACCESS_LEVEL; do
      printf '%s=%s\n' "$v" "${!v:-}"
    done
  )
}

get() { printf '%s' "$1" | grep "^$2=" | head -1 | cut -d= -f2-; }

echo "== create action =="
ENV_OUT=$(load_context "$SCRIPT_DIR/create.json")

assert_eq "9f8e7d6c-1234-4321-abcd-000000000000" "$(get "$ENV_OUT" SERVICE_ID)" "SERVICE_ID parsed"
assert_eq "conciliation-db-9f8e7d6c" "$(get "$ENV_OUT" SERVER_NAME)" "server name derived from service name"
assert_eq "conciliation" "$(get "$ENV_OUT" DATABASE_NAME)" "database name from parameters"
assert_eq "rg-pg-test" "$(get "$ENV_OUT" RESOURCE_GROUP_NAME)" "resource group from values.yaml"
assert_eq "eastus2" "$(get "$ENV_OUT" LOCATION)" "location from values.yaml"
assert_eq "services-tfstate" "$(get "$ENV_OUT" TFSTATE_CONTAINER)" "uses the shared container, never creates one"
assert_eq "rg-state-test" "$(get "$ENV_OUT" TFSTATE_RESOURCE_GROUP)" "tfstate resource group from values.yaml"
assert_eq "postgresql-flexible-server/9f8e7d6c-1234-4321-abcd-000000000000/deployment.tfstate" "$(get "$ENV_OUT" TFSTATE_KEY)" "per-service state key exported for the link steps"
assert_contains "$(get "$ENV_OUT" TOFU_MODULE_DIR)" "/deployment" "module dir points at deployment/"
assert_contains "$(get "$ENV_OUT" OUTPUT_DIR)" "np-service-9f8e7d6c" "output dir is per service instance"

echo "== backend settings are written as a FILE, never as a flag string =="
BACKEND="$(get "$ENV_OUT" OUTPUT_DIR)/backend.hcl"
assert_eq "yes" "$([ -f "$BACKEND" ] && echo yes || echo no)" "backend.hcl written into OUTPUT_DIR"
BH=$(cat "$BACKEND" 2>/dev/null)
assert_contains "$BH" 'storage_account_name = "npstatetest"' "state account"
assert_contains "$BH" 'container_name       = "services-tfstate"' "state container"
assert_contains "$BH" 'key                  = "postgresql-flexible-server/9f8e7d6c-1234-4321-abcd-000000000000/deployment.tfstate"' "per-service state key"
assert_contains "$BH" 'resource_group_name  = "rg-state-test"' "state resource group"
assert_contains "$BH" 'use_azuread_auth     = true' "backend authenticates via Azure AD, not shared key"
assert_eq "" "$(get "$ENV_OUT" TOFU_INIT_VARIABLES)" "no flag string is exported"

echo "== TOFU_VARIABLES is a JSON object matching the module's variables =="
TFVARS=$(get "$ENV_OUT" TOFU_VARIABLES)
assert_eq "ok" "$(printf '%s' "$TFVARS" | jq -e . >/dev/null 2>&1 && echo ok || echo bad)" "TOFU_VARIABLES is valid JSON"
assert_eq "conciliation-db-9f8e7d6c" "$(printf '%s' "$TFVARS" | jq -r '.server_name')" "tfvars server_name"
assert_eq "conciliation" "$(printf '%s' "$TFVARS" | jq -r '.database_name')" "tfvars database_name"
assert_eq "17" "$(printf '%s' "$TFVARS" | jq -r '.postgres_version')" "postgres_version from parameters is a string, as azurerm expects"
assert_eq "string" "$(printf '%s' "$TFVARS" | jq -r '.postgres_version | type')" "postgres_version typed as string"
assert_eq "14" "$(printf '%s' "$TFVARS" | jq -r '.backup_retention_days')" "parameters override defaults"
assert_eq "number" "$(printf '%s' "$TFVARS" | jq -r '.storage_mb | type')" "storage_mb typed as number"
assert_eq "boolean" "$(printf '%s' "$TFVARS" | jq -r '.high_availability | type')" "high_availability typed as boolean"
assert_eq "object" "$(printf '%s' "$TFVARS" | jq -r '.tags | type')" "tags typed as object"

echo "== allowed_ips is split, trimmed and typed as an array =="
assert_eq "array" "$(printf '%s' "$TFVARS" | jq -r '.allowed_ips | type')" "allowed_ips typed as array"
assert_eq "20.1.2.3 10.0.0.1-10.0.0.9" "$(printf '%s' "$TFVARS" | jq -r '.allowed_ips | join(" ")')" "entries trimmed, ranges preserved"

echo "== tfvars keys are exactly the module's variables =="
EXPECTED_KEYS="allowed_ips backup_retention_days database_name high_availability location postgres_version resource_group_name server_name service_id sku_name storage_mb tags"
assert_eq "$EXPECTED_KEYS" "$(printf '%s' "$TFVARS" | jq -r 'keys | join(" ")')" "no extra or missing tfvars keys"

echo "== nothing invokes az =="
if grep -q "az " "$SERVICE_PATH/scripts/azure/build_context"; then
  echo "  FAIL build_context calls az" >&2; FAILURES=$((FAILURES + 1))
else
  echo "  ok   build_context does not depend on the az binary"
fi

echo "== attributes are merged with parameters, parameters winning =="
MERGED=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az2.log" NP_STUB_LOG="$TMP/np2.log"
  CONTEXT=$(jq '.notification
    | .service.attributes = {"database_name":"conciliation","sku_name":"GP_Standard_D2s_v3","backup_retention_days":35}
    | .parameters = {"sku_name":"B_Standard_B2s"}' "$SCRIPT_DIR/create.json")
  export CONTEXT
  export LINK=null SERVICE_PATH VALUES="$TMP/values.yaml" ACTION_SOURCE=service
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_context" >/dev/null 2>&1
  printf '%s' "$TOFU_VARIABLES"
)
assert_eq "B_Standard_B2s" "$(printf '%s' "$MERGED" | jq -r '.sku_name')" "parameter beats stored attribute"
assert_eq "35" "$(printf '%s' "$MERGED" | jq -r '.backup_retention_days')" "stored attribute used when no parameter"

echo "== a stored server_name is stable and wins over a changed .service.name =="
# "name" forces replacement on azurerm_postgresql_flexible_server: recomputing
# it from .service.name on every action would destroy the server and its data
# the moment someone renames the service instance in nullplatform.
STABLE_NAME_ENV=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az5.log" NP_STUB_LOG="$TMP/np5.log"
  CONTEXT=$(jq '.notification
    | .service.name = "Totally Renamed Service"
    | .service.attributes = {"server_name":"conciliation-db-9f8e7d6c","database_name":"conciliation"}' "$SCRIPT_DIR/create.json")
  export CONTEXT LINK=null SERVICE_PATH VALUES="$TMP/values.yaml" ACTION_SOURCE=service
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_context" >/dev/null 2>&1
  printf 'SERVER_NAME=%s\n' "$SERVER_NAME"
)
assert_eq "SERVER_NAME=conciliation-db-9f8e7d6c" "$STABLE_NAME_ENV" \
  "stored server_name wins over a freshly-computed name from the changed service name"

echo "== invalid parameters are rejected =="
reject() {
  local patch="$1" label="$2"
  (
    export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az3.log" NP_STUB_LOG="$TMP/np3.log"
    CONTEXT=$(jq --argjson p "$patch" '.notification | .parameters = (.parameters + $p)' "$SCRIPT_DIR/create.json")
    export CONTEXT LINK=null SERVICE_PATH VALUES="$TMP/values.yaml" ACTION_SOURCE=service
    # shellcheck source=/dev/null
    source "$SERVICE_PATH/scripts/azure/build_context" >/dev/null 2>&1
  ) && { echo "  FAIL $label" >&2; FAILURES=$((FAILURES + 1)); } || echo "  ok   $label"
}
reject '{"database_name":"Conciliation"}'          "uppercase database_name rejected"
reject '{"database_name":"1db"}'                   "database_name starting with a digit rejected"
reject '{"database_name":"db; drop table x"}'      "database_name with SQL rejected"
reject '{"postgres_version":"9.6"}'                "unsupported postgres_version rejected"
reject '{"sku_name":"Deluxe"}'                     "unknown sku_name rejected"
reject '{"storage_mb":"; rm -rf /"}'               "non-numeric storage_mb rejected"
reject '{"storage_mb":1024}'                       "storage_mb below the Azure minimum rejected"
reject '{"backup_retention_days":99}'              "out-of-range backup_retention_days rejected"
reject '{"high_availability":"maybe"}'             "non-boolean high_availability rejected"

echo "== database_name is required on create =="
reject '{"database_name":""}' "empty database_name rejected on create"

echo "== an invalid allowed_ips entry is rejected before tofu =="
BAD_IPS_VALUES="$TMP/bad-ips-values.yaml"
sed 's/^allowed_ips:.*/allowed_ips: "20.1.2.3, not-an-ip"/' "$TMP/values.yaml" > "$BAD_IPS_VALUES"
BAD_IPS_ERR=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az6.log" NP_STUB_LOG="$TMP/np6.log"
  CONTEXT=$(jq '.notification' "$SCRIPT_DIR/create.json")
  export CONTEXT LINK=null SERVICE_PATH VALUES="$BAD_IPS_VALUES" ACTION_SOURCE=service
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_context" 2>&1
) && BAD_IPS_RC=0 || BAD_IPS_RC=$?
assert_eq "1" "$BAD_IPS_RC" "build_context fails on a malformed allowed_ips entry"
assert_contains "$BAD_IPS_ERR" "not-an-ip" "error names the offending entry"

echo "== an empty allowed_ips warns loudly but does not block =="
NO_IPS_VALUES="$TMP/no-ips-values.yaml"
sed 's/^allowed_ips:.*/allowed_ips: ""/' "$TMP/values.yaml" > "$NO_IPS_VALUES"
NO_IPS_OUT=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az7.log" NP_STUB_LOG="$TMP/np7.log"
  CONTEXT=$(jq '.notification' "$SCRIPT_DIR/create.json")
  export CONTEXT LINK=null SERVICE_PATH VALUES="$NO_IPS_VALUES" ACTION_SOURCE=service
  unset SERVICES_PG_ALLOWED_IPS || true
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_context" 2>&1
  printf 'ALLOWED=%s\n' "$(printf '%s' "$TOFU_VARIABLES" | jq -c '.allowed_ips')"
) && NO_IPS_RC=0 || NO_IPS_RC=$?
assert_eq "0" "$NO_IPS_RC" "create still runs with no firewall entries"
assert_contains "$NO_IPS_OUT" "WARNING: allowed_ips is empty" "warns that nothing will be able to connect"
assert_contains "$NO_IPS_OUT" "ALLOWED=[]" "tfvars carry an empty array"

echo "== allowed_ips falls back to the agent environment =="
ENV_IPS_OUT=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az8.log" NP_STUB_LOG="$TMP/np8.log"
  CONTEXT=$(jq '.notification' "$SCRIPT_DIR/create.json")
  export CONTEXT LINK=null SERVICE_PATH VALUES="$NO_IPS_VALUES" ACTION_SOURCE=service
  export SERVICES_PG_ALLOWED_IPS="40.4.4.4"
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_context" >/dev/null 2>&1
  printf '%s' "$TOFU_VARIABLES" | jq -r '.allowed_ips | join(",")'
)
assert_eq "40.4.4.4" "$ENV_IPS_OUT" "SERVICES_PG_ALLOWED_IPS used when values.yaml is empty"

echo "== missing placement fails with a clear message =="
EMPTY_VALUES="$TMP/empty-values.yaml"
printf 'subscription_id: ""\nresource_group_name: ""\nlocation: ""\ntfstate_storage_account: ""\n' > "$EMPTY_VALUES"
PLACEMENT_ERR=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az4.log" NP_STUB_LOG="$TMP/np4.log"
  CONTEXT=$(jq '.notification' "$SCRIPT_DIR/create.json")
  export CONTEXT LINK=null SERVICE_PATH VALUES="$EMPTY_VALUES" ACTION_SOURCE=service
  unset RESOURCE_GROUP SERVICES_RESOURCE_GROUP || true
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_context" 2>&1
) || true
assert_contains "$PLACEMENT_ERR" "resource_group_name" "error names the missing setting"

echo "== link action derives a stable role name =="
LINK_ENV=$(load_context "$SCRIPT_DIR/link.json")
assert_eq "eeeeeeee-1111-2222-3333-444444444444" "$(get "$LINK_ENV" LINK_ID)" "LINK_ID parsed"
assert_eq "u_conciliation_api_eeeeeeee" "$(get "$LINK_ENV" LINK_USERNAME)" "username derived from the app slug and the link id"
assert_eq "admin" "$(get "$LINK_ENV" LINK_ACCESS_LEVEL)" "access level from link parameters"

echo "== a stored username wins over a recomputed one =="
STORED_USER=$(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az9.log" NP_STUB_LOG="$TMP/np9.log"
  CONTEXT=$(jq '.notification | .type = "update" | .link.attributes = {"username":"u_legacy_name"} | .link.entity.slug = "renamed-app"' "$SCRIPT_DIR/link.json")
  export CONTEXT
  LINK=$(echo "$CONTEXT" | jq '.link'); export LINK
  export SERVICE_PATH VALUES="$TMP/values.yaml" ACTION_SOURCE=link
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_context" >/dev/null 2>&1
  printf '%s' "$LINK_USERNAME"
)
assert_eq "u_legacy_name" "$STORED_USER" "stored username is kept: a rename would drop the role"

echo "== an invalid access_level is rejected =="
(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" AZ_STUB_LOG="$TMP/az10.log" NP_STUB_LOG="$TMP/np10.log"
  CONTEXT=$(jq '.notification | .parameters.access_level = "superuser"' "$SCRIPT_DIR/link.json")
  export CONTEXT
  LINK=$(echo "$CONTEXT" | jq '.link'); export LINK
  export SERVICE_PATH VALUES="$TMP/values.yaml" ACTION_SOURCE=link
  # shellcheck source=/dev/null
  source "$SERVICE_PATH/scripts/azure/build_context" >/dev/null 2>&1
) && { echo "  FAIL superuser accepted" >&2; FAILURES=$((FAILURES + 1)); } || echo "  ok   unknown access_level rejected"

finish_tests
