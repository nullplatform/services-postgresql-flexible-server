#!/bin/bash
# Runs every unit test and validator in this directory.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RC=0
for t in "$SCRIPT_DIR"/test-*.sh "$SCRIPT_DIR"/validate-specs.sh; do
  [ -f "$t" ] || continue
  echo "=== $(basename "$t") ==="
  if bash "$t"; then
    echo
  else
    echo "  ^^ FAILED" >&2
    RC=1
    echo
  fi
done

if [ "$RC" -ne 0 ]; then
  echo "SUITE FAILED" >&2
else
  echo "SUITE PASSED"
fi
exit "$RC"
