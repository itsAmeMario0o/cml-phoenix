#!/usr/bin/env bash
# Runs scripts/lib/cml-remote.sh against tests/fake_cml_api.py.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/lib/cml-remote.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
PORT=18001
PORT_DEREGISTER_FAILS=18002
PORT_NO_LABS=18003
failures=0

python3 "${REPO_ROOT}/tests/fake_cml_api.py" "${PORT}" &
API_PID=$!
FAKE_DEREGISTER_FAILS=1 python3 "${REPO_ROOT}/tests/fake_cml_api.py" "${PORT_DEREGISTER_FAILS}" &
API_PID_DEREGISTER_FAILS=$!
FAKE_LABS=0 python3 "${REPO_ROOT}/tests/fake_cml_api.py" "${PORT_NO_LABS}" &
API_PID_NO_LABS=$!
trap 'kill "${API_PID}" "${API_PID_DEREGISTER_FAILS}" "${API_PID_NO_LABS}" 2>/dev/null || true; rm -rf "${TMP}"' EXIT
sleep 1

printf 'CFG_APP_USER="admin"\nCFG_APP_PASS="secret"\n' > "${TMP}/vars.sh"
export CML_API="http://127.0.0.1:${PORT}/api/v0" VARS_FILE="${TMP}/vars.sh"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

out="$(bash "${SCRIPT}" list-labs)"
assert_eq "list-labs three lines" "3" "$(echo "${out}" | wc -l | tr -d ' ')"
assert_eq "list-labs first row" "$(printf 'lab-1\tSpine Leaf\tSTARTED')" "$(echo "${out}" | head -1)"

out="$(bash "${SCRIPT}" export-labs "${TMP}/exports")"
assert_eq "export message" "exported 3 labs to ${TMP}/exports" "${out}"
assert_eq "export file exists" "yes" "$([[ -f "${TMP}/exports/spine-leaf-lab-1.yaml" ]] && echo yes || echo no)"
assert_eq "export file content" "lab:" "$(head -1 "${TMP}/exports/spine-leaf-lab-1.yaml")"
assert_eq "second lab export file exists" "yes" "$([[ -f "${TMP}/exports/trustsec-demo-lab-2.yaml" ]] && echo yes || echo no)"
assert_eq "slash-in-title export file exists" "yes" "$([[ -f "${TMP}/exports/vlan-trunk-demo-lab-3.yaml" ]] && echo yes || echo no)"

out="$(bash "${SCRIPT}" stop-labs)"
assert_eq "stop-labs stops the started one" "stopped 1 labs" "${out}"
assert_eq "second stop is a no-op" "stopped 0 labs" "$(bash "${SCRIPT}" stop-labs)"

assert_eq "license-status registered" "REGISTERED" "$(bash "${SCRIPT}" license-status)"
assert_eq "deregister" "NOT_REGISTERED" "$(bash "${SCRIPT}" deregister)"
assert_eq "license-status after" "NOT_REGISTERED" "$(bash "${SCRIPT}" license-status)"

rc=0; bash "${SCRIPT}" bogus >/dev/null 2>&1 || rc=$?
assert_eq "unknown subcommand exits 2" "2" "${rc}"

rc=0
out="$(CML_API="http://127.0.0.1:${PORT_DEREGISTER_FAILS}/api/v0" bash "${SCRIPT}" deregister)" || rc=$?
assert_eq "deregister failure exits 1" "1" "${rc}"
assert_eq "deregister failure prints REGISTERED" "REGISTERED" "${out}"

out="$(CML_API="http://127.0.0.1:${PORT_NO_LABS}/api/v0" bash "${SCRIPT}" list-labs)"
assert_eq "list-labs with no labs is empty" "" "${out}"
out="$(CML_API="http://127.0.0.1:${PORT_NO_LABS}/api/v0" bash "${SCRIPT}" export-labs "${TMP}/exports-empty")"
assert_eq "export-labs with no labs" "exported 0 labs to ${TMP}/exports-empty" "${out}"

if [[ "${failures}" -gt 0 ]]; then echo "test_cml_remote: ${failures} failure(s)"; exit 1; fi
echo "test_cml_remote: all passed"
