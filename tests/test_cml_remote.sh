#!/usr/bin/env bash
# Runs scripts/lib/cml-remote.sh against tests/fake_cml_api.py.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/lib/cml-remote.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
PORT=18001
failures=0

python3 "${REPO_ROOT}/tests/fake_cml_api.py" "${PORT}" &
API_PID=$!
trap 'kill "${API_PID}" 2>/dev/null || true; rm -rf "${TMP}"' EXIT
sleep 1

printf 'CFG_APP_USER="admin"\nCFG_APP_PASS="secret"\n' > "${TMP}/vars.sh"
export CML_API="http://127.0.0.1:${PORT}/api/v0" VARS_FILE="${TMP}/vars.sh"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

out="$(bash "${SCRIPT}" list-labs)"
assert_eq "list-labs two lines" "2" "$(echo "${out}" | wc -l | tr -d ' ')"
assert_eq "list-labs first row" "$(printf 'lab-1\tSpine Leaf\tSTARTED')" "$(echo "${out}" | head -1)"

out="$(bash "${SCRIPT}" export-labs "${TMP}/exports")"
assert_eq "export message" "exported 2 labs to ${TMP}/exports" "${out}"
assert_eq "export file exists" "yes" "$([[ -f "${TMP}/exports/spine-leaf-lab-1.yaml" ]] && echo yes || echo no)"
assert_eq "export file content" "lab:" "$(head -1 "${TMP}/exports/spine-leaf-lab-1.yaml")"

out="$(bash "${SCRIPT}" stop-labs)"
assert_eq "stop-labs stops the started one" "stopped 1 labs" "${out}"
assert_eq "second stop is a no-op" "stopped 0 labs" "$(bash "${SCRIPT}" stop-labs)"

assert_eq "license-status registered" "REGISTERED" "$(bash "${SCRIPT}" license-status)"
assert_eq "deregister" "NOT_REGISTERED" "$(bash "${SCRIPT}" deregister)"
assert_eq "license-status after" "NOT_REGISTERED" "$(bash "${SCRIPT}" license-status)"

rc=0; bash "${SCRIPT}" bogus >/dev/null 2>&1 || rc=$?
assert_eq "unknown subcommand exits 2" "2" "${rc}"

if [[ "${failures}" -gt 0 ]]; then echo "test_cml_remote: ${failures} failure(s)"; exit 1; fi
echo "test_cml_remote: all passed"
