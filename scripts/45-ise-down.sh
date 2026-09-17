#!/usr/bin/env bash
# Tear down the disposable ISE VM created by scripts/25-ise-up.sh. Finds
# every resource carrying the role=ise tag in the lab resource group and
# deletes it: VM, NIC, NSG, OS disk, and public IP (the solution template
# tags the first three, 25-ise-up.sh tags the disk and NSG, ADR 0008).
# Never touches bootstrap, persistent, or the CML VM, none of which carry
# this tag.
#
#   scripts/45-ise-down.sh [--dry-run]
#
# Prompts unless ASSUME_YES=1. --dry-run prints the planned deletes and
# deletes nothing.
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

# delete_all ROWS: the VM first. Deleting it only releases the compute
# allocation; NIC, NSG, disk, and public IP each need their own delete
# afterward, in any order once the VM is gone.
delete_all() {
  local rows="$1" id type name
  while IFS=$'\t' read -r id type name || [[ -n "${id}" ]]; do
    [[ -z "${id}" ]] && continue
    [[ "${type}" == "Microsoft.Compute/virtualMachines" ]] && delete_by_type "${id}" "${type}" "${name}"
  done <<< "${rows}"
  while IFS=$'\t' read -r id type name || [[ -n "${id}" ]]; do
    [[ -z "${id}" ]] && continue
    [[ "${type}" == "Microsoft.Compute/virtualMachines" ]] || delete_by_type "${id}" "${type}" "${name}"
  done <<< "${rows}"
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
  pass "ISE resources deleted. Persistent resources and the CML VM untouched."
  summary_and_exit
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
