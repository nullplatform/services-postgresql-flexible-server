#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_PATH="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/assert.sh"

WF="$SERVICE_PATH/workflows/azure"

echo "== every workflow the handlers can dispatch to exists =="
for w in create update delete read link link-update unlink; do
  assert_eq "present" "$([ -f "$WF/$w.yaml" ] && echo present || echo absent)" "$w.yaml exists"
done

echo "== every workflow is valid YAML =="
for f in "$WF"/*.yaml; do
  assert_eq "ok" "$(python3 -c "import yaml,sys; yaml.safe_load(open('$f')); print('ok')" 2>/dev/null || echo bad)" "valid YAML: $(basename "$f")"
done

echo "== every referenced script exists and is executable =="
MISSING=""
for f in "$WF"/*.yaml; do
  while read -r script; do
    [ -n "$script" ] || continue
    resolved="${script/\$SERVICE_PATH/$SERVICE_PATH}"
    if [ ! -x "$resolved" ]; then
      MISSING="$MISSING $(basename "$f"):$script"
    fi
  done < <(python3 -c "
import yaml,sys
d = yaml.safe_load(open('$f')) or {}
for s in (d.get('steps') or []):
    if s.get('file'):
        print(s['file'])
")
done
assert_eq "" "$MISSING" "all referenced step scripts exist and are executable"

steps_of() {
  python3 -c "
import yaml
d = yaml.safe_load(open('$WF/$1.yaml'))
print('|'.join(s['name'] for s in d['steps']))
"
}

tofu_action_of() {
  python3 -c "
import yaml
d = yaml.safe_load(open('$WF/$1.yaml'))
print([s for s in d['steps'] if s['name']=='tofu'][0]['configuration']['TOFU_ACTION'])
"
}

echo "== create and update resolve credentials, build context, apply, write outputs =="
for w in create update; do
  assert_eq "resolve azure credentials|build context|tofu|write service outputs" "$(steps_of "$w")" "$w step order"
  assert_eq "apply" "$(tofu_action_of "$w")" "$w uses TOFU_ACTION=apply"
done

echo "== delete destroys =="
assert_eq "resolve azure credentials|build context|tofu" "$(steps_of delete)" "delete step order"
assert_eq "destroy" "$(tofu_action_of delete)" "delete uses TOFU_ACTION=destroy"

echo "== link builds the permissions context before applying =="
assert_eq "resolve azure credentials|build context|build permissions context|tofu|write link outputs" "$(steps_of link)" "link step order"

echo "== link-update and unlink reuse link.yaml through include =="
for w in link-update unlink; do
  INC=$(python3 -c "
import yaml
d = yaml.safe_load(open('$WF/$w.yaml')) or {}
print(','.join(d.get('include') or []))
")
  assert_contains "$INC" "workflows/azure/link.yaml" "$w includes link.yaml"
  REPLACE=$(python3 -c "
import yaml
d = yaml.safe_load(open('$WF/$w.yaml')) or {}
print(','.join(s.get('action','') for s in (d.get('steps') or [])))
")
  assert_contains "$REPLACE" "replace" "$w replaces a step rather than redefining the workflow"
done
assert_eq "destroy" "$(tofu_action_of unlink)" "unlink destroys the link's module"
assert_eq "apply" "$(tofu_action_of link-update)" "link-update applies"

echo "== read.yaml must not run tofu: a read may not touch Azure =="
READ_RUNS_TOFU=$(python3 -c "
import yaml
d = yaml.safe_load(open('$WF/read.yaml'))
print(any('do_tofu' in (s.get('file') or '') for s in d['steps']))
")
assert_eq "False" "$READ_RUNS_TOFU" "read.yaml invokes no tofu step"
assert_eq "build context|read current state" "$(steps_of read)" "read.yaml step order"

echo "== credential variables are declared as step outputs or they never propagate =="
for w in create update delete link; do
  OUTS=$(python3 -c "
import yaml
d = yaml.safe_load(open('$WF/$w.yaml'))
s = [x for x in d['steps'] if x['name']=='resolve azure credentials'][0]
print(' '.join(o['name'] for o in s.get('output') or []))
")
  for v in ARM_SUBSCRIPTION_ID ARM_CLIENT_ID ARM_TENANT_ID ARM_CLIENT_SECRET; do
    assert_contains "$OUTS" "$v" "$w declares $v as a step output"
  done
done

echo "== build_context declares the variables do_tofu needs =="
for w in create update delete; do
  OUTS=$(python3 -c "
import yaml
d = yaml.safe_load(open('$WF/$w.yaml'))
s = [x for x in d['steps'] if x['name']=='build context'][0]
print(' '.join(o['name'] for o in s.get('output') or []))
")
  for v in OUTPUT_DIR TOFU_MODULE_DIR TOFU_INIT_VARIABLES TOFU_VARIABLES; do
    assert_contains "$OUTS" "$v" "$w declares $v"
  done
done

echo "== link declares everything build_permissions_context needs =="
LINK_OUTS=$(python3 -c "
import yaml
d = yaml.safe_load(open('$WF/link.yaml'))
s = [x for x in d['steps'] if x['name']=='build context'][0]
print(' '.join(o['name'] for o in s.get('output') or []))
")
for v in LINK_ID LINK_USERNAME LINK_ACCESS_LEVEL TFSTATE_CONTAINER TFSTATE_STORAGE_ACCOUNT TFSTATE_RESOURCE_GROUP TFSTATE_KEY; do
  assert_contains "$LINK_OUTS" "$v" "link declares $v"
done

echo "== the early-exit flag is declared so it reaches do_tofu =="
PERM_OUTS=$(python3 -c "
import yaml
d = yaml.safe_load(open('$WF/link.yaml'))
s = [x for x in d['steps'] if x['name']=='build permissions context'][0]
print(' '.join(o['name'] for o in s.get('output') or []))
")
assert_contains "$PERM_OUTS" "NP_SKIP_TOFU" "link declares NP_SKIP_TOFU"

finish_tests
