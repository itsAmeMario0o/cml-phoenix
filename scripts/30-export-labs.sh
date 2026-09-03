#!/usr/bin/env bash
# Export every lab to YAML and copy the folder to blob storage.
#
#   scripts/30-export-labs.sh [--dry-run]
#
# 1. Refuse if the CML API does not answer (nothing to export safely)
# 2. On the host: cml-remote.sh export-labs /data/exports/<UTC timestamp>
# 3. scp that folder to exports/<timestamp>/ in the repo (gitignored)
# 4. azcopy the local copy to the exports container, same folder name
#
# The blob copy is the durable one. The host copy dies with the VM, the
# local copy is a convenience for diffing. Reimport is by hand or via
# cml-mcp create_full_lab_topology, on purpose (spec section 3).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REMOTE_LIB="${REPO_ROOT}/scripts/lib/cml-remote.sh"
LOCAL_EXPORTS="${REPO_ROOT}/exports"
DRY_RUN=0

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

api_ready() {
  local ip="$1"
  [[ "$(curl -sk -m 10 "https://${ip}/api/v0/system_information" | jq -r .ready 2>/dev/null)" == "true" ]]
}

export_on_host() {
  local ip="$1" stamp="$2" key="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ssh -p 1122 sysadmin@${ip} bash -s -- export-labs /data/exports/${stamp} < ${REMOTE_LIB}"
  else
    ssh -p 1122 -i "${key}" -o StrictHostKeyChecking=accept-new "sysadmin@${ip}" \
      "bash -s -- export-labs /data/exports/${stamp}" < "${REMOTE_LIB}"
  fi
}

pull_local_copy() {
  local ip="$1" stamp="$2" key="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
  mkdir -p "${LOCAL_EXPORTS}"
  run scp -P 1122 -i "${key}" -o StrictHostKeyChecking=accept-new -q -r \
    "sysadmin@${ip}:/data/exports/${stamp}" "${LOCAL_EXPORTS}/${stamp}"
}

push_to_blob() {
  local stamp="$1" sa
  sa="$(tf_out persistent storage_account_name)"
  export AZCOPY_AUTO_LOGIN_TYPE=AZCLI
  export AZCOPY_LOG_LOCATION="${REPO_ROOT}/.azcopy" AZCOPY_JOB_PLAN_LOCATION="${REPO_ROOT}/.azcopy"
  mkdir -p "${AZCOPY_LOG_LOCATION}"
  run azcopy copy "${LOCAL_EXPORTS}/${stamp}" "https://${sa}.blob.core.windows.net/exports/" --recursive
}

main() {
  local ip stamp
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
  require_cmd terraform ssh scp azcopy curl jq
  ip="$(cml_ip)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ "${DRY_RUN}" != "1" ]] && ! api_ready "${ip}"; then
    die "CML API at https://${ip} is not ready. Nothing exported."
  fi
  export_on_host "${ip}" "${stamp}"
  pull_local_copy "${ip}" "${stamp}"
  push_to_blob "${stamp}"
  pass "exports in ${LOCAL_EXPORTS}/${stamp} and blob container exports/${stamp}"
  summary_and_exit
}

main "$@"
