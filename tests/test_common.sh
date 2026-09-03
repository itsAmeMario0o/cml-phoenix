#!/usr/bin/env bash
# Tests for scripts/lib/common.sh. Runs on macOS bash 3.2.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "[OK]    ${label}"
  else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"
    failures=$((failures + 1))
  fi
}

# Each case runs in a subshell so counters and exit codes stay isolated.

out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; pass a; warn b; miss c; summary_and_exit" 2>&1 || true)"
assert_eq "summary counts" "summary: 1 OK, 1 WARN, 1 FAIL" "$(echo "${out}" | tail -1)"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; pass a; summary_and_exit" >/dev/null 2>&1 || rc=$?
assert_eq "exit 0 with no FAIL" "0" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; miss a; summary_and_exit" >/dev/null 2>&1 || rc=$?
assert_eq "exit 1 with a FAIL" "1" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_cmd bash definitely-not-a-command-xyz" >/dev/null 2>&1 || rc=$?
assert_eq "require_cmd fails on missing tool" "1" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_env NOT_SET_VAR_XYZ" >/dev/null 2>&1 || rc=$?
assert_eq "require_env fails on unset var" "1" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; ASSUME_YES=1 confirm 'go?'" >/dev/null 2>&1 || rc=$?
assert_eq "confirm honours ASSUME_YES" "0" "${rc}"

rc=0; echo "n" | bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; confirm 'go?'" >/dev/null 2>&1 || rc=$?
assert_eq "confirm returns 1 on n" "1" "${rc}"

out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; echo \"\${REPO_ROOT}\"")"
assert_eq "REPO_ROOT resolves" "${REPO_ROOT}" "${out}"

if [[ "${failures}" -gt 0 ]]; then
  echo "test_common: ${failures} failure(s)"
  exit 1
fi
echo "test_common: all passed"
