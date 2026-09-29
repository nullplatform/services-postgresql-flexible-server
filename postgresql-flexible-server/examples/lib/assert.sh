#!/bin/bash
# Shared assertions for the bash test scripts in this directory.
# Sourced, never executed. Callers must call finish_tests last.

FAILURES="${FAILURES:-0}"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ok   $label"
  else
    echo "  FAIL $label" >&2
    echo "         expected: [$expected]" >&2
    echo "         actual:   [$actual]" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ok   $label"
  else
    echo "  FAIL $label" >&2
    echo "         missing: [$needle]" >&2
    echo "         in:      [$haystack]" >&2
    FAILURES=$((FAILURES + 1))
  fi
}

assert_fails() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "  FAIL $label (command unexpectedly succeeded)" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "  ok   $label"
  fi
}

finish_tests() {
  if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES assertion(s) failed" >&2
    exit 1
  fi
  echo "all assertions passed"
}
