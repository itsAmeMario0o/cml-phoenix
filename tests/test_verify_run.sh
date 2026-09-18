#!/usr/bin/env bash
# Dry-run test for scripts/80-verify-lab.sh (Task 3, ADR 0009). No venv, no
# pyATS, and no live CML call: this runs on a fresh clone in the build lane
# (senior-secops: a real run writes a testbed that can carry device
# credentials, so the plan this test checks must never print one). A fake
# cml.env exercises load_cml_env for real, the same fix that makes this
# script usable at all outside a test.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
RUN_SCRIPT="${REPO_ROOT}/scripts/80-verify-lab.sh"
SCENARIO="cilium-evpn"
LAB_TITLE="Cilium EVPN fabric (blank)"
VENV_DIR="${REPO_ROOT}/verify/.venv"
SCENARIO_DIR="${REPO_ROOT}/verify/${SCENARIO}"
JOBFILE="${SCENARIO_DIR}/jobfile.py"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
FAKE_PASSWORD="Sup3rSecretTestOnly-DoNotLeak"
printf 'CML_URL=https://198.51.100.9\nCML_USERNAME=admin\nCML_PASSWORD=%s\nCML_VERIFY_SSL=false\n' "${FAKE_PASSWORD}" > "${TMP}/cml.env"
export CML_ENV_FILE="${TMP}/cml.env" LAB_ENV_FILE="${TMP}/no-such-labs.env"
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

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
  rm -rf "${VENV_DIR}" "${SCENARIO_DIR}" "${REPO_ROOT}/verify/.testbed" "${TMP}"
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
# Without these two flags easypy writes under ~/.pyats, outside the repo,
# and the archive can carry the test AAA password in clear text.
assert_contains "easypy archive stays in the repo" "-archive_dir ${REPO_ROOT}/verify/.archive" "${out}"
assert_contains "easypy runinfo stays in the repo" "-runinfo_dir ${REPO_ROOT}/verify/.runinfo" "${out}"
assert_contains "archive and runinfo directories are private" "+ mkdir -p -m 0700 ${REPO_ROOT}/verify/.archive ${REPO_ROOT}/verify/.runinfo" "${out}"
assert_contains "the run ends with the summary" "summary: " "${out}"

# cml.env is genuinely loaded and exported now (the fix for the bug this
# test exists to catch: 80-verify-lab.sh used to never load it at all).
# --dry-run never executes gen_testbed.py itself (run() only echoes the
# planned command), so confirm the loaded password never reaches the
# printed plan line, by name or by value.
assert_not_contains "CML_PASSWORD var name never appears" "CML_PASSWORD" "${out}"
assert_not_contains "CML_USERNAME var name never appears" "CML_USERNAME" "${out}"
assert_not_contains "loaded password value never appears" "${FAKE_PASSWORD}" "${out}"

# An unknown scenario dies with a clear message and touches nothing.
rc=0
unknown_out="$(bash "${RUN_SCRIPT}" no-such-scenario --dry-run 2>&1)" || rc=$?
assert_eq "unknown scenario exits nonzero" "1" "${rc}"
assert_contains "unknown scenario names itself" "unknown scenario 'no-such-scenario'" "${unknown_out}"

finish "test_verify_run"
