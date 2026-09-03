#!/usr/bin/env bash
# Upload the CML package and the selected refplat images to the cml container.
#
#   scripts/10-upload-images.sh [--dry-run]
#
# Mounts the refplat ISO from software/ read-only, copies only the node
# definitions and images listed in config/refplat.txt plus the package named
# in config/cml.tfvars, then unmounts. Existing blobs are skipped, so re-runs
# are cheap. Uses the az login session through AZCOPY_AUTO_LOGIN_TYPE=AZCLI;
# the persistent root grants Storage Blob Data Contributor for this.
#
# azcopy keeps logs and job plans under ~/.azcopy by default. Repo rule says
# nothing outside the repo, so they go to .azcopy/ here (gitignored).
#
# Overrides: CML_SOFTWARE_DIR (software/), REFPLAT_ISO (auto-detect
# refplat-*.iso), REFPLAT_DIR (skip mounting, use this folder), REFPLAT_FILE,
# CML_TFVARS, STORAGE_ACCOUNT (persistent output), CONTAINER (cml).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CML_SOFTWARE_DIR="${CML_SOFTWARE_DIR:-${REPO_ROOT}/software}"
REFPLAT_FILE="${REFPLAT_FILE:-${REPO_ROOT}/config/refplat.txt}"
CML_TFVARS="${CML_TFVARS:-${REPO_ROOT}/config/cml.tfvars}"
CONTAINER="${CONTAINER:-cml}"
MOUNT_POINT="${REPO_ROOT}/.refplat-mount"
DRY_RUN=0
MOUNTED=0

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

find_iso() {
  local candidates
  if [[ -n "${REFPLAT_ISO:-}" ]]; then
    echo "${REFPLAT_ISO}"
    return 0
  fi
  candidates="$(ls "${CML_SOFTWARE_DIR}"/refplat-*.iso 2>/dev/null || true)"
  if [[ "$(echo "${candidates}" | grep -c .)" -ne 1 ]]; then
    die "expected exactly one refplat-*.iso in ${CML_SOFTWARE_DIR}, found: ${candidates:-none}. Set REFPLAT_ISO."
  fi
  echo "${candidates}"
}

mount_iso() {
  local iso="$1"
  if [[ -n "${REFPLAT_DIR:-}" ]]; then
    echo "using REFPLAT_DIR=${REFPLAT_DIR}, not mounting"
    return 0
  fi
  require_cmd hdiutil
  mkdir -p "${MOUNT_POINT}"
  hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_POINT}" "${iso}" >/dev/null
  MOUNTED=1
  REFPLAT_DIR="${MOUNT_POINT}"
}

unmount_iso() {
  if [[ "${MOUNTED}" == "1" ]]; then
    hdiutil detach "${MOUNT_POINT}" -quiet || true
    rmdir "${MOUNT_POINT}" 2>/dev/null || true
  fi
}

storage_base() {
  local sa="${STORAGE_ACCOUNT:-}"
  if [[ -z "${sa}" ]]; then
    sa="$(tf_out persistent storage_account_name)" || die "persistent root not applied; set STORAGE_ACCOUNT or run 20-up.sh through the persistent step"
  fi
  echo "https://${sa}.blob.core.windows.net/${CONTAINER}"
}

verify_selection() {
  local def img
  while read -r def img || [[ -n "${def}" ]]; do
    [[ -z "${def}" || "${def}" == \#* ]] && continue
    if [[ -f "${REFPLAT_DIR}/node-definitions/${def}.yaml" ]]; then
      pass "definition ${def}"
    else
      miss "definition ${def} not on the ISO"
    fi
    if [[ -d "${REFPLAT_DIR}/virl-base-images/${img}" ]]; then
      pass "image ${img}"
    else
      miss "image ${img} not on the ISO"
    fi
  done < "${REFPLAT_FILE}"
}

upload_all() {
  local base="$1" pkg def img
  pkg="$(python3 "${REPO_ROOT}/scripts/lib/tfvars.py" "${CML_TFVARS}" software_package)"
  if [[ ! -f "${CML_SOFTWARE_DIR}/${pkg}" ]]; then
    miss "package ${CML_SOFTWARE_DIR}/${pkg} missing"
    return 0
  fi
  run azcopy copy "${CML_SOFTWARE_DIR}/${pkg}" "${base}/${pkg}" --overwrite=false
  while read -r def img || [[ -n "${def}" ]]; do
    [[ -z "${def}" || "${def}" == \#* ]] && continue
    run azcopy copy "${REFPLAT_DIR}/node-definitions/${def}.yaml" "${base}/refplat/node-definitions/${def}.yaml" --overwrite=false
    run azcopy copy "${REFPLAT_DIR}/virl-base-images/${img}" "${base}/refplat/virl-base-images/" --recursive --overwrite=false
  done < "${REFPLAT_FILE}"
  pass "uploads issued to ${base}"
}

main() {
  local iso base
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
  export AZCOPY_AUTO_LOGIN_TYPE=AZCLI
  export AZCOPY_LOG_LOCATION="${REPO_ROOT}/.azcopy" AZCOPY_JOB_PLAN_LOCATION="${REPO_ROOT}/.azcopy"
  mkdir -p "${AZCOPY_LOG_LOCATION}"
  echo "AZCOPY_LOG_LOCATION=${AZCOPY_LOG_LOCATION}"
  if [[ "${DRY_RUN}" != "1" ]]; then
    require_cmd azcopy az python3
  fi
  trap unmount_iso EXIT
  if [[ -z "${REFPLAT_DIR:-}" ]]; then
    iso="$(find_iso)"
    mount_iso "${iso}"
  fi
  base="$(storage_base)"
  verify_selection
  if [[ "${fail}" -gt 0 ]]; then
    summary_and_exit
  fi
  upload_all "${base}"
  summary_and_exit
}

main "$@"
