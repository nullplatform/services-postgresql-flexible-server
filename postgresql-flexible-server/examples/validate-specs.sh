#!/bin/bash
# Validates the service and link specs against the nullplatform skills checklist.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

SERVICE_SPEC="$SERVICE_PATH/specs/service-spec.json.tpl"
LINK_SPEC="$SERVICE_PATH/specs/links/connect.json.tpl"

echo "== spec files exist and are valid JSON =="
for f in "$SERVICE_SPEC" "$LINK_SPEC"; do
  if [ -f "$f" ]; then
    assert_eq "ok" "$(jq -e . "$f" >/dev/null 2>&1 && echo ok || echo bad)" "valid JSON: $(basename "$f")"
  else
    assert_eq "present" "missing" "file exists: $f"
  fi
done

echo "== schema lives in attributes.schema =="
assert_eq "object" "$(jq -r '.attributes.schema.type // "MISSING"' "$SERVICE_SPEC" 2>/dev/null)" "service schema type"
assert_eq "object" "$(jq -r '.attributes.schema.type // "MISSING"' "$LINK_SPEC" 2>/dev/null)" "link schema type"

echo "== specification_schema is absent =="
assert_eq "absent" "$(jq -e 'has("specification_schema")' "$SERVICE_SPEC" >/dev/null 2>&1 && echo present || echo absent)" "service has no specification_schema"
assert_eq "absent" "$(jq -e 'has("specification_schema")' "$LINK_SPEC" >/dev/null 2>&1 && echo present || echo absent)" "link has no specification_schema"

echo "== identity and selectors =="
assert_eq "postgresql-flexible-server" "$(jq -r '.slug' "$SERVICE_SPEC" 2>/dev/null)" "service slug"
assert_eq "dependency" "$(jq -r '.type' "$SERVICE_SPEC" 2>/dev/null)" "service type"
assert_eq "Azure" "$(jq -r '.selectors.provider' "$SERVICE_SPEC" 2>/dev/null)" "service provider selector"
assert_eq "Database" "$(jq -r '.selectors.category' "$SERVICE_SPEC" 2>/dev/null)" "service category selector"
assert_eq "connect" "$(jq -r '.available_links[0]' "$SERVICE_SPEC" 2>/dev/null)" "service declares the connect link"
assert_eq "connect" "$(jq -r '.slug' "$LINK_SPEC" 2>/dev/null)" "link slug"

echo "== required service attributes exist =="
for a in database_name postgres_version sku_name storage_mb backup_retention_days high_availability \
         hostname port server_name server_id resource_group_name; do
  assert_eq "present" "$(jq -e --arg a "$a" '.attributes.schema.properties[$a]' "$SERVICE_SPEC" >/dev/null 2>&1 && echo present || echo missing)" "service attribute $a"
done

echo "== the service required array is exactly the one input with no safe default =="
assert_eq "database_name" "$(jq -r '.attributes.schema.required | join(",")' "$SERVICE_SPEC" 2>/dev/null)" "service required array"

echo "== immutable inputs are editable on create only =="
for a in database_name postgres_version; do
  assert_eq "create" "$(jq -r --arg a "$a" '.attributes.schema.properties[$a].editableOn | join(",")' "$SERVICE_SPEC" 2>/dev/null)" "$a editable on create only"
done

echo "== output attributes are not editable =="
for a in hostname port server_name server_id resource_group_name; do
  assert_eq "0" "$(jq -r --arg a "$a" '.attributes.schema.properties[$a].editableOn | length' "$SERVICE_SPEC" 2>/dev/null)" "$a editableOn is empty"
done

