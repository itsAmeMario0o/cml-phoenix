#!/usr/bin/env bash
# Tear down the CML VM only. Persistent and bootstrap are never touched.
#
#   scripts/40-down.sh [--dry-run] [--force-license] [--skip-export]
#
# 1. scripts/30-export-labs.sh (refuses if the API is down)
# 2. Stop every lab
# 3. /provision/del.sh on the host, then verify NOT_REGISTERED; retry with
#    cml-remote.sh deregister. A stranded Smart License blocks the next
#    build, so a failure here stops the teardown unless --force-license.
# 4. Render config/cml.yml again, then terraform destroy in vendor/cloud-cml
#
# --skip-export drops steps 1 and 2 for a VM whose API never came up, and
# makes you type the VM name first: the labs on it are lost with it. The
# license gate still runs; a wedged VM usually needs --force-license too.
# --dry-run prints the sequence. Prompts unless ASSUME_YES=1.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CLOUD_CML="${REPO_ROOT}/vendor/cloud-cml"
CML_VM_NAME="cml-controller"
DRY_RUN=0
FORCE_LICENSE=0
SKIP_EXPORT=0

# license_blocked STATUS: 0 when the teardown must stop. Anything other than
# a confirmed NOT_REGISTERED blocks, including UNKNOWN, because an
# unverified license is a stranded license until proven otherwise.
license_blocked() {
  [[ "$1" != "NOT_REGISTERED" ]]
}

export_labs() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ${REPO_ROOT}/scripts/30-export-labs.sh --dry-run"
  else
    "${REPO_ROOT}/scripts/30-export-labs.sh" || die "export failed, not destroying. Fix the export or run 30-export-labs.sh by hand."
  fi
}

# confirm_skip_export: destroying without a copy of the labs is answered
# by typing the VM name, not y, so a reflex cannot pass it. ASSUME_YES
# stands in only because --skip-export itself was typed on the same
# command line; it never skips the export on its own.
confirm_skip_export() {
  local answer
  warn "skipping the export and the lab stop: every lab on ${CML_VM_NAME} is lost with it"
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  printf "Type the VM name (%s) to destroy it without an export: " "${CML_VM_NAME}"
  read -r answer
  [[ "${answer}" == "${CML_VM_NAME}" ]] || die "declined"
}

release_license() {
  local status
  run cml_ssh /provision/del.sh || true
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ license gate (status from host)"
    return 0
  fi
  status="$( (cml_remote license-status || echo UNKNOWN) | tail -n 1)"
  if license_blocked "${status}"; then
    warn "del.sh left the license ${status}, retrying through the API"
    status="$( (cml_remote deregister || true) | tail -n 1)"
    [[ -n "${status}" ]] || status="UNKNOWN"
  fi
  if license_blocked "${status}"; then
    if [[ "${FORCE_LICENSE}" == "1" ]]; then
      warn "license still ${status}, continuing because of --force-license. Release it in Smart Software Manager."
    else
      die "license still ${status}. Fix it, or rerun with --force-license and release it in Smart Software Manager."
    fi
  else
    pass "license ${status}"
  fi
}

# destroy_cml: render config/cml.yml first. Terraform re-reads it for the
# destroy, and the copy from the build went stale when the fork renamed
# a customize script (LESSONS-LEARNED, 2026-09-17).
destroy_cml() {
  local tenant
  if [[ "${DRY_RUN}" == "1" ]]; then
    tenant="<tenant>"
  else
    tenant="$(az account show --query tenantId -o tsv)"
  fi
  render_config
  export TF_VAR_cfg_file="${CML_YML}"
  export TF_VAR_azure_subscription_id="${ARM_SUBSCRIPTION_ID}"
  export TF_VAR_azure_tenant_id="${tenant}"
  if [[ "${DRY_RUN}" != "1" ]]; then
    confirm "Destroy the CML VM (vendor/cloud-cml root only)?" || die "declined"
  fi
  run terraform -chdir="${CLOUD_CML}" destroy -input=false -auto-approve
}

main() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      --force-license) FORCE_LICENSE=1 ;;
      --skip-export) SKIP_EXPORT=1 ;;
      *) die "usage: 40-down.sh [--dry-run] [--force-license] [--skip-export]" ;;
    esac
  done
  require_env ARM_SUBSCRIPTION_ID
  require_cmd terraform az ssh python3 jq
  if [[ "${SKIP_EXPORT}" == "1" ]]; then
    confirm_skip_export
  else
    export_labs
    run cml_remote stop-labs
  fi
  release_license
  destroy_cml
  if [[ "${DRY_RUN}" == "1" ]]; then
    pass "dry run: would destroy the CML VM (vendor/cloud-cml root only). Persistent resources untouched."
  else
    pass "CML VM destroyed. Persistent resources untouched. Next build: scripts/20-up.sh"
  fi
  summary_and_exit
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
