#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"
# shellcheck source=/dev/null
source "$SERVICE_PATH/scripts/azure/resolve_azure_credentials_lib"

PROVIDER_JSON='{"authentication":{"subscription_id":"sub-from-provider","client_id":"cli-from-provider","tenant_id":"ten-from-provider"}}'

echo "== sp_from_provider =="
HAPPY_TRIPLE=$(printf '%s%s%s%s%s' "sub-from-provider" "$NP_FS" "cli-from-provider" "$NP_FS" "ten-from-provider")
assert_eq "$HAPPY_TRIPLE" \
  "$(sp_from_provider "$PROVIDER_JSON")" "reads the authentication block"
EMPTY_TRIPLE=$(printf '%s%s' "$NP_FS" "$NP_FS")
assert_eq "$EMPTY_TRIPLE" "$(sp_from_provider '')" "empty input yields three empty fields"
assert_eq "$EMPTY_TRIPLE" "$(sp_from_provider '{}')" "empty object yields three empty fields"
assert_eq "$EMPTY_TRIPLE" "$(sp_from_provider 'not json at all')" "malformed input does not crash"
# Compare through `read` rather than against a literal separator string, so this
# assertion stays honest if the separator ever changes again.
(
  IFS="$NP_FS" read -r s c t <<< "$(sp_from_provider '{"authentication":{"subscription_id":"sub-only"}}')"
  assert_eq "sub-only" "$s" "partial provider data: subscription read back"
  assert_eq ""         "$c" "partial provider data: client empty"
  assert_eq ""         "$t" "partial provider data: tenant empty"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== values.yaml wins over everything =="
(
  export ARM_SUBSCRIPTION_ID="sub-from-env"
  out=$(resolve_azure_credentials "$PROVIDER_JSON" "sub-from-values" "cli-from-values" "ten-from-values")
  IFS="$NP_FS" read -r s c t <<< "$out"
  assert_eq "sub-from-values" "$s" "values.yaml beats env and provider (subscription)"
  assert_eq "cli-from-values" "$c" "values.yaml beats provider (client)"
  assert_eq "ten-from-values" "$t" "values.yaml beats provider (tenant)"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== provider wins when values.yaml is empty =="
(
  export ARM_SUBSCRIPTION_ID="sub-from-env"
  out=$(resolve_azure_credentials "$PROVIDER_JSON" "" "" "")
  IFS="$NP_FS" read -r s c t <<< "$out"
  assert_eq "sub-from-provider" "$s" "provider beats ambient env"
  assert_eq "cli-from-provider" "$c" "provider client used"
  assert_eq "ten-from-provider" "$t" "provider tenant used"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== ambient env is the last resort before MSI =="
(
  export ARM_SUBSCRIPTION_ID="sub-from-env"
  export ARM_CLIENT_ID="cli-from-env"
  export ARM_TENANT_ID="ten-from-env"
  out=$(resolve_azure_credentials '{}' "" "" "")
  IFS="$NP_FS" read -r s c t <<< "$out"
  assert_eq "sub-from-env" "$s" "ambient subscription used when nothing else set"
  assert_eq "cli-from-env" "$c" "ambient client used"
  assert_eq "ten-from-env" "$t" "ambient tenant used"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== a provider missing a MIDDLE field must not cross-assign (regression) =="
# This is the case that catches the IFS-whitespace collapsing bug: the provider
# supplies subscription_id and tenant_id but NOT client_id, so the packed triple
# has an empty middle field. With a tab separator, `read` collapsed it and the
# tenant value landed in the client slot, so ARM_CLIENT_ID was exported with a
# tenant id. Route it through the real `read`, not a raw string comparison.
PARTIAL_JSON='{"authentication":{"subscription_id":"prov-sub","tenant_id":"prov-tenant"}}'
(
  export ARM_CLIENT_ID="env-client"
  unset ARM_SUBSCRIPTION_ID ARM_TENANT_ID
  out=$(resolve_azure_credentials "$PARTIAL_JSON" "" "" "")
  IFS="$NP_FS" read -r s c t <<< "$out"
  assert_eq "prov-sub"    "$s" "middle-missing: provider subscription kept in the subscription slot"
  assert_eq "env-client"  "$c" "middle-missing: absent client falls through to the environment"
  assert_eq "prov-tenant" "$t" "middle-missing: provider tenant stays in the tenant slot"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== a provider missing the FIRST field must not shift the others left =="
LEADING_JSON='{"authentication":{"client_id":"prov-client","tenant_id":"prov-tenant"}}'
(
  export ARM_SUBSCRIPTION_ID="env-sub"
  unset ARM_CLIENT_ID ARM_TENANT_ID
  out=$(resolve_azure_credentials "$LEADING_JSON" "" "" "")
  IFS="$NP_FS" read -r s c t <<< "$out"
  assert_eq "env-sub"     "$s" "leading-missing: absent subscription falls through to the environment"
  assert_eq "prov-client" "$c" "leading-missing: provider client stays in the client slot"
  assert_eq "prov-tenant" "$t" "leading-missing: provider tenant stays in the tenant slot"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== nothing anywhere leaves everything empty (agent identity) =="
(
  unset ARM_SUBSCRIPTION_ID ARM_CLIENT_ID ARM_TENANT_ID
  out=$(resolve_azure_credentials '{}' "" "" "")
  assert_eq "$(printf '%s%s' "$NP_FS" "$NP_FS")" "$out" "all three fields empty"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== credential_source labels the winning branch =="
assert_eq "values.yaml"    "$(credential_source "v" "p" "e")" "values.yaml wins"
assert_eq "provider"       "$(credential_source ""  "p" "e")" "provider second"
assert_eq "environment"    "$(credential_source ""  ""  "e")" "environment third"
assert_eq "agent-identity" "$(credential_source ""  ""  "" )" "nothing set means agent identity"

echo "== the step degrades to agent identity and never fails =="
export NP_STUB_LOG="$(mktemp)"
export PATH="$SCRIPT_DIR/stub-bin:$PATH"
export CONTEXT='{"service":{"id":"svc-1","nrn":"organization=1:account=2:namespace=3","dimensions":{}}}'
export VALUES="$SERVICE_PATH/values.yaml"
STEP_OUT=$(bash "$SERVICE_PATH/scripts/azure/resolve_azure_credentials" 2>&1) || {
  echo "  FAIL step exited non-zero with no credentials available" >&2
  FAILURES=$((FAILURES + 1))
}
assert_contains "$STEP_OUT" "agent-identity" "step reports the agent-identity branch"
assert_contains "$(cat "$NP_STUB_LOG")" "provider list" "step queried the provider"
assert_contains "$(cat "$NP_STUB_LOG")" "--categories cloud-providers" "step used the cloud-providers category"
if grep -q -- "--limit" "$NP_STUB_LOG"; then
  echo "  FAIL step passed --limit alongside --categories" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   step did not pass --limit with --categories"
fi
rm -f "$NP_STUB_LOG"

finish_tests

echo "== the AZURE_* names the platform actually injects are read =="
# tofu-modules nullplatform/agent (v7.7.0) injects AZURE_SUBSCRIPTION_ID /
# AZURE_CLIENT_ID / AZURE_TENANT_ID / AZURE_CLIENT_SECRET into the agent pod.
# Reading only ARM_* — as this library originally did — meant a service on a
# real nullplatform Azure agent picked up nothing from its own environment.
(
  unset ARM_SUBSCRIPTION_ID ARM_CLIENT_ID ARM_TENANT_ID || true
  export AZURE_SUBSCRIPTION_ID="sub-from-agent"
  export AZURE_CLIENT_ID="cli-from-agent"
  export AZURE_TENANT_ID="ten-from-agent"
  out=$(resolve_azure_credentials '{}' "" "" "")
  IFS="$NP_FS" read -r s c t <<< "$out"
  assert_eq "sub-from-agent" "$s" "AZURE_SUBSCRIPTION_ID used"
  assert_eq "cli-from-agent" "$c" "AZURE_CLIENT_ID used"
  assert_eq "ten-from-agent" "$t" "AZURE_TENANT_ID used"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== ARM_* outranks AZURE_* when both are present =="
(
  export ARM_SUBSCRIPTION_ID="sub-arm"     AZURE_SUBSCRIPTION_ID="sub-azure"
  export ARM_CLIENT_ID="cli-arm"           AZURE_CLIENT_ID="cli-azure"
  export ARM_TENANT_ID="ten-arm"           AZURE_TENANT_ID="ten-azure"
  out=$(resolve_azure_credentials '{}' "" "" "")
  IFS="$NP_FS" read -r s c t <<< "$out"
  assert_eq "sub-arm" "$s" "explicit ARM_ wins over the platform's AZURE_"
  assert_eq "cli-arm" "$c" "client: ARM_ wins"
  assert_eq "ten-arm" "$t" "tenant: ARM_ wins"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== the client secret IS carried by the provider =="
# The module nullplatform/cloud/azure/cloud writes client_secret into
# .authentication, and its precondition requires all four together. An earlier
# version of this service assumed the provider never exposed it and skipped it,
# which half-applied the service principal and silently fell back to MSI.
WITH_SECRET='{"authentication":{"subscription_id":"s","client_id":"c","tenant_id":"t","client_secret":"shh"}}'
assert_eq "shh" "$(secret_from_provider "$WITH_SECRET")" "reads client_secret from the provider"
assert_eq ""    "$(secret_from_provider "$PROVIDER_JSON")" "absent secret is empty"
assert_eq ""    "$(secret_from_provider '')"               "empty input is empty"
assert_eq ""    "$(secret_from_provider 'not json')"       "malformed input does not crash"

echo "== the secret never travels in the packed triple =="
# sp_from_provider must keep returning exactly three fields, or every caller
# that unpacks it starts cross-assigning — and the fourth value would be a
# credential landing in ARM_TENANT_ID.
(
  IFS="$NP_FS" read -r s c t extra <<< "$(sp_from_provider "$WITH_SECRET")"
  assert_eq "s" "$s"  "subscription"
  assert_eq "c" "$c"  "client"
  assert_eq "t" "$t"  "tenant"
  assert_eq ""  "${extra:-}" "no fourth field: the secret is not in the triple"
  finish_tests
) || FAILURES=$((FAILURES + 1))

echo "== resolve_client_secret precedence: provider -> ARM_ -> AZURE_ =="
(
  unset ARM_CLIENT_SECRET AZURE_CLIENT_SECRET || true
  assert_eq "shh" "$(resolve_client_secret "$WITH_SECRET")" "provider wins"
  assert_eq ""    "$(resolve_client_secret '{}')"           "nothing anywhere is empty"
  export AZURE_CLIENT_SECRET="from-agent"
  assert_eq "from-agent" "$(resolve_client_secret '{}')"    "falls back to the agent's AZURE_CLIENT_SECRET"
  assert_eq "shh"        "$(resolve_client_secret "$WITH_SECRET")" "provider still beats the environment"
  export ARM_CLIENT_SECRET="from-arm"
  assert_eq "from-arm"   "$(resolve_client_secret '{}')"    "ARM_ beats AZURE_"
  finish_tests
) || FAILURES=$((FAILURES + 1))

finish_tests
