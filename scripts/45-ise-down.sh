#!/usr/bin/env bash
# Tear down the disposable ISE VM created by scripts/25-ise-up.sh. Finds
# every resource carrying the role=ise tag in the lab resource group and
# deletes it: VM, NIC, NSG, OS disk, and public IP. The Marketplace wizard
# tags nothing; 25-ise-up.sh tags all five (ADR 0008). Never touches
# bootstrap, persistent, or the CML VM, none of which carry this tag.
#
#   scripts/45-ise-down.sh [--dry-run]
#
# Prompts unless ASSUME_YES=1. --dry-run prints the planned deletes and
# deletes nothing. A real run lists by tag again afterwards and fails if
# anything is still there.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

DRY_RUN=0

# find_ise_resources: id, type, name (tab separated) per line for
# everything tagged role=ise in the lab resource group. Read-only, so it
# always runs for real, dry run included, and shows exactly what would
# be deleted.
# az 2.89 refuses --tag together with --resource-group, so the resource
# group is the server side filter and the tag is the query. Not the other
# way round: Azure reports a disk's resource group in upper case
# (RG-CML-LAB), and a query comparing it to the real name skips the disk
# without a word while it goes on billing (LESSONS-LEARNED, 2026-09-17).
find_ise_resources() {
  local rg
  rg="$(out_or_placeholder resource_group_name)"
  az resource list --resource-group "${rg}" --query "[?tags.role=='ise'].{id:id,type:type,name:name}" -o tsv
}

# delete_by_type ID TYPE NAME: dispatch to the right az subcommand. An
# unrecognized type only warns, since deleting something we cannot name
# correctly is worse than leaving it for the operator to check by hand.
delete_by_type() {
  local id="$1" type="$2" name="$3"
  case "${type}" in
    Microsoft.Compute/virtualMachines) run az vm delete --ids "${id}" --yes ;;
    Microsoft.Network/networkInterfaces) run az network nic delete --ids "${id}" ;;
    Microsoft.Network/networkSecurityGroups) run az network nsg delete --ids "${id}" ;;
    Microsoft.Compute/disks) run az disk delete --ids "${id}" --yes ;;
    Microsoft.Network/publicIPAddresses) run az network public-ip delete --ids "${id}" ;;
    *) warn "unrecognized ISE resource type ${type} (${name}), skipping" ;;
  esac
}

# delete_rank TYPE: the pass a type is deleted in. The VM first, since
# deleting it only releases the compute allocation. Then the NIC: Azure
# refuses to delete an NSG or a public IP while a NIC still references
# it, and 25-ise-up.sh attaches ise-nsg to the NIC. Everything else last.
delete_rank() {
  case "$1" in
    Microsoft.Compute/virtualMachines) echo 1 ;;
    Microsoft.Network/networkInterfaces) echo 2 ;;
    *) echo 3 ;;
  esac
}

# delete_all ROWS: three passes by delete_rank. The order comes from here
# and never from the listing, because `az resource list` does not promise
# one (architecture review, 2026-09-17).
delete_all() {
  local rows="$1" rank id type name
  for rank in 1 2 3; do
    while IFS=$'\t' read -r id type name || [[ -n "${id}" ]]; do
      [[ -z "${id}" ]] && continue
      [[ "$(delete_rank "${type}")" == "${rank}" ]] || continue
      delete_by_type "${id}" "${type}" "${name}"
    done <<< "${rows}"
  done
}

# confirm_gone: list by tag again. A delete that az accepted can still
# leave the resource behind; only an empty listing is success.
confirm_gone() {
  local left
  if [[ "${DRY_RUN}" == "1" ]]; then
    pass "dry run: would delete every ISE resource listed above, then list by tag again to confirm nothing remains"
    return 0
  fi
  left="$(find_ise_resources)" || die "cannot re-list ISE resources by tag"
  if [[ -n "${left}" ]]; then
    echo "${left}"
    miss "ISE resources still tagged role=ise after the deletes. Delete them by hand and rerun."
  else
    pass "ISE resources deleted. Persistent resources and the CML VM untouched."
  fi
}

main() {
  local rows
  DRY_RUN="$(parse_dry_run_only "$@")"
  require_env ARM_SUBSCRIPTION_ID
  require_cmd az terraform jq
  rows="$(find_ise_resources)" || die "cannot list ISE resources by tag"
  if [[ -z "${rows}" ]]; then
    pass "no ISE resources tagged role=ise found"
    summary_and_exit
  fi
  echo "ISE resources tagged role=ise:"
  echo "${rows}"
  confirm "Delete every ISE resource listed above?" || die "declined"
  delete_all "${rows}"
  confirm_gone
  summary_and_exit
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
