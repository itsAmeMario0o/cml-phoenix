#!/usr/bin/env bash
# Runs scripts/60-import-lab.sh against tests/fake_cml_api.py, plus a
# dry run and the failure paths (missing env file, bad credentials).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/60-import-lab.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
PORT=18005
failures=0

python3 "${REPO_ROOT}/tests/fake_cml_api.py" "${PORT}" &
API_PID=$!
trap 'kill "${API_PID}" 2>/dev/null || true; rm -rf "${TMP}" "${REPO_ROOT}/exports/.rendered/demo-lab.yaml"' EXIT
sleep 1

printf 'CML_URL=http://127.0.0.1:%s\nCML_USERNAME=admin\nCML_PASSWORD=secret\nCML_VERIFY_SSL=false\n' "${PORT}" > "${TMP}/cml.env"
printf 'LAB_PASSWORD=Sekret1\n' > "${TMP}/labs.env"
printf 'ssh-ed25519 AAAATESTKEY demo@example\n' > "${TMP}/key.pub"
printf 'lab:\n  title: Demo Lab\nnodes:\n- id: n0\n  configuration:\n  - name: c\n    content: |\n      username admin password __LAB_PASSWORD__\n      key __LAB_SSH_PUBKEY__\n' > "${TMP}/demo-lab.yaml"
export CML_ENV_FILE="${TMP}/cml.env" LAB_ENV_FILE="${TMP}/labs.env" PUBKEY_FILE="${TMP}/key.pub"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}

out="$(bash "${SCRIPT}" "${TMP}/demo-lab.yaml" --dry-run 2>&1)"
assert_contains "dry run renders" "+ python3 ${REPO_ROOT}/scripts/lib/render_lab.py ${TMP}/demo-lab.yaml" "${out}"
assert_contains "dry run posts with encoded title" "+ curl -X POST http://127.0.0.1:${PORT}/api/v0/import?title=Demo%20Lab" "${out}"
assert_contains "dry run summary" "would import 'Demo Lab'" "${out}"
if grep -qF "Sekret1" <<<"${out}"; then echo "[FAIL]  dry run leaked the lab password"; failures=$((failures + 1)); else
  echo "[OK]    dry run keeps the lab password out of its output"; fi

out="$(bash "${SCRIPT}" "${TMP}/demo-lab.yaml" 2>&1)"
assert_contains "import reports the lab id" "imported 'Demo Lab' as lab lab-new, stopped" "${out}"
rendered="${REPO_ROOT}/exports/.rendered/demo-lab.yaml"
assert_eq "rendered copy exists" "yes" "$([[ -f "${rendered}" ]] && echo yes || echo no)"
assert_eq "rendered copy is private" "600" "$(stat -f %Lp "${rendered}" 2>/dev/null || stat -c %a "${rendered}")"
assert_contains "rendered copy has the password" "username admin password Sekret1" "$(cat "${rendered}")"
assert_contains "fake api received the rendered body" "username admin password Sekret1" "$(curl -s -H 'Authorization: Bearer FAKE-TOKEN' "http://127.0.0.1:${PORT}/api/v0/labs/lab-new/download")"

rc=0; out="$(LAB_ENV_FILE="${TMP}/missing.env" bash "${SCRIPT}" "${TMP}/demo-lab.yaml" 2>&1)" || rc=$?
assert_eq "missing labs.env exits 1" "1" "${rc}"
assert_contains "missing labs.env names the file" "${TMP}/missing.env missing" "${out}"

printf 'CML_URL=http://127.0.0.1:%s\nCML_USERNAME=admin\nCML_PASSWORD=wrong\n' "${PORT}" > "${TMP}/bad.env"
rc=0; out="$(CML_ENV_FILE="${TMP}/bad.env" bash "${SCRIPT}" "${TMP}/demo-lab.yaml" 2>&1)" || rc=$?
assert_eq "bad credentials exit 1" "1" "${rc}"
assert_contains "bad credentials message" "authentication to http://127.0.0.1:${PORT} failed" "${out}"

rc=0; bash "${SCRIPT}" >/dev/null 2>&1 || rc=$?
assert_eq "no argument exits 2" "2" "${rc}"

if [[ "${failures}" -gt 0 ]]; then echo "test_import_lab: ${failures} failure(s)"; exit 1; fi
echo "test_import_lab: all passed"
