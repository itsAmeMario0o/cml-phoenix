#!/usr/bin/env bash
# The smoke test needs a live host. Here we only prove it fails cleanly when
# there is no state, and that it never crashes past the first check.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/90-smoke-test.sh"
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

rc=0; out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" TF_STUB_FAIL=1 bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "no state exits 1" "1" "${rc}"
assert_contains "explains" "persistent output public_ip_address" "${out}"
assert_contains "summary printed" "summary:" "${out}"

# The transit bridge (ADR 0003) needs a live controller, so its SSH checks
# cannot run here. Assert the checks exist in the source instead.
src="$(cat "${SCRIPT}")"
assert_contains "check_transit_bridge defined" "check_transit_bridge() {" "${src}"
assert_contains "check_transit_bridge called from main" "  check_transit_bridge" "${src}"
assert_contains "checks bridge1 address exactly" "10.100.0.1/24" "${src}"
assert_contains "checks ip_forward" "net.ipv4.ip_forward" "${src}"

# check_forward (ADR 0012): with a cml.env whose CML_API_BASE port is
# closed, the check is one [FAIL] naming 50-tunnels.sh up, and the script
# carries on to the next check instead of exiting. 18017 is left closed.
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
printf 'CML_URL=https://203.0.113.5\nCML_API_BASE=http://127.0.0.1:18017\nCML_USERNAME=admin\nCML_PASSWORD=secret\n' > "${TMP}/cml.env"
out="$(CML_ENV_FILE="${TMP}/cml.env" LAB_ENV_FILE="${TMP}/no-labs.env" bash -c "
  source '${SCRIPT}'
  check_forward
  echo still-running
" 2>&1)"
assert_contains "forward down is a [FAIL]" "[FAIL]  CML API forward not up on 127.0.0.1:18017. Run: scripts/50-tunnels.sh up" "${out}"
assert_contains "forward down does not stop the smoke test" "still-running" "${out}"
assert_not_contains "no public address in the forward check" "203.0.113.5" "${out}"

# check_api asks the host over cml_ssh, never the public address with -k.
# The literal ${IP} is the source text being searched for, on purpose.
# shellcheck disable=SC2016
assert_not_contains "no local curl -k against the public IP" 'curl -sk -m 10 "https://${IP}' "${src}"
assert_contains "check_api uses cml_api_ready" "if cml_api_ready; then" "${src}"

finish "test_smoke"
