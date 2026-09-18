#!/usr/bin/env bash
# Shared assertion helpers for tests/test_*.sh. Source it, do not run it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/asserts.sh"
#
# Provides: failures (counter, starts at 0), assert_contains,
# assert_not_contains, assert_eq, line_of, assert_before, finish.

failures=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}

assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "[FAIL]  ${label}: found forbidden '${needle}'"; failures=$((failures + 1))
  else
    echo "[OK]    ${label}"
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

# line_of NEEDLE HAYSTACK: the 1-based line number of NEEDLE's first
# match in HAYSTACK, for ordering assertions ("A happened before B").
line_of() { grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1; }

# assert_before LABEL FIRST SECOND HAYSTACK: FIRST's first match comes
# before SECOND's, and both are present. For call order in a STUB_LOG.
assert_before() {
  local label="$1" a b
  a="$(line_of "$2" "$4")"; b="$(line_of "$3" "$4")"
  if [[ -n "${a}" && -n "${b}" && "${a}" -lt "${b}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: '$2' at line ${a:-none}, '$3' at line ${b:-none}"; failures=$((failures + 1)); fi
}

# finish NAME: the footer every test file ends with. Exit nonzero the
# moment any assertion failed, so tests/run.sh cannot mistake a partial
# pass for a clean one.
finish() {
  if [[ "${failures}" -gt 0 ]]; then
    echo "$1: ${failures} failure(s)"
    exit 1
  fi
  echo "$1: all passed"
}
