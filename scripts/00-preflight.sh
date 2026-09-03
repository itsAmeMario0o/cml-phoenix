#!/usr/bin/env bash
# Pre-build readiness check. Read-only. Run it before scripts/20-up.sh.
#
# Checks:
#   1. az login valid, ARM_SUBSCRIPTION_ID set and matching
#   2. Toolchain: terraform az azcopy jq uv uvx python3 shellcheck pre-commit gitleaks
#   3. terraform fmt -check and validate on bootstrap, persistent, vendor/cloud-cml
#   4. Submodule at the pinned commit
#   5. config/cml.tfvars present, parses, no 0.0.0.0/0, refplat.txt parses
#   6. vCPU quota in the region for the requested size (family and regional)
#   7. Package and every listed refplat image present in the cml container
#      (skipped with a WARN until the persistent root has been applied)
#   8. Estimated copy time versus SAS validity (WARN only)
#
# Writes .preflight-ok in the repo root when nothing FAILs; 20-up.sh refuses
# to run without a fresh marker. Exit 1 on any FAIL.
#
# Overrides: LOCATION (eastus2), CML_TFVARS, REFPLAT_FILE, ASSUMED_MBPS (50).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

LOCATION="${LOCATION:-eastus2}"
CML_TFVARS="${CML_TFVARS:-${REPO_ROOT}/config/cml.tfvars}"
REFPLAT_FILE="${REFPLAT_FILE:-${REPO_ROOT}/config/refplat.txt}"
ASSUMED_MBPS="${ASSUMED_MBPS:-50}"
TFVARS_PY="${REPO_ROOT}/scripts/lib/tfvars.py"
MARKER="${REPO_ROOT}/.preflight-ok"

tfvar() { python3 "${TFVARS_PY}" "${CML_TFVARS}" "$1" 2>/dev/null; }

check_login() {
  local user sub_id
  if user="$(az account show --query user.name -o tsv 2>/dev/null)" && [[ -n "${user}" ]]; then
    pass "azure login: ${user}"
  else
    miss "azure login: not signed in. Run: az login"
    return 0
  fi
  if [[ -z "${ARM_SUBSCRIPTION_ID:-}" ]]; then
    miss "ARM_SUBSCRIPTION_ID: not set. See docs/PREREQUISITES.md section 2.2"
    return 0
  fi
  sub_id="$(az account show --query id -o tsv 2>/dev/null)"
  if [[ "${sub_id}" == "${ARM_SUBSCRIPTION_ID}" ]]; then
    pass "ARM_SUBSCRIPTION_ID matches the active subscription"
  else
    miss "ARM_SUBSCRIPTION_ID does not match az account show. Run: az account set"
  fi
}

check_tools() {
  local tool
  for tool in terraform az azcopy jq uv uvx python3 shellcheck pre-commit gitleaks ssh-keygen; do
    if command -v "${tool}" >/dev/null 2>&1; then
      pass "tool ${tool}"
    else
      miss "tool ${tool}: not installed. See docs/PREREQUISITES.md section 4"
    fi
  done
}

check_terraform_root() {
  local dir="$1" label="$2"
  if [[ ! -d "${dir}" ]]; then
    miss "terraform ${label}: ${dir} missing"
    return 0
  fi
  if terraform -chdir="${dir}" fmt -check -recursive >/dev/null 2>&1; then
    pass "terraform fmt ${label}"
  else
    miss "terraform fmt ${label}: run terraform -chdir=${dir} fmt -recursive"
  fi
  if [[ ! -d "${dir}/.terraform" ]]; then
    terraform -chdir="${dir}" init -backend=false -input=false >/dev/null 2>&1 || true
  fi
  if terraform -chdir="${dir}" validate >/dev/null 2>&1; then
    pass "terraform validate ${label}"
  else
    miss "terraform validate ${label}: run terraform -chdir=${dir} validate"
  fi
}

check_submodule() {
  local line
  line="$(cd "${REPO_ROOT}" && git submodule status vendor/cloud-cml 2>/dev/null || true)"
  case "${line}" in
    " "*) pass "submodule vendor/cloud-cml at pinned commit" ;;
    "+"*) miss "submodule vendor/cloud-cml differs from the pinned commit. Run: git submodule update" ;;
    "-"*) miss "submodule vendor/cloud-cml not initialized. Run: git submodule update --init" ;;
    *) miss "submodule vendor/cloud-cml: unexpected status '${line}'" ;;
  esac
}

check_config() {
  local key list
  if [[ ! -f "${CML_TFVARS}" ]]; then
    miss "config/cml.tfvars: missing. Copy config/cml.tfvars.example and fill it in"
    return 0
  fi
  pass "config/cml.tfvars present"
  for key in smartlicense_token license_flavor vm_size software_package sas_validity; do
    if [[ -n "$(tfvar "${key}")" ]]; then
      pass "cml.tfvars ${key} set"
    else
      miss "cml.tfvars ${key}: missing or unparsable"
    fi
  done
  if [[ "$(tfvar smartlicense_token)" == "PASTE-TOKEN-HERE" ]]; then
    miss "cml.tfvars smartlicense_token is still the placeholder"
  fi
  for key in allowed_ipv4_subnets_mgmt allowed_ipv4_subnets_cml2; do
    list="$(tfvar "${key}")"
    if [[ -z "${list}" ]]; then
      miss "cml.tfvars ${key}: empty"
    elif grep -q "0.0.0.0/0" <<<"${list}"; then
      miss "cml.tfvars ${key} contains 0.0.0.0/0"
    else
      pass "cml.tfvars ${key}: ${list}"
    fi
  done
  if [[ -f "${REFPLAT_FILE}" ]] && [[ "$(grep -cvE '^\s*(#|$)' "${REFPLAT_FILE}")" -gt 0 ]]; then
    pass "refplat.txt lists $(grep -cvE '^\s*(#|$)' "${REFPLAT_FILE}") images"
  else
    miss "config/refplat.txt missing or empty"
  fi
}

