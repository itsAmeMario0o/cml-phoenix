#!/usr/bin/env bash
# scripts/45-ise-down.sh with dry run OFF, against the stubbed az and
# terraform (tests/stubs). Every az call lands in STUB_LOG, so these
# assertions are about what the script did with a real answer: delete
# order, what happens when a delete fails, and what the re-list decides.
# tests/test_ise_dry_run.sh still covers the printed plan.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/45-ise-down.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

LOG="${TMP}/calls.log"
# run_down [ENV=VALUE...]: the script for real, calls logged. Sets rc,
# out and log for the assertions that follow.
run_down() {
  rm -f "${LOG}"; rc=0
  out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" STUB_LOG="${LOG}" \
    ARM_SUBSCRIPTION_ID=x ASSUME_YES=1 env "$@" bash "${SCRIPT}" 2>&1)" || rc=$?
  log="$(cat "${LOG}" 2>/dev/null || true)"
}

# 1. Clean run. The stub lists the NSG and the public IP before the NIC;
#    the deletes must still go VM, NIC, then the rest, and the empty
#    re-list is what earns the [OK].
run_down
assert_eq "clean run exits 0" "0" "${rc}"
assert_contains "clean run is an OK" "[OK]    ISE resources deleted." "${out}"
assert_before "vm deleted before nic" "az vm delete" "az network nic delete" "${log}"
assert_before "nic deleted before nsg" "az network nic delete" "az network nsg delete" "${log}"
assert_before "nic deleted before public ip" "az network nic delete" "az network public-ip delete" "${log}"
assert_before "nic deleted before disk" "az network nic delete" "az disk delete" "${log}"
assert_contains "disk deleted by id, whatever case Azure gave its group" "az disk delete --ids /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/RG-CML-LAB/providers/Microsoft.Compute/disks/ise1osdisk --yes" "${log}"
assert_eq "five deletes, one per resource" "5" "$(grep -c ' delete ' <<<"${log}")"
assert_eq "listed twice: once to plan, once to confirm" "2" "$(grep -c 'az resource list' <<<"${log}")"
assert_contains "the last call is the re-list" "az resource list" "$(tail -1 <<<"${log}")"
assert_eq "no terraform apply or destroy" "0" "$(grep -cE 'terraform .*(apply|destroy)' <<<"${log}" || true)"

# 2. The NSG delete fails. Documents current behaviour: the script exits
#    1 through bare errexit with az's error and no [OK], but also with no
#    [FAIL] line of its own, and the disk and public IP deletes and the
#    re-list never happen (delete_all has no || die around delete_by_type).
run_down AZ_STUB_FAIL="network nsg delete"
assert_eq "failed nsg delete exits 1" "1" "${rc}"
assert_not_contains "failed nsg delete never claims success" "[OK]" "${out}"
assert_contains "az's own error reaches the operator" "az stub: 'network nsg delete' failed" "${out}"
assert_contains "a failed delete is named" "[FAIL]  delete of ise-nsg failed" "${out}"
assert_contains "the remaining deletes still run" "az disk delete" "${log}"
assert_eq "the tag re-list still runs after a failure" "2" "$(grep -c 'az resource list' <<<"${log}")"

# 3. Every delete is accepted, but the re-list still shows the disk.
run_down AZ_STUB_ISE_LEFTOVER=1
assert_eq "leftover after the deletes exits 1" "1" "${rc}"
assert_contains "leftover is a FAIL" "[FAIL]  ISE resources still tagged role=ise after the deletes" "${out}"
assert_contains "leftover row is shown" "disks/ise1osdisk" "${out}"
assert_not_contains "leftover never claims success" "ISE resources deleted." "${out}"
assert_eq "all five deletes were still issued" "5" "$(grep -c ' delete ' <<<"${log}")"

# 4. The first listing cannot be read at all: nothing is deleted.
run_down AZ_STUB_FAIL="resource list"
assert_eq "unlistable exits 1" "1" "${rc}"
assert_contains "unlistable is a FAIL" "[FAIL]  cannot list ISE resources by tag" "${out}"
assert_not_contains "unlistable deletes nothing" " delete " "${log}"

# 5. The persistent root has no outputs. Documents current behaviour, and
#    it is a bug: find_ise_resources runs inside "$(...) || die", where
#    bash keeps errexit off, so out_or_placeholder's die only prints. The
#    listing then runs with an empty --resource-group, everything it
#    returns is deleted, and the run ends [OK] exit 0 under two [FAIL]
#    lines. Fix: `rg="$(out_or_placeholder resource_group_name)" || return 1`
#    in find_ise_resources, then flip these three assertions.
run_down TF_STUB_FAIL=1
assert_contains "no persistent outputs names the output" "[FAIL]  persistent output resource_group_name unavailable" "${out}"
assert_eq "no persistent outputs exits 1" "1" "${rc}"
assert_not_contains "never lists with an empty resource group" "az resource list --resource-group  --query" "${log}"
assert_not_contains "deletes nothing without a resource group" "az vm delete" "${log}"

finish "test_ise_down_run"
