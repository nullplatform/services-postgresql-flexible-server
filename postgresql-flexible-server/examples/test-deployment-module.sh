#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

MODULE="$SERVICE_PATH/deployment"

echo "== the module takes typed variables, not a context blob =="
assert_eq "absent" "$(grep -q 'variable "context"' "$MODULE/variables.tf" && echo present || echo absent)" "no var.context"
assert_eq "absent" "$(grep -q 'jsondecode' "$MODULE"/*.tf && echo present || echo absent)" "no jsondecode of a notification"
for v in service_id server_name resource_group_name location database_name postgres_version \
         sku_name storage_mb backup_retention_days high_availability allowed_ips tags; do
  assert_eq "present" "$(grep -q "variable \"$v\"" "$MODULE/variables.tf" && echo present || echo absent)" "variable $v declared"
done

echo "== every free-form REQUIRED string variable is validated, mirroring build_context =="
for v in service_id server_name resource_group_name database_name; do
  BLOCK=$(sed -n "/variable \"$v\"/,/^}/p" "$MODULE/variables.tf")
  assert_contains "$BLOCK" "validation {" "variable $v carries a validation block"
done

echo "== location is optional and falls back to the resource group =="
LOC_BLOCK=$(sed -n '/variable "location"/,/^}/p' "$MODULE/variables.tf")
assert_contains "$LOC_BLOCK" 'default     = ""' "location defaults to empty"
assert_contains "$(cat "$MODULE/main.tf")" 'data "azurerm_resource_group" "target"' "main.tf reads the resource group"
assert_contains "$(cat "$MODULE/main.tf")" 'data.azurerm_resource_group.target.location' "the fallback uses the resource group's location"

echo "== TLS is enforced and not variable =="
assert_eq "present" "$(grep -q 'require_secure_transport' "$MODULE/main.tf" && echo present || echo absent)" "require_secure_transport configured"
assert_eq "present" "$(grep -A3 'name      = "require_secure_transport"' "$MODULE/main.tf" | grep -q 'value     = "on"' && echo present || echo absent)" "require_secure_transport is on"
assert_eq "absent" "$(grep -q 'variable "require_secure_transport"' "$MODULE/variables.tf" && echo present || echo absent)" "require_secure_transport is not a variable"

echo "== the administrator password is generated, never taken as input =="
assert_eq "present" "$(grep -q 'resource "random_password" "admin"' "$MODULE/main.tf" && echo present || echo absent)" "random_password.admin exists"
assert_eq "absent" "$(grep -q 'variable "admin_password"\|variable "administrator_password"' "$MODULE/variables.tf" && echo present || echo absent)" "no password variable"

echo "== the firewall is data-driven and never open to the world =="
assert_eq "present" "$(grep -q 'azurerm_postgresql_flexible_server_firewall_rule' "$MODULE/main.tf" && echo present || echo absent)" "firewall rules declared"
assert_eq "absent" "$(sed 's/#.*//' "$MODULE"/*.tf | grep -q '0\.0\.0\.0' && echo present || echo absent)" "no 0.0.0.0 rule"
assert_eq "absent" "$(sed 's/#.*//' "$MODULE"/*.tf | grep -q '255\.255\.255\.255' && echo present || echo absent)" "no 255.255.255.255 rule"

echo "== the name is never recomputed inside the module =="
assert_eq "present" "$(grep -q 'name                = var.server_name' "$MODULE/main.tf" && echo present || echo absent)" "server name comes straight from the variable"

echo "== outputs the write_service_outputs step and the permissions module depend on =="
for o in hostname port database_name server_name server_id resource_group_name admin_login admin_password; do
  assert_eq "present" "$(grep -q "output \"$o\"" "$MODULE/outputs.tf" && echo present || echo absent)" "output $o declared"
done
assert_eq "present" "$(sed -n '/output "admin_password"/,/^}/p' "$MODULE/outputs.tf" | grep -q 'sensitive   = true' && echo present || echo absent)" "admin_password marked sensitive"

echo "== backend is static, azurerm, and unconfigured =="
assert_eq "present" "$(grep -q 'backend "azurerm"' "$MODULE/backend.tf" && echo present || echo absent)" "azurerm backend declared in backend.tf"

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