echo "== exported service attributes =="
assert_eq "true" "$(jq -r '.attributes.schema.properties.hostname.export' "$SERVICE_SPEC" 2>/dev/null)" "hostname exported"
assert_eq "true" "$(jq -r '.attributes.schema.properties.port.export' "$SERVICE_SPEC" 2>/dev/null)" "port exported"
assert_eq "true" "$(jq -r '.attributes.schema.properties.database_name.export' "$SERVICE_SPEC" 2>/dev/null)" "database_name exported"
for a in server_name server_id resource_group_name; do
  assert_eq "false" "$(jq -r --arg a "$a" '.attributes.schema.properties[$a].export' "$SERVICE_SPEC" 2>/dev/null)" "$a not exported"
done

echo "== the administrator credentials never appear in the schema =="
for a in admin_login admin_password administrator_password administrator_login; do
  assert_eq "null" "$(jq -r --arg a "$a" '.attributes.schema.properties[$a]' "$SERVICE_SPEC" 2>/dev/null)" "$a absent from the service schema"
done

echo "== TLS is not user-editable =="
assert_eq "null" "$(jq -r '.attributes.schema.properties.require_secure_transport' "$SERVICE_SPEC" 2>/dev/null)" "require_secure_transport absent from schema"
assert_eq "null" "$(jq -r '.attributes.schema.properties.public_network_access' "$SERVICE_SPEC" 2>/dev/null)" "public_network_access absent from schema"

echo "== link attributes =="
for a in access_level username password jdbc_url; do
  assert_eq "present" "$(jq -e --arg a "$a" '.attributes.schema.properties[$a]' "$LINK_SPEC" >/dev/null 2>&1 && echo present || echo missing)" "link attribute $a"
done
assert_eq "admin" "$(jq -r '.attributes.schema.properties.access_level.default' "$LINK_SPEC" 2>/dev/null)" "access_level default"
assert_eq "read,read-write,admin" "$(jq -r '.attributes.schema.properties.access_level.enum | join(",")' "$LINK_SPEC" 2>/dev/null)" "access_level enum"
assert_eq "" "$(jq -r '.attributes.schema.required | join(",")' "$LINK_SPEC" 2>/dev/null)" "no required link input: access_level has a default"

echo "== link outputs land on the fixed DATABASE_* names the consuming apps read =="
assert_eq "DATABASE_USER"     "$(jq -r '.attributes.schema.properties.username.export.target' "$LINK_SPEC" 2>/dev/null)" "username -> DATABASE_USER"
assert_eq "DATABASE_PASSWORD" "$(jq -r '.attributes.schema.properties.password.export.target' "$LINK_SPEC" 2>/dev/null)" "password -> DATABASE_PASSWORD"
assert_eq "DATABASE_URL"      "$(jq -r '.attributes.schema.properties.jdbc_url.export.target' "$LINK_SPEC" 2>/dev/null)" "jdbc_url -> DATABASE_URL"
for a in username password jdbc_url; do
  assert_eq "environment_variable" "$(jq -r --arg a "$a" '.attributes.schema.properties[$a].export.type' "$LINK_SPEC" 2>/dev/null)" "$a exported as an environment variable"
  assert_eq "0" "$(jq -r --arg a "$a" '.attributes.schema.properties[$a].editableOn | length' "$LINK_SPEC" 2>/dev/null)" "$a is not editable"
done
assert_eq "true"  "$(jq -r '.attributes.schema.properties.password.export.secret' "$LINK_SPEC" 2>/dev/null)" "password exported as secret"
assert_eq "false" "$(jq -r '.attributes.schema.properties.username.export.secret' "$LINK_SPEC" 2>/dev/null)" "username is not a secret"
assert_eq "false" "$(jq -r '.attributes.schema.properties.jdbc_url.export.secret' "$LINK_SPEC" 2>/dev/null)" "jdbc_url is not a secret"

echo "== the link must not re-export service attributes =="
for a in hostname port database_name; do
  assert_eq "null" "$(jq -r --arg a "$a" '.attributes.schema.properties[$a]' "$LINK_SPEC" 2>/dev/null)" "link does not redeclare $a"
done

finish_tests