check_quota() {
  local size family vcpus limit total
  size="$(tfvar vm_size)"
  [[ -n "${size}" ]] || return 0
  family="$(az vm list-skus -l "${LOCATION}" --size "${size}" --query "[0].family" -o tsv 2>/dev/null || true)"
  vcpus="$(az vm list-skus -l "${LOCATION}" --size "${size}" --query "[0].capabilities[?name=='vCPUs'].value | [0]" -o tsv 2>/dev/null || true)"
  if [[ -z "${family}" || -z "${vcpus}" ]]; then
    miss "quota: size ${size} not found in ${LOCATION}"
    return 0
  fi
  limit="$(az vm list-usage -l "${LOCATION}" --query "[?name.value=='${family}'].limit | [0]" -o tsv 2>/dev/null || echo 0)"
  total="$(az vm list-usage -l "${LOCATION}" --query "[?name.value=='cores'].limit | [0]" -o tsv 2>/dev/null || echo 0)"
  if [[ "${limit:-0}" -ge "${vcpus}" ]]; then
    pass "quota ${family} in ${LOCATION}: ${limit} (need ${vcpus} for ${size})"
  else
    miss "quota ${family} in ${LOCATION}: ${limit:-0}, need ${vcpus}. See docs/PREREQUISITES.md section 2.1"
  fi
  if [[ "${total:-0}" -ge "${vcpus}" ]]; then
    pass "quota regional vCPUs in ${LOCATION}: ${total}"
  else
    miss "quota regional vCPUs in ${LOCATION}: ${total:-0}, need ${vcpus}"
  fi
}

sas_seconds() {
  local v="$1"
  case "${v}" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *) echo 0 ;;
  esac
}

check_blobs() {
  local sa pkg def img count bytes total_bytes=0 est validity
  if ! sa="$(tf_out persistent storage_account_name 2>/dev/null)" || [[ -z "${sa}" ]]; then
    warn "blob checks skipped: persistent root not applied yet"
    return 0
  fi
  pkg="$(tfvar software_package)"
  if az storage blob show --auth-mode login --account-name "${sa}" -c cml -n "${pkg}" -o none 2>/dev/null; then
    pass "blob ${pkg} present"
  else
    miss "blob ${pkg} missing in container cml. Run: scripts/10-upload-images.sh"
  fi
  while read -r def img; do
    [[ -z "${def}" || "${def}" == \#* ]] && continue
    if az storage blob show --auth-mode login --account-name "${sa}" -c cml -n "refplat/node-definitions/${def}.yaml" -o none 2>/dev/null; then
      pass "blob node definition ${def}"
    else
      miss "blob node definition ${def} missing"
    fi
    count="$(az storage blob list --auth-mode login --account-name "${sa}" -c cml --prefix "refplat/virl-base-images/${img}/" --query "length(@)" -o tsv 2>/dev/null || echo 0)"
    if [[ "${count:-0}" -gt 0 ]]; then
      bytes="$(az storage blob list --auth-mode login --account-name "${sa}" -c cml --prefix "refplat/virl-base-images/${img}/" --query "sum([].properties.contentLength)" -o tsv 2>/dev/null || echo 0)"
      total_bytes=$(( total_bytes + ${bytes:-0} ))
      pass "blob image ${img} ($(( ${bytes:-0} / 1048576 )) MB)"
    else
      miss "blob image ${img} missing. Run: scripts/10-upload-images.sh"
    fi
  done < "${REFPLAT_FILE}"
  validity="$(sas_seconds "$(tfvar sas_validity)")"
  est=$(( total_bytes / (ASSUMED_MBPS * 1048576) ))
  if [[ "${validity}" -gt 0 && "${est}" -gt $(( validity * 8 / 10 )) ]]; then
    warn "image copy estimate ${est}s at ${ASSUMED_MBPS} MB/s is close to SAS validity ${validity}s. Raise sas_validity"
  else
    pass "image copy estimate ${est}s within SAS validity ${validity}s"
  fi
}

main() {
  rm -f "${MARKER}"
  check_login
  check_tools
  check_terraform_root "${REPO_ROOT}/terraform/bootstrap" bootstrap
  check_terraform_root "${REPO_ROOT}/terraform/persistent" persistent
  check_terraform_root "${REPO_ROOT}/vendor/cloud-cml" cloud-cml
  check_submodule
  check_config
  if [[ -f "${CML_TFVARS}" ]] && command -v az >/dev/null 2>&1; then
    check_quota
    check_blobs
  fi
  if [[ "${fail}" -eq 0 ]]; then
    touch "${MARKER}"
  fi
  summary_and_exit
}

main "$@"
