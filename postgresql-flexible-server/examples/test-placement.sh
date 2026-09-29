#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"
# shellcheck source=/dev/null
source "$SERVICE_PATH/scripts/azure/resolve_placement_lib"

# A cloud-providers config carrying the optional `services` block.
PROVIDER_JSON='{
  "authentication": {"subscription_id":"sub-p","client_id":"cli-p","tenant_id":"ten-p"},
  "services": {
    "resource_group_name": "rg-from-provider",
    "location": "westus2",
    "tfstate": {
      "storage_account": "sa-from-provider",
      "container": "ct-from-provider",
      "resource_group_name": "rg-tfstate-from-provider"
    }
  }
}'

# Every test runs with a clean slate: these are exactly the variables the
# resolvers consult, and a leaked one would make an assertion pass for the
# wrong reason.
clear_env() {
  unset SERVICES_RESOURCE_GROUP RESOURCE_GROUP SERVICES_LOCATION \
        AZURE_TFSTATE_STORAGE_ACCOUNT AZURE_TFSTATE_CONTAINER \
        AZURE_TFSTATE_RESOURCE_GROUP || true
}

echo "== first_non_empty is the precedence primitive =="
assert_eq "a"  "$(first_non_empty "a" "b" "c")" "first wins"
assert_eq "b"  "$(first_non_empty ""  "b" "c")" "skips a leading empty"
assert_eq "c"  "$(first_non_empty ""  ""  "c")" "skips two leading empties"
assert_eq ""   "$(first_non_empty ""  ""  "")"  "all empty yields empty"
assert_eq ""   "$(first_non_empty)"             "no arguments yields empty"
# A value that is only whitespace is a value, not an absence — matching how
# the shell's own ${x:-y} behaves, so the two never disagree.
assert_eq " "  "$(first_non_empty " " "b")"     "whitespace counts as present"

echo "== provider_field reads nested paths and never crashes =="
assert_eq "rg-from-provider" "$(provider_field "$PROVIDER_JSON" "services.resource_group_name")" "top-level nested field"
assert_eq "ct-from-provider" "$(provider_field "$PROVIDER_JSON" "services.tfstate.container")"   "two levels deep"
assert_eq "" "$(provider_field "$PROVIDER_JSON" "services.nope")"      "absent field is empty"
assert_eq "" "$(provider_field "$PROVIDER_JSON" "a.b.c.d.e")"          "absent deep path is empty"
assert_eq "" "$(provider_field '' 'services.location')"               "empty json is empty"
assert_eq "" "$(provider_field '{}' 'services.location')"             "empty object is empty"
assert_eq "" "$(provider_field 'not json at all' 'services.location')" "malformed json does not crash"
assert_eq "" "$(provider_field "$PROVIDER_JSON" '')"                  "empty path is empty"
# A non-string must not leak jq's rendering of an object into a shell variable
# that is about to become a resource group name.
assert_eq "" "$(provider_field "$PROVIDER_JSON" 'services.tfstate')"  "an object reads as empty, not as JSON"

echo "== values.yaml outranks the provider, which outranks the environment =="
(
  clear_env
  export SERVICES_RESOURCE_GROUP="rg-from-env"
  assert_eq "rg-from-values" "$(placement_resource_group "$PROVIDER_JSON" "rg-from-values")" "values wins"
  assert_eq "rg-from-provider" "$(placement_resource_group "$PROVIDER_JSON" "")"             "provider beats env"
  assert_eq "rg-from-env"      "$(placement_resource_group '{}' "")"                         "env is the last resort"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== RESOURCE_GROUP is read: it is what the nullplatform agent actually injects =="
(
  clear_env
  # tofu-modules nullplatform/agent (v7.7.0) sets RESOURCE_GROUP, not
  # SERVICES_RESOURCE_GROUP. Reading only the latter — as this service did
  # before — meant a stock Azure agent supplied nothing.
  export RESOURCE_GROUP="rg-from-agent"
  assert_eq "rg-from-agent" "$(placement_resource_group '{}' "")" "falls back to the agent's RESOURCE_GROUP"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== SERVICES_RESOURCE_GROUP outranks the agent's RESOURCE_GROUP =="
(
  clear_env
  export SERVICES_RESOURCE_GROUP="rg-explicit"
  export RESOURCE_GROUP="rg-from-agent"
  assert_eq "rg-explicit" "$(placement_resource_group '{}' "")" "the service-specific name wins"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== location may legitimately resolve to empty =="
(
  clear_env
  assert_eq ""         "$(placement_location '{}' "")"                "unset everywhere is empty, not an error"
  assert_eq "westus2"  "$(placement_location "$PROVIDER_JSON" "")"    "provider location used"
  assert_eq "eastus"   "$(placement_location "$PROVIDER_JSON" "eastus")" "values wins"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== tfstate fields resolve independently =="
(
  clear_env
  assert_eq "sa-from-provider" "$(placement_tfstate_storage_account "$PROVIDER_JSON" "")" "storage account from provider"
  assert_eq "ct-from-provider" "$(placement_tfstate_container "$PROVIDER_JSON" "")"       "container from provider"
  export AZURE_TFSTATE_STORAGE_ACCOUNT="sa-env"
  export AZURE_TFSTATE_CONTAINER="ct-env"
  assert_eq "sa-env" "$(placement_tfstate_storage_account '{}' "")" "storage account from env"
  assert_eq "ct-env" "$(placement_tfstate_container '{}' "")"       "container from env"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== tfstate resource group defaults to the target resource group =="
(
  clear_env
  assert_eq "rg-tfstate-from-provider" "$(placement_tfstate_resource_group "$PROVIDER_JSON" "" "rg-target")" "provider wins"
  assert_eq "rg-target" "$(placement_tfstate_resource_group '{}' "" "rg-target")" "falls back to the target rg"
  assert_eq ""          "$(placement_tfstate_resource_group '{}' "" "")"          "no target rg yields empty"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== a provider missing the services block falls straight through =="
(
  clear_env
  ONLY_AUTH='{"authentication":{"subscription_id":"s"},"networking":{"domain_name":"d"}}'
  export RESOURCE_GROUP="rg-from-agent"
  assert_eq "rg-from-agent" "$(placement_resource_group "$ONLY_AUTH" "")" "no services block: env tier applies"
  assert_eq ""              "$(placement_location "$ONLY_AUTH" "")"       "no services block: location empty"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== placement_source labels the winning tier without echoing the value =="
assert_eq "values.yaml"       "$(placement_source "v" "p" "e")" "values"
assert_eq "provider"          "$(placement_source ""  "p" "e")" "provider"
assert_eq "agent-environment" "$(placement_source ""  ""  "e")" "environment"
assert_eq "unset"             "$(placement_source ""  ""  "")"  "nothing"

finish_tests
