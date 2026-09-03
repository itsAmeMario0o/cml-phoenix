#!/usr/bin/env bash
# Post-build checks, read-only. Run after scripts/20-up.sh.
#
#   1. persistent output public_ip_address readable
#   2. CML API answers and reports ready
#   3. cloud-cml output address equals the persistent public IP
#   4. License registered
#   5. /data mounted on the host
#   6. /data/images populated and bind-mounted on /var/lib/libvirt/images
#   7. /data/exports writable by sysadmin
#   8. Data disk attached at LUN 0 (az)
#   9. cml-mcp on the Mac lists labs through scripts/mcp-cml.sh
#
# Exit 1 on any FAIL. Overrides: none needed; CML_SSH_KEY for the key path.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REMOTE_LIB="${REPO_ROOT}/scripts/lib/cml-remote.sh"
CLOUD_CML="${REPO_ROOT}/vendor/cloud-cml"

check_outputs() {
  if ! IP="$(cml_ip 2>/dev/null)" || [[ -z "${IP}" ]]; then
    miss "persistent output public_ip_address unreadable. Has 20-up.sh run?"
    summary_and_exit
  fi
  pass "public IP ${IP}"
}

check_api() {
  local ready
  ready="$(curl -sk -m 10 "https://${IP}/api/v0/system_information" | jq -r .ready 2>/dev/null || true)"
  if [[ "${ready}" == "true" ]]; then
    pass "CML API ready at https://${IP}"
  else
    miss "CML API at https://${IP} not ready (got '${ready:-no answer}')"
  fi
}

check_ip_matches() {
  local addr
  addr="$(terraform -chdir="${CLOUD_CML}" output -json cml2info 2>/dev/null | jq -r .address 2>/dev/null || true)"
  if [[ "${addr}" == "${IP}" ]]; then
    pass "cloud-cml address matches persistent public IP"
  else
    miss "cloud-cml address '${addr}' differs from persistent public IP ${IP}"
  fi
}

check_license() {
  local status
  status="$(cml_ssh "bash -s -- license-status" < "${REMOTE_LIB}" 2>/dev/null || echo UNREACHABLE)"
  case "${status}" in
    REGISTERED | COMPLETED) pass "license ${status}" ;;
    *) miss "license status '${status}'" ;;
  esac
}

check_data_disk_on_host() {
  local mounted bound count
  mounted="$(cml_ssh "findmnt -n -o SOURCE /data" 2>/dev/null || true)"
  if [[ -n "${mounted}" ]]; then
    pass "/data mounted from ${mounted}"
  else
    miss "/data not mounted. See /var/log/provision/05-persist-pre.log on the host"
  fi
  bound="$(cml_ssh "findmnt -n -o TARGET --target /var/lib/libvirt/images" 2>/dev/null || true)"
  if [[ "${bound}" == "/var/lib/libvirt/images" ]]; then
    pass "/var/lib/libvirt/images is a bind mount"
  else
    miss "/var/lib/libvirt/images is not a bind mount (findmnt says '${bound}')"
  fi
  count="$(cml_ssh "find /data/images -type f 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ' || echo 0)"
  if [[ "${count:-0}" -gt 0 ]]; then
    pass "/data/images holds ${count} files"
  else
    miss "/data/images is empty"
  fi
}

check_exports_writable() {
  if cml_ssh "test -w /data/exports" 2>/dev/null; then
    pass "/data/exports is writable"
  else
    miss "/data/exports is not writable. See /var/log/provision/05-persist-post.log on the host"
  fi
}

check_lun0() {
  local rg name
  if ! rg="$(tf_out persistent resource_group_name)"; then
    miss "persistent output resource_group_name unreadable"
    return 0
  fi
  name="$(az vm show -g "${rg}" -n cml-controller --query "storageProfile.dataDisks[?lun==\`0\`].name | [0]" -o tsv 2>/dev/null || true)"
  if [[ "${name}" == "disk-cml-lab-data" ]]; then
    pass "data disk disk-cml-lab-data at LUN 0"
  else
    miss "LUN 0 holds '${name:-nothing}', expected disk-cml-lab-data"
  fi
}

check_mcp() {
  local out
  if out="$(python3 "${REPO_ROOT}/scripts/lib/mcp_call.py" --cmd "bash ${REPO_ROOT}/scripts/mcp-cml.sh" --tool get_cml_labs 2>&1)"; then
    pass "cml-mcp get_cml_labs answered ($(echo "${out}" | wc -c | tr -d ' ') bytes)"
  else
    miss "cml-mcp failed: $(echo "${out}" | tail -1)"
  fi
}

main() {
  require_cmd terraform az curl jq ssh python3 uvx
  check_outputs
  check_api
  check_ip_matches
  check_license
  check_data_disk_on_host
  check_exports_writable
  check_lun0
  check_mcp
  summary_and_exit
}

main "$@"
