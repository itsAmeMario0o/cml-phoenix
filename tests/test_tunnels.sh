#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/50-tunnels.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
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

printf 'cockpit 19090 127.0.0.1 9090\nise 18443 10.20.2.10 443\n' > "${TMP}/tunnels.conf"
common="TUNNELS_CONF=${TMP}/tunnels.conf STATE_DIR=${TMP}/state"

# shellcheck disable=SC2086
out="$(env ${common} bash "${SCRIPT}" status 2>&1)"
assert_contains "status lists cockpit down" "cockpit: DOWN (localhost:19090)" "${out}"
assert_contains "status lists ise down" "ise: DOWN (localhost:18443)" "${out}"

rc=0
# shellcheck disable=SC2086
env ${common} bash "${SCRIPT}" bogus >/dev/null 2>&1 || rc=$?
assert_eq "bad usage exits 1" "1" "${rc}"

# shellcheck disable=SC2086
out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" env ${common} bash "${SCRIPT}" up --dry-run 2>&1)"
assert_contains "up plans the forward" "+ ssh -p 1122 -N -L 18443:10.20.2.10:443" "${out}"

rc=0; env TUNNELS_CONF="${TMP}/missing.conf" STATE_DIR="${TMP}/state" bash "${SCRIPT}" status >/dev/null 2>&1 || rc=$?
assert_eq "missing conf exits 1" "1" "${rc}"

if [[ "${failures}" -gt 0 ]]; then echo "test_tunnels: ${failures} failure(s)"; exit 1; fi
echo "test_tunnels: all passed"
