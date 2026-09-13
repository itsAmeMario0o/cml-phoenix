#!/usr/bin/env bash
# Dry-run test for scripts/80-verify-lab.sh (Task 3, ADR 0009). No venv, no
# pyATS, and no live CML call: this runs on a fresh clone in the build lane
# (senior-secops: a real run writes a testbed that can carry device
# credentials, so the plan this test checks must never print one).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
RUN_SCRIPT="${REPO_ROOT}/scripts/80-verify-lab.sh"
SCENARIO="cilium-evpn"
LAB_TITLE="Cilium EVPN fabric (blank)"
VENV_DIR="${REPO_ROOT}/verify/.venv"
SCENARIO_DIR="${REPO_ROOT}/verify/${SCENARIO}"
JOBFILE="${SCENARIO_DIR}/jobfile.py"
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

# 80-verify-lab.sh checks the real verify/.venv and verify/<scenario>/
# paths directly, with no override variable (unlike ISE_ENV_FILE for the
# ISE scripts), so any real venv or scenario directory is moved aside
# rather than clobbered, and restored on exit.
VENV_SAVED=0
SCENARIO_SAVED=0
if [[ -e "${VENV_DIR}" ]]; then
  mv "${VENV_DIR}" "${VENV_DIR}.saved-test"
  VENV_SAVED=1
fi
if [[ -e "${SCENARIO_DIR}" ]]; then
  mv "${SCENARIO_DIR}" "${SCENARIO_DIR}.saved-test"
  SCENARIO_SAVED=1
fi

cleanup() {
  rm -rf "${VENV_DIR}" "${SCENARIO_DIR}" "${REPO_ROOT}/verify/.testbed"
  if [[ "${VENV_SAVED}" == "1" ]]; then
    mv "${VENV_DIR}.saved-test" "${VENV_DIR}"
  fi
  if [[ "${SCENARIO_SAVED}" == "1" ]]; then
    mv "${SCENARIO_DIR}.saved-test" "${SCENARIO_DIR}"
  fi
}
trap cleanup EXIT

# A fake venv is just a directory (the script only checks it exists) and
# a fake jobfile is a placeholder (easypy is never actually invoked; run()
# only echoes the plan in --dry-run).
mkdir -p "${VENV_DIR}" "${SCENARIO_DIR}"
echo "# fake jobfile, never executed by this test" > "${JOBFILE}"

rc=0
out="$(bash "${RUN_SCRIPT}" "${SCENARIO}" --dry-run 2>&1)" || rc=$?
assert_eq "dry run exits 0" "0" "${rc}"

assert_contains "gen_testbed.py planned" "+ python3 ${REPO_ROOT}/verify/lib/gen_testbed.py" "${out}"
assert_contains "gen_testbed.py gets the lab title from the YAML" "${LAB_TITLE}" "${out}"
assert_contains "gen_testbed.py writes to the scenario's testbed path" "${REPO_ROOT}/verify/.testbed/${SCENARIO}.yaml" "${out}"

assert_contains "easypy planned" "+ ${VENV_DIR}/bin/easypy" "${out}"
assert_contains "easypy runs the scenario's jobfile" "${JOBFILE}" "${out}"

# No CML credential appears anywhere. --dry-run never executes
# gen_testbed.py (run() only echoes the planned command), so the real
# config/mcp-env/cml.env is never even sourced here; these checks just
# confirm the plan line itself carries no credential-shaped content.
assert_not_contains "CML_PASSWORD var name never appears" "CML_PASSWORD" "${out}"
assert_not_contains "CML_USERNAME var name never appears" "CML_USERNAME" "${out}"

# An unknown scenario dies with a clear message and touches nothing.
rc=0
unknown_out="$(bash "${RUN_SCRIPT}" no-such-scenario --dry-run 2>&1)" || rc=$?
assert_eq "unknown scenario exits nonzero" "1" "${rc}"
assert_contains "unknown scenario names itself" "unknown scenario 'no-such-scenario'" "${unknown_out}"

if [[ "${failures}" -gt 0 ]]; then echo "test_verify_run: ${failures} failure(s)"; exit 1; fi
echo "test_verify_run: all passed"
