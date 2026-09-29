#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

MODULE="$SERVICE_PATH/permissions"

echo "== variables match what build_permissions_context emits =="
for v in link_id username access_level tfstate_resource_group_name tfstate_storage_account_name tfstate_container_name deployment_state_key; do
  assert_eq "present" "$(grep -q "variable \"$v\"" "$MODULE/variables.tf" 2>/dev/null && echo present || echo absent)" "variable $v declared"
done

echo "== every free-form string variable is validated =="
for v in link_id username tfstate_resource_group_name tfstate_storage_account_name tfstate_container_name deployment_state_key; do
  BLOCK=$(sed -n "/variable \"$v\"/,/^}/p" "$MODULE/variables.tf" 2>/dev/null)
  assert_contains "$BLOCK" "validation {" "variable $v carries a validation block"
done

echo "== the server coordinates and credentials come from the deployment state, not from variables =="
assert_eq "present" "$(grep -q 'data "terraform_remote_state" "deployment"' "$MODULE/main.tf" 2>/dev/null && echo present || echo absent)" "reads the deployment state"
assert_eq "present" "$(grep -q 'use_azuread_auth     = true' "$MODULE/main.tf" 2>/dev/null && echo present || echo absent)" "remote state authenticates via Azure AD"
assert_eq "absent" "$(grep -q 'variable "admin_password"\|variable "password"\|variable "hostname"' "$MODULE/variables.tf" 2>/dev/null && echo present || echo absent)" "no credential or hostname passed in as a variable"

echo "== the access level matrix covers all three levels =="
for level in '"read"' '"read-write"' '"admin"'; do
  assert_eq "present" "$(grep -q "$level" "$MODULE/locals.tf" 2>/dev/null && echo present || echo absent)" "locals map has $level"
done

echo "== read must not grant writes or CREATE =="
READ_BLOCK=$(sed -n '/"read" *= *{/,/^    }/p' "$MODULE/locals.tf" 2>/dev/null | tr -s ' ')
assert_contains "$READ_BLOCK" 'table = ["SELECT"]' "read grants SELECT only on tables"
assert_contains "$READ_BLOCK" 'database = ["CONNECT"]' "read grants CONNECT only on the database"
if printf '%s' "$READ_BLOCK" | grep -q 'CREATE\|INSERT\|UPDATE\|DELETE\|ALL'; then
  echo "  FAIL read grants a write or CREATE privilege" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   read grants no write or CREATE privilege"
fi

echo "== admin can create schemas and tables (what a migration tool needs) =="
ADMIN_BLOCK=$(sed -n '/"admin" *= *{/,/^    }/p' "$MODULE/locals.tf" 2>/dev/null | tr -s ' ')
assert_contains "$ADMIN_BLOCK" '"CREATE"' "admin grants CREATE"

echo "== the role is dropped without taking its objects along =="
assert_eq "present" "$(grep -q 'skip_reassign_owned = false' "$MODULE/main.tf" 2>/dev/null && echo present || echo absent)" "ownership is reassigned on drop"

echo "== the provider connects over TLS and not as a superuser =="
assert_eq "present" "$(grep -q 'sslmode = "require"' "$MODULE/providers.tf" 2>/dev/null && echo present || echo absent)" "sslmode=require"
assert_eq "present" "$(grep -q 'superuser       = false' "$MODULE/providers.tf" 2>/dev/null && echo present || echo absent)" "superuser=false, as Azure requires"
assert_eq "present" "$(grep -q 'cyrilgdn/postgresql' "$MODULE/providers.tf" 2>/dev/null && echo present || echo absent)" "postgresql provider declared"

echo "== the link password has no URL-reserved characters =="
LINK_PW=$(sed -n '/resource "random_password" "link"/,/^}/p' "$MODULE/main.tf" 2>/dev/null | tr -s ' ')
assert_contains "$LINK_PW" 'special = false' "link password is alphanumeric"

echo "== the JDBC URL requires TLS and carries no credentials =="
assert_eq "present" "$(grep -q 'sslmode=require' "$MODULE/locals.tf" 2>/dev/null && echo present || echo absent)" "jdbc_url has sslmode=require"
assert_eq "absent" "$(sed 's/#.*//' "$MODULE/locals.tf" | grep 'jdbc_url' | grep -q 'password' && echo present || echo absent)" "jdbc_url embeds no password"

echo "== outputs write_link_outputs depends on =="
for o in username password jdbc_url; do
  assert_eq "present" "$(grep -q "output \"$o\"" "$MODULE/outputs.tf" 2>/dev/null && echo present || echo absent)" "output $o declared"
done
assert_eq "present" "$(sed -n '/output "password"/,/^}/p' "$MODULE/outputs.tf" 2>/dev/null | grep -q 'sensitive   = true' && echo present || echo absent)" "password marked sensitive"

echo "== backend is static and azurerm =="
assert_eq "present" "$(grep -q 'backend "azurerm"' "$MODULE/backend.tf" 2>/dev/null && echo present || echo absent)" "azurerm backend in backend.tf"

if command -v tofu >/dev/null 2>&1; then
  echo "== fmt, init and validate =="
  assert_eq "formatted" "$(tofu fmt -check -recursive "$MODULE" >/dev/null 2>&1 && echo formatted || echo unformatted)" "tofu fmt -check passes"
  tofu -chdir="$MODULE" init -backend=false -input=false >/dev/null 2>&1 || true
  VOUT=$(tofu -chdir="$MODULE" validate 2>&1) && VRC=0 || VRC=$?
  assert_eq "0" "$VRC" "tofu validate succeeds"
  [ "$VRC" -eq 0 ] || echo "$VOUT" >&2
else
  echo "  skip tofu not installed"
fi

finish_tests
