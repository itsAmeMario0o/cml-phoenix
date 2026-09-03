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

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "[OK]    ${label}"
  else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"
    failures=$((failures + 1))
  fi
}

# sas_seconds is a pure parser; source the script (common.sh's counters are
# harmless here) to unit test it directly without touching Azure.
sas_of() { bash -c "source '${SCRIPT}'; sas_seconds '$1'"; }
assert_eq "sas_seconds 4h" "14400" "$(sas_of 4h)"
assert_eq "sas_seconds 4h30m" "16200" "$(sas_of 4h30m)"
assert_eq "sas_seconds 30m" "1800" "$(sas_of 30m)"
assert_eq "sas_seconds 240" "240" "$(sas_of 240)"
assert_eq "sas_seconds abc" "0" "$(sas_of abc)"
assert_eq "sas_seconds 4h30 (missing trailing m)" "0" "$(sas_of 4h30)"

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
