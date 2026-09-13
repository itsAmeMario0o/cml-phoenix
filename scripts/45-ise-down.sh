#!/usr/bin/env bash
# Tear down the disposable ISE VM created by scripts/25-ise-up.sh. Finds
# every resource carrying the role=ise tag in the lab resource group and
# deletes it: VM, NIC, NSG, OS disk, and a public IP if one somehow
# exists (25-ise-up.sh never creates one, ADR 0003). Never touches
# bootstrap, persistent, or the CML VM, none of which carry this tag.
#
#   scripts/45-ise-down.sh [--dry-run]
#
# Prompts unless ASSUME_YES=1. --dry-run prints the planned deletes and
# deletes nothing.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

USERDATA_FILE="${REPO_ROOT}/config/mcp-env/ise-userdata"
DRY_RUN=0

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

out_or_placeholder() {
  local value
  if value="$(tf_out persistent "$1" 2>/dev/null)" && [[ -n "${value}" ]]; then
    echo "${value}"
  elif [[ "${DRY_RUN}" == "1" ]]; then
    echo "<$1>"
  else
    die "persistent output $1 unavailable"
  fi
}

# find_ise_resources: id, type, name (tab separated) per line for
# everything tagged role=ise in the lab resource group. Read-only, so it
# always runs for real, dry run included, and shows exactly what would
# be deleted.
find_ise_resources() {
  local rg
  rg="$(out_or_placeholder resource_group_name)"
  az resource list -g "${rg}" --tag role=ise --query "[].{id:id,type:type,name:name}" -o tsv
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

# remove_userdata_file: the rendered custom-data holds the ISE admin
# password (ADR 0004); once ISE is gone the file is stale, not useful,
# and should not linger on disk.
remove_userdata_file() {
  if [[ -f "${USERDATA_FILE}" ]]; then
    run rm -f "${USERDATA_FILE}"
  fi
}

main() {
  local rows
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
  require_env ARM_SUBSCRIPTION_ID
  require_cmd az terraform jq
  rows="$(find_ise_resources)" || die "cannot list ISE resources by tag"
  if [[ -z "${rows}" ]]; then
    pass "no ISE resources tagged role=ise found"
    remove_userdata_file
    summary_and_exit
  fi
  echo "ISE resources tagged role=ise:"
  echo "${rows}"
  confirm "Delete every ISE resource listed above?" || die "declined"
  delete_all "${rows}"
  remove_userdata_file
  pass "ISE resources deleted. Persistent resources and the CML VM untouched."
  summary_and_exit
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
