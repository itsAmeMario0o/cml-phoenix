#!/usr/bin/env bash
# Preflight is read-only, so the test runs it for real when RUN_AZ_TESTS=1
# and otherwise only checks the failure path that needs no Azure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/00-preflight.sh"
failures=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}

# Missing tfvars must be a FAIL line, not a crash, and the marker must not exist.
rm -f "${REPO_ROOT}/.preflight-ok"
out="$(CML_TFVARS="${REPO_ROOT}/does-not-exist.tfvars" bash "${SCRIPT}" 2>&1 || true)"
assert_contains "missing tfvars is a FAIL" "[FAIL]  config/cml.tfvars" "${out}"
assert_contains "summary line printed" "summary:" "${out}"
if [[ -f "${REPO_ROOT}/.preflight-ok" ]]; then
  echo "[FAIL]  marker written despite failure"; failures=$((failures + 1))
else
  echo "[OK]    no marker on failure"
fi

if [[ "${RUN_AZ_TESTS:-0}" == "1" ]]; then
  out="$(bash "${SCRIPT}" 2>&1 || true)"
  assert_contains "az login check ran" "azure login:" "${out}"
  assert_contains "quota check ran" "quota" "${out}"
fi

if [[ "${failures}" -gt 0 ]]; then echo "test_preflight: ${failures} failure(s)"; exit 1; fi
echo "test_preflight: all passed"
