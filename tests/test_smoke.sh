#!/usr/bin/env bash
# The smoke test needs a live host. Here we only prove it fails cleanly when
# there is no state, and that it never crashes past the first check.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/90-smoke-test.sh"
chmod +x "${REPO_ROOT}/tests/stubs/"*
failures=0
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

rc=0; out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" TF_STUB_FAIL=1 bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "no state exits 1" "1" "${rc}"
assert_contains "explains" "persistent output public_ip_address" "${out}"
assert_contains "summary printed" "summary:" "${out}"

if [[ "${failures}" -gt 0 ]]; then echo "test_smoke: ${failures} failure(s)"; exit 1; fi
echo "test_smoke: all passed"
