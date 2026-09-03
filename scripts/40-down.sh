#!/usr/bin/env bash
# Tear down the CML VM only. Persistent and bootstrap are never touched.
#
#   scripts/40-down.sh [--dry-run] [--force-license]
#
# 1. scripts/30-export-labs.sh (refuses if the API is down)
# 2. Stop every lab
# 3. /provision/del.sh on the host, then verify NOT_REGISTERED; retry with
#    cml-remote.sh deregister. A stranded Smart License blocks the next
#    build, so a failure here stops the teardown unless --force-license.
# 4. terraform destroy in vendor/cloud-cml
#
# --dry-run prints the sequence. Prompts unless ASSUME_YES=1.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REMOTE_LIB="${REPO_ROOT}/scripts/lib/cml-remote.sh"
CLOUD_CML="${REPO_ROOT}/vendor/cloud-cml"
CML_YML="${REPO_ROOT}/config/cml.yml"
DRY_RUN=0
FORCE_LICENSE=0

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

remote() {
  local ip="$1"; shift
  local key="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ssh -p 1122 sysadmin@${ip} bash -s -- $* < ${REMOTE_LIB}"
  else
    ssh -p 1122 -i "${key}" -o StrictHostKeyChecking=accept-new "sysadmin@${ip}" "bash -s -- $*" < "${REMOTE_LIB}"
  fi
}

export_labs() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ${REPO_ROOT}/scripts/30-export-labs.sh --dry-run"
  else
    "${REPO_ROOT}/scripts/30-export-labs.sh" || die "export failed, not destroying. Fix the export or run 30-export-labs.sh by hand."
  fi
}

release_license() {
  local ip="$1" status
  run cml_ssh /provision/del.sh || true
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  status="$(remote "${ip}" license-status || echo UNKNOWN)"
  if [[ "${status}" == "REGISTERED" ]]; then
    warn "del.sh left the license REGISTERED, retrying through the API"
    status="$(remote "${ip}" deregister || echo REGISTERED)"
  fi
  if [[ "${status}" == "REGISTERED" ]]; then
    if [[ "${FORCE_LICENSE}" == "1" ]]; then
      warn "license still REGISTERED, continuing because of --force-license. Release it in Smart Software Manager."
    else
      die "license still REGISTERED. Fix it, or rerun with --force-license and release it in Smart Software Manager."
    fi
  else
    pass "license ${status}"
  fi
}

destroy_cml() {
  local tenant
  tenant="$(az account show --query tenantId -o tsv)"
  export TF_VAR_cfg_file="${CML_YML}"
  export TF_VAR_azure_subscription_id="${ARM_SUBSCRIPTION_ID}"
  export TF_VAR_azure_tenant_id="${tenant}"
  confirm "Destroy the CML VM (vendor/cloud-cml root only)?" || die "declined"
  run terraform -chdir="${CLOUD_CML}" destroy -input=false -auto-approve
}

main() {
  local ip arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      --force-license) FORCE_LICENSE=1 ;;
      *) die "usage: 40-down.sh [--dry-run] [--force-license]" ;;
    esac
  done
  require_env ARM_SUBSCRIPTION_ID
  require_cmd terraform az ssh
  ip="$(cml_ip)"
  export_labs
  remote "${ip}" stop-labs
  release_license "${ip}"
  destroy_cml
  pass "CML VM destroyed. Persistent resources untouched. Next build: scripts/20-up.sh"
  summary_and_exit
}

main "$@"
