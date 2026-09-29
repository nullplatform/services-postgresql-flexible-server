#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A fake module so the test never touches a real provider.
mkdir -p "$TMP/module"
echo 'output "noop" { value = "noop" }' > "$TMP/module/main.tf"
echo 'marker' > "$TMP/module/MARKER"

run_do_tofu() {
  local action="$1"
  (
    export PATH="$SCRIPT_DIR/stub-bin:$PATH"
    export TOFU_STUB_LOG="$TMP/tofu.log"
    export OUTPUT_DIR="$TMP/out"
    mkdir -p "$OUTPUT_DIR"
    export TOFU_MODULE_DIR="$TMP/module"
    printf 'container_name = "np-service-1"\n' > "$OUTPUT_DIR/backend.hcl"
    export TOFU_VARIABLES='{"service_id":"svc-1","soft_delete_days":7}'
    export TOFU_ACTION="$action"
    bash "$SERVICE_PATH/scripts/azure/do_tofu" >/dev/null 2>&1
  )
}

echo "== apply =="
: > "$TMP/tofu.log"
run_do_tofu apply
LOG=$(cat "$TMP/tofu.log")
assert_contains "$LOG" "init" "runs tofu init"
assert_contains "$LOG" "-backend-config=backend.hcl" "init reads the backend settings from the file"
assert_contains "$LOG" "apply -auto-approve" "runs apply with -auto-approve"
assert_contains "$LOG" "-var-file=terraform.tfvars.json" "passes the tfvars file"

echo "== the module is copied into OUTPUT_DIR, not executed in place =="
assert_eq "marker" "$(cat "$TMP/out/MARKER" 2>/dev/null || echo missing)" "module files copied to OUTPUT_DIR"
if grep -q -- "-chdir" "$TMP/tofu.log"; then
  echo "  FAIL do_tofu used -chdir into the shared module directory" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "  ok   no -chdir into the shared module directory"
fi

echo "== tfvars are written as JSON =="
assert_eq "ok" "$(jq -e . "$TMP/out/terraform.tfvars.json" >/dev/null 2>&1 && echo ok || echo bad)" "terraform.tfvars.json is valid JSON"
assert_eq "svc-1" "$(jq -r '.service_id' "$TMP/out/terraform.tfvars.json")" "tfvars content written verbatim"
assert_eq "number" "$(jq -r '.soft_delete_days | type' "$TMP/out/terraform.tfvars.json")" "numeric types survive"

echo "== destroy =="
: > "$TMP/tofu.log"
run_do_tofu destroy
assert_contains "$(cat "$TMP/tofu.log")" "destroy -auto-approve" "runs destroy with -auto-approve"

echo "== a copied module never clobbers a file only OUTPUT_DIR has =="
: > "$TMP/tofu.log"
echo 'local_only = true' > "$TMP/out/sensitive.auto.tfvars"
run_do_tofu apply
assert_eq "local_only = true" "$(cat "$TMP/out/sensitive.auto.tfvars")" "OUTPUT_DIR-only files survive the copy"

echo "== NP_SKIP_TOFU=true skips tofu entirely (C1) =="
: > "$TMP/tofu.log"
(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" TOFU_STUB_LOG="$TMP/tofu.log"
  export OUTPUT_DIR="$TMP/out3"; mkdir -p "$OUTPUT_DIR"
  # Deliberately point at a module dir that does not exist, and an action of
  # destroy — exactly what the environment would look like inherited from an
  # earlier build_context after build_permissions_context's early exit. If
  # NP_SKIP_TOFU did not short-circuit, do_tofu's own module-dir check would
  # also refuse this, but the point of the test is that tofu is never even
  # considered: the stub log must stay empty.
  export TOFU_MODULE_DIR="$TMP/does-not-exist"
  printf 'container_name = "c"\n' > "$OUTPUT_DIR/backend.hcl"; export TOFU_VARIABLES='{}'
  export TOFU_ACTION=destroy
  export NP_SKIP_TOFU=true
  bash "$SERVICE_PATH/scripts/azure/do_tofu" >/dev/null 2>&1
) && SKIP_RC=0 || SKIP_RC=$?
assert_eq "0" "$SKIP_RC" "do_tofu exits 0 when NP_SKIP_TOFU=true"
assert_eq "0" "$(wc -l < "$TMP/tofu.log" | tr -d '[:space:]')" "tofu was never invoked when NP_SKIP_TOFU=true"

echo "== do_tofu refuses to run against a TOFU_MODULE_DIR that does not exist (defence in depth) =="
: > "$TMP/tofu.log"
(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" TOFU_STUB_LOG="$TMP/tofu.log"
  export OUTPUT_DIR="$TMP/out4"; mkdir -p "$OUTPUT_DIR"
  export TOFU_MODULE_DIR="$TMP/does-not-exist"
  printf 'container_name = "c"\n' > "$OUTPUT_DIR/backend.hcl"; export TOFU_VARIABLES='{}'
  export TOFU_ACTION=destroy
  unset NP_SKIP_TOFU
  bash "$SERVICE_PATH/scripts/azure/do_tofu" >/dev/null 2>&1
) && MISSING_RC=0 || MISSING_RC=$?
assert_eq "1" "$MISSING_RC" "do_tofu fails when TOFU_MODULE_DIR does not exist"
assert_eq "0" "$(wc -l < "$TMP/tofu.log" | tr -d '[:space:]')" "tofu was never invoked against a missing module dir"

echo "== TOFU_ACTION defaults to apply =="
: > "$TMP/tofu.log"
(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" TOFU_STUB_LOG="$TMP/tofu.log"
  export OUTPUT_DIR="$TMP/out2"; mkdir -p "$OUTPUT_DIR"
  printf 'container_name = "c"\n' > "$OUTPUT_DIR/backend.hcl"
  export TOFU_MODULE_DIR="$TMP/module" TOFU_VARIABLES='{}'
  unset TOFU_ACTION
  bash "$SERVICE_PATH/scripts/azure/do_tofu" >/dev/null 2>&1
)
assert_contains "$(cat "$TMP/tofu.log")" "apply -auto-approve" "missing TOFU_ACTION defaults to apply"

echo "== sin backend.hcl falla fuerte, sin correr tofu =="
: > "$TMP/tofu.log"
(
  export PATH="$SCRIPT_DIR/stub-bin:$PATH" TOFU_STUB_LOG="$TMP/tofu.log"
  export OUTPUT_DIR="$TMP/out-nobackend"; mkdir -p "$OUTPUT_DIR"
  export TOFU_MODULE_DIR="$TMP/module" TOFU_VARIABLES='{}' TOFU_ACTION=apply
  bash "$SERVICE_PATH/scripts/azure/do_tofu" >/dev/null 2>&1
) && RC=0 || RC=1
assert_eq "1" "$RC" "do_tofu falla cuando falta backend.hcl"
assert_eq "0" "$(grep -c "apply" "$TMP/tofu.log" || true)" "nunca llega a tofu apply sin backend"

finish_tests
