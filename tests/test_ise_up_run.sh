#!/usr/bin/env bash
# scripts/25-ise-up.sh --post-deploy with dry run OFF, against the
# stubbed az, terraform, ssh and sleep (tests/stubs). The readiness loop
# runs for real: the ssh stub plays the remote curl's http_code per call
# from SSH_STUB_HTTP_SEQ and the sleep stub returns at once, logging the
# interval it was asked for. ise_config.py is replaced by a logging
# python3 on PATH so nothing dials the forwarded port.
# tests/test_ise_dry_run.sh still covers the printed plan.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/25-ise-up.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

LOG="${TMP}/calls.log"
FAKE_PASSWORD="Sup3rSecretTestOnly-DoNotLeak"
FAKE_RADIUS_SECRET="Sup3rRadiusTestOnly-DoNotLeak"
cat > "${TMP}/ise.env" <<EOF
ISE_HOSTNAME=ise1
ISE_PRIVATE_IP=10.20.2.20
ISE_ADMIN_SOURCE_CIDR=10.20.1.10/32
ISE_ADMIN_PASSWORD=${FAKE_PASSWORD}
RADIUS_SECRET=${FAKE_RADIUS_SECRET}
EOF
mkdir -p "${TMP}/bin"
# The $* and ${STUB_LOG} below are the fake python3's own, on purpose.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "python3 $*" >> "${STUB_LOG}"\n' > "${TMP}/bin/python3"
chmod +x "${TMP}/bin/python3"

# run_up [ENV=VALUE...]: the script for real, calls logged, the timeout
# cut to three polls at the script's own 30 s interval. Sets rc, out, log.
run_up() {
  rm -f "${LOG}"; rc=0
  out="$(PATH="${TMP}/bin:${REPO_ROOT}/tests/stubs:${PATH}" STUB_LOG="${LOG}" \
    ARM_SUBSCRIPTION_ID=x ASSUME_YES=1 ISE_ENV_FILE="${TMP}/ise.env" AD_ENV="${TMP}/no-ad.env" \
    ISE_READY_TIMEOUT_S=90 env "$@" bash "${SCRIPT}" --post-deploy 2>&1)" || rc=$?
  log="$(cat "${LOG}" 2>/dev/null || true)"
}

# 1. ISE answers 000 (refused), then 502 (front end up, application not),
#    then 200. The script waits through the first two and proceeds after
#    the third, at the interval it promised.
run_up SSH_STUB_HTTP_SEQ="000 502 200"
assert_eq "000, 502, 200 exits 0" "0" "${rc}"
assert_contains "ready after the 200" "[OK]    ISE answered (HTTP 200) after 1m0s" "${out}"
assert_contains "finishes" "[OK]    ISE ready." "${out}"
assert_eq "three polls" "3" "$(grep -c 'http_code' <<<"${log}")"
assert_eq "two sleeps of the configured interval" "2" "$(grep -c '^sleep 30$' <<<"${log}")"
assert_before "jump proven before the first poll" "sysadmin@203.0.113.5 true" "http_code" "${log}"
assert_before "nsg attached before the tagging" "az network nic update" "az resource tag" "${log}"
assert_before "tagging before the wait" "az disk update" "http_code" "${log}"
assert_before "forward opened after the 200" "http_code" "-N -L 18443:10.20.2.20:443 sysadmin@203.0.113.5" "${log}"
assert_before "policy applied through the forward" "-N -L 18443" "python3 ${REPO_ROOT}/scripts/lib/ise_config.py" "${log}"
assert_eq "policy applied once" "1" "$(grep -c 'ise_config.py' <<<"${log}")"
assert_not_contains "admin password never on a command line" "${FAKE_PASSWORD}" "${log}"
assert_not_contains "radius secret never on a command line" "${FAKE_RADIUS_SECRET}" "${log}"
assert_not_contains "admin password never printed" "${FAKE_PASSWORD}" "${out}"
assert_not_contains "no 0.0.0.0/0 in any rule" "0.0.0.0/0" "${log}"

# 2. Only 502s: the timeout is a [FAIL], the forward never opens, the
#    policy is never applied.
run_up SSH_STUB_HTTP_SEQ="502"
assert_eq "502 forever exits 1" "1" "${rc}"
assert_contains "502 forever times out" "[FAIL]  ISE did not answer within 1 minutes" "${out}"
assert_not_contains "502 forever never opens the forward" "-N -L" "${log}"
assert_not_contains "502 forever never applies policy" "ise_config.py" "${log}"
assert_not_contains "502 forever never claims ready" "ISE ready." "${out}"

# 3. A dead jump host (every ssh exits 255) is told apart from ISE still
#    booting: one failed ssh, a [FAIL] naming the jump, no poll, no wait.
run_up SSH_STUB_EXIT=255
assert_eq "dead jump exits 1" "1" "${rc}"
assert_contains "dead jump names the jump" "[FAIL]  CML host jump 203.0.113.5 does not answer on port 1122" "${out}"
assert_eq "dead jump: no poll" "0" "$(grep -c 'http_code' <<<"${log}" || true)"
assert_eq "dead jump: no sleep" "0" "$(grep -c '^sleep' <<<"${log}" || true)"
assert_not_contains "dead jump never says still waiting" "still waiting" "${out}"

# 4. The RADIUS rule cannot be created: exit 1, no [OK], nothing tagged,
#    no wait.
run_up AZ_STUB_FAIL="network nsg rule create"
assert_eq "failed nsg rule exits 1" "1" "${rc}"
assert_not_contains "failed nsg rule never claims success" "[OK]" "${out}"
assert_contains "az's error reaches the operator" "az stub: 'network nsg rule create' failed" "${out}"
assert_not_contains "failed nsg rule: nic never updated" "az network nic update" "${log}"
assert_not_contains "failed nsg rule: nothing tagged" "az resource tag" "${log}"
assert_not_contains "failed nsg rule: no wait" "http_code" "${log}"

# 5. The disk tag fails after the NSG is attached: exit 1, no wait.
run_up AZ_STUB_FAIL="disk update"
assert_eq "failed disk tag exits 1" "1" "${rc}"
assert_contains "failed disk tag: nsg was attached first" "az network nic update" "${log}"
assert_not_contains "failed disk tag: no wait" "http_code" "${log}"
assert_not_contains "failed disk tag never claims success" "[OK]" "${out}"

finish "test_ise_up_run"
