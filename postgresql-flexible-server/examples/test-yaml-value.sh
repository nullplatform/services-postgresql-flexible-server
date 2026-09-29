#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# yaml_value() is duplicated in every script that reads $VALUES — shell
# functions do not survive across workflow steps. Extract the copy from each
# and run the same cases against all of them, so the copies cannot drift.
SCRIPTS=(build_context resolve_azure_credentials)

cat > "$TMP/values.yaml" <<'EOF'
quoted_empty_with_comment: ""   # empty = resource_group_name
quoted_value_with_comment: "rg-real"   # a trailing note
bare_value_with_comment: rg-bare   # a trailing note
bare_value: rg-plain
quoted_empty: ""
quoted_with_spaces: "two words"
EOF

for s in "${SCRIPTS[@]}"; do
  echo "== yaml_value in $s =="
  awk '/^yaml_value\(\) \{/,/^\}/' "$SERVICE_PATH/scripts/azure/$s" > "$TMP/fn.sh"
  assert_eq "yes" "$([ -s "$TMP/fn.sh" ] && echo yes || echo no)" "$s: yaml_value found"
  # shellcheck source=/dev/null
  source "$TMP/fn.sh"

  # The regression: an inline comment after a quoted empty value must not
  # become the value. It used to return '"   # empty = resource_group_name',
  # which outranked every other resolution tier and landed in backend.hcl.
  assert_eq "FALLBACK" "$(yaml_value quoted_empty_with_comment FALLBACK "$TMP/values.yaml")" \
    "$s: quoted empty + inline comment falls back to the default"

  assert_eq "rg-real"   "$(yaml_value quoted_value_with_comment X "$TMP/values.yaml")" "$s: quoted value drops the comment"
  assert_eq "rg-bare"   "$(yaml_value bare_value_with_comment X "$TMP/values.yaml")"   "$s: bare value drops the comment"
  assert_eq "rg-plain"  "$(yaml_value bare_value X "$TMP/values.yaml")"                "$s: bare value"
  assert_eq "FALLBACK"  "$(yaml_value quoted_empty FALLBACK "$TMP/values.yaml")"       "$s: quoted empty is empty"
  assert_eq "two words" "$(yaml_value quoted_with_spaces X "$TMP/values.yaml")"        "$s: spaces inside quotes survive"
  assert_eq "FALLBACK"  "$(yaml_value absent_key FALLBACK "$TMP/values.yaml")"         "$s: missing key uses the default"
  assert_eq "FALLBACK"  "$(yaml_value any_key FALLBACK /nonexistent/file.yaml)"        "$s: missing file uses the default"
done

echo "== the shipped values.yaml parses to all-empty (it is a template) =="
awk '/^yaml_value\(\) \{/,/^\}/' "$SERVICE_PATH/scripts/azure/build_context" > "$TMP/fn.sh"
# shellcheck source=/dev/null
source "$TMP/fn.sh"
for k in subscription_id client_id tenant_id resource_group_name location allowed_ips \
         tfstate_storage_account tfstate_container tfstate_resource_group; do
  assert_eq "EMPTY" "$(yaml_value "$k" EMPTY "$SERVICE_PATH/values.yaml")" "shipped values.yaml: $k is empty"
done

finish_tests
