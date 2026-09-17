#!/usr/bin/env bash
# Dry-run tests for the fork's 06-transit.sh (ADR 0003). The script
# runs on Ubuntu as root; here DRY_RUN=1 prints the commands it would run
# and the PRETEND_* variables stand in for the libvirt, bridge, route, and
# nftables probes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/vendor/cloud-cml/modules/deploy/data/06-transit.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

common_env="DRY_RUN=1 LOG_DIR=${TMP} OLD_NETPLAN_FILE=${TMP}/60-transit-bridge.yaml"
good_addr="PRETEND_ADDR=10.100.0.1/24"
good_route="PRETEND_ROUTE=10.100.0.0/16 via 10.100.0.2 dev bridge1 proto static"
libvirt_masq="ip saddr 192.168.255.0/24 ip daddr != 192.168.255.0/24 masquerade"

# 1. First build: nothing defined, no stray bridge. Define, autostart, start.
# shellcheck disable=SC2086
out="$(env ${common_env} ${good_addr} "${good_route}" PRETEND_MASQ="${libvirt_masq}" bash "${SCRIPT}" 2>&1)"
assert_contains "defines the network" "+ virsh net-define <xml>:" "${out}"
assert_contains "network is routed, not NAT" "<forward mode='route'/>" "${out}"
assert_contains "bridge is named for the connector scan" "<bridge name='bridge1' stp='off' delay='0'/>" "${out}"
assert_contains "host address is ADR 0003's" "<ip address='10.100.0.1' netmask='255.255.255.0'/>" "${out}"
assert_contains "lab summary routes to the edge" "<route address='10.100.0.0' prefix='16' gateway='10.100.0.2'/>" "${out}"
assert_not_contains "no DHCP on the transit network" "<dhcp>" "${out}"
assert_contains "autostarts the network" "+ virsh net-autostart transit" "${out}"
assert_contains "starts the network" "+ virsh net-start transit" "${out}"
assert_not_contains "no stray bridge to remove" "+ ip link delete" "${out}"
assert_contains "libvirt NAT rule is fine" "masquerade rules leave 10.100.0.0/16 alone" "${out}"
assert_not_contains "no warning for libvirt NAT rule" "WARN" "${out}"
assert_contains "verifies the address" "bridge1 holds 10.100.0.1/24" "${out}"
assert_contains "verifies the route" "10.100.0.0/16 routes via 10.100.0.2" "${out}"
assert_contains "logs done" "[06-transit] done" "${out}"

# 2. Rerun on a host where the network exists and is active: no redefine,
#    no restart, autostart reasserted.
# shellcheck disable=SC2086
out="$(env ${common_env} ${good_addr} "${good_route}" PRETEND_NET_DEFINED=1 PRETEND_NET_ACTIVE=1 PRETEND_STRAY_BRIDGE=1 bash "${SCRIPT}" 2>&1)"
assert_contains "existing network kept" "network transit already defined" "${out}"
assert_not_contains "existing network not redefined" "+ virsh net-define" "${out}"
assert_contains "existing network not restarted" "network transit already active" "${out}"
assert_not_contains "no net-start on an active network" "+ virsh net-start" "${out}"
assert_contains "autostart reasserted" "+ virsh net-autostart transit" "${out}"
assert_not_contains "libvirt's own bridge is not deleted" "+ ip link delete" "${out}"

# 3. Defined but stopped: start it, do not redefine.
# shellcheck disable=SC2086
out="$(env ${common_env} ${good_addr} "${good_route}" PRETEND_NET_DEFINED=1 PRETEND_NET_ACTIVE=0 bash "${SCRIPT}" 2>&1)"
assert_contains "stopped network is started" "+ virsh net-start transit" "${out}"
assert_not_contains "stopped network not redefined" "+ virsh net-define" "${out}"

# 4. A bridge1 left by the netplan version is removed before libvirt takes
#    the name, along with its netplan file.
# shellcheck disable=SC2086
out="$(env ${common_env} ${good_addr} "${good_route}" PRETEND_STRAY_BRIDGE=1 bash "${SCRIPT}" 2>&1)"
assert_contains "stray bridge removed" "+ ip link delete bridge1" "${out}"
assert_contains "old netplan file removed" "+ rm -f ${TMP}/60-transit-bridge.yaml" "${out}"
assert_contains "netplan reapplied" "+ netplan apply" "${out}"
assert_contains "then the network is defined" "+ virsh net-define <xml>:" "${out}"

# 5. Masquerade rules that could NAT the transit range warn.
# shellcheck disable=SC2086
out="$(env ${common_env} ${good_addr} "${good_route}" PRETEND_MASQ="ip saddr 10.100.0.0/16 masquerade" bash "${SCRIPT}" 2>&1)"
assert_contains "warns on a transit-range masquerade" "WARN: a masquerade rule may cover 10.100.0.0/16" "${out}"
# shellcheck disable=SC2086
out="$(env ${common_env} ${good_addr} "${good_route}" PRETEND_MASQ="oifname eth0 masquerade" bash "${SCRIPT}" 2>&1)"
assert_contains "warns on an unscoped masquerade" "WARN: a masquerade rule may cover" "${out}"
# shellcheck disable=SC2086
out="$(env ${common_env} ${good_addr} "${good_route}" PRETEND_MASQ= bash "${SCRIPT}" 2>&1)"
assert_contains "no NAT rules logged" "no masquerade rules on the host" "${out}"

# 6. The bridge not coming up, or the route missing, fails loudly.
set +e
# shellcheck disable=SC2086
out="$(env ${common_env} PRETEND_ADDR= "${good_route}" bash "${SCRIPT}" 2>&1)"
rc=$?
set -e
assert_eq "missing bridge exits nonzero" "1" "${rc}"
assert_contains "missing bridge names the problem" "FAIL: bridge1 address 'none', expected 10.100.0.1/24" "${out}"
set +e
# shellcheck disable=SC2086
out="$(env ${common_env} ${good_addr} PRETEND_ROUTE= bash "${SCRIPT}" 2>&1)"
rc=$?
set -e
assert_eq "missing route exits nonzero" "1" "${rc}"
assert_contains "missing route names the problem" "FAIL: no route to 10.100.0.0/16 via 10.100.0.2" "${out}"

# 7. Log file lands in LOG_DIR.
[[ -f "${TMP}/06-transit.log" ]] && log_present=1 || log_present=0
assert_eq "log file written" "1" "${log_present}"

# 8. cml.sh postprocess only runs names matching this pattern; a name it
#    skips means the bridge is never built (seen 2026-09-17).
if grep -qE '[0-9]{2}-[[:alnum:]_]+\.sh' <<<"/provision/$(basename "${SCRIPT}")"; then name_ok=1; else name_ok=0; fi
assert_eq "script name matches the postprocess filter" "1" "${name_ok}"

echo "test_transit: all passed"
