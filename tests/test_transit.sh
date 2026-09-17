#!/usr/bin/env bash
# Dry-run tests for the fork's 06-transit-bridge.sh (ADR 0003). The script
# runs on Ubuntu as root; here DRY_RUN=1 prints the commands it would run
# and the PRETEND_* variables stand in for the bridge and nftables probes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/vendor/cloud-cml/modules/deploy/data/06-transit-bridge.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

common_env="DRY_RUN=1 LOG_DIR=${TMP} NETPLAN_FILE=${TMP}/60-transit-bridge.yaml SYSCTL_FILE=${TMP}/60-transit-bridge.conf"
libvirt_masq="ip saddr 192.168.255.0/24 ip daddr != 192.168.255.0/24 masquerade"

# 1. The normal case: bridge comes up, only libvirt's NAT rule exists.
# shellcheck disable=SC2086
out="$(env ${common_env} PRETEND_ADDR=10.100.0.1/24 PRETEND_MASQ="${libvirt_masq}" bash "${SCRIPT}" 2>&1)"
assert_contains "writes the netplan file" "+ write ${TMP}/60-transit-bridge.yaml mode 0600:" "${out}"
assert_contains "bridge has the ADR 0003 address" "addresses: [10.100.0.1/24]" "${out}"
assert_contains "bridge has no member interfaces" "interfaces: []" "${out}"
assert_contains "routes the lab summary to the edge" "- to: 10.100.0.0/16" "${out}"
assert_contains "via the C8000v edge" "via: 10.100.0.2" "${out}"
assert_contains "applies netplan" "+ netplan apply" "${out}"
assert_contains "persists ip_forward" "net.ipv4.ip_forward = 1" "${out}"
assert_contains "applies the sysctl file" "+ sysctl -q -p ${TMP}/60-transit-bridge.conf" "${out}"
assert_contains "libvirt NAT rule is fine" "masquerade rules leave 10.100.0.0/16 alone" "${out}"
assert_not_contains "no warning for libvirt NAT rule" "WARN" "${out}"
assert_contains "verifies the address" "br-transit holds 10.100.0.1/24" "${out}"
assert_contains "logs done" "[06-transit-bridge] done" "${out}"

# 2. A masquerade rule naming the transit range warns.
# shellcheck disable=SC2086
out="$(env ${common_env} PRETEND_ADDR=10.100.0.1/24 PRETEND_MASQ="ip saddr 10.100.0.0/16 masquerade" bash "${SCRIPT}" 2>&1)"
assert_contains "warns on a transit-range masquerade" "WARN: a masquerade rule may cover 10.100.0.0/16" "${out}"

# 3. A masquerade rule with no source restriction warns too.
# shellcheck disable=SC2086
out="$(env ${common_env} PRETEND_ADDR=10.100.0.1/24 PRETEND_MASQ="oifname eth0 masquerade" bash "${SCRIPT}" 2>&1)"
assert_contains "warns on an unscoped masquerade" "WARN: a masquerade rule may cover" "${out}"

# 4. No masquerade rules at all is fine.
# shellcheck disable=SC2086
out="$(env ${common_env} PRETEND_ADDR=10.100.0.1/24 PRETEND_MASQ= bash "${SCRIPT}" 2>&1)"
assert_contains "no NAT rules logged" "no masquerade rules on the host" "${out}"

# 5. The bridge not coming up is a failure, visible in the log.
set +e
# shellcheck disable=SC2086
out="$(env ${common_env} PRETEND_ADDR= PRETEND_MASQ= bash "${SCRIPT}" 2>&1)"
rc=$?
set -e
assert_eq "missing bridge exits nonzero" "1" "${rc}"
assert_contains "missing bridge names the problem" "FAIL: br-transit address 'none', expected 10.100.0.1/24" "${out}"

# 6. Log file lands in LOG_DIR.
[[ -f "${TMP}/06-transit-bridge.log" ]] && log_present=1 || log_present=0
assert_eq "log file written" "1" "${log_present}"

echo "test_transit: all passed"
