#!/usr/bin/env bash
# Bring the lab up: bootstrap (once), persistent, then the CML VM.
#
#   scripts/20-up.sh [--dry-run]
#
# Order:
#   1. Refuse unless .preflight-ok is fresh (PREFLIGHT_MAX_AGE_MIN, 240)
#   2. Generate keys/cml-lab if missing (RSA 4096)
#   3. Bootstrap apply if it has no local state; verify backend.tf matches
#   4. Persistent init and apply
#   5. Refuse if the CML VM already exists
#   6. Render config/cml.yml from persistent outputs, cml.tfvars, refplat.txt
#      (render_config in scripts/lib/common.sh, shared with 40-down.sh)
#   7. cloud-cml init and apply (its readiness module waits for the API)
#   8. Write config/mcp-env/cml.env, print URL, IP, and the del.sh command
#
# Every apply prompts unless ASSUME_YES=1. --dry-run prints what would run.
# Never runs destroy. Never touches bootstrap or persistent with destroy.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PREFLIGHT_MAX_AGE_MIN="${PREFLIGHT_MAX_AGE_MIN:-240}"
KEY_FILE="${REPO_ROOT}/keys/cml-lab"
ENV_FILE="${REPO_ROOT}/config/mcp-env/cml.env"
BOOTSTRAP="${REPO_ROOT}/terraform/bootstrap"
PERSISTENT="${REPO_ROOT}/terraform/persistent"
CLOUD_CML="${REPO_ROOT}/vendor/cloud-cml"
DRY_RUN=0

check_preflight_marker() {
  local marker="${REPO_ROOT}/.preflight-ok" age
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "dry run: skipping preflight marker check"
    return 0
  fi
  [[ -f "${marker}" ]] || die "no preflight marker. Run: scripts/00-preflight.sh"
  age=$(( ( $(date +%s) - $(stat -f %m "${marker}") ) / 60 ))
  if [[ "${age}" -gt "${PREFLIGHT_MAX_AGE_MIN}" ]]; then
    die "preflight marker is ${age} minutes old. Run: scripts/00-preflight.sh"
  fi
  pass "preflight marker ${age} minutes old"
}

ensure_ssh_key() {
  if [[ -f "${KEY_FILE}" && -f "${KEY_FILE}.pub" ]]; then
    pass "ssh key ${KEY_FILE}"
    return 0
  fi
  mkdir -p "${REPO_ROOT}/keys"
  run ssh-keygen -t rsa -b 4096 -N "" -C "cml-lab" -f "${KEY_FILE}"
}

apply_bootstrap() {
  if [[ "${DRY_RUN}" != "1" && -f "${BOOTSTRAP}/terraform.tfstate" ]]; then
    pass "bootstrap already applied"
  else
    confirm "Apply the bootstrap root (state storage account)?" || die "declined"
    run terraform -chdir="${BOOTSTRAP}" init -input=false
    run terraform -chdir="${BOOTSTRAP}" apply -input=false -auto-approve
  fi
  if [[ "${DRY_RUN}" != "1" ]]; then
    local sa
    sa="$(tf_out bootstrap storage_account_name)" || die "bootstrap output storage_account_name unavailable"
    grep -q "storage_account_name *= *\"${sa}\"" "${PERSISTENT}/backend.tf" ||
      die "terraform/persistent/backend.tf does not name ${sa}. Fix it and commit (plan Task 5)."
  fi
}

apply_persistent() {
  confirm "Apply the persistent root (network, IP, 512 GB disk, storage)?" || die "declined"
  run terraform -chdir="${PERSISTENT}" init -input=false
  run terraform -chdir="${PERSISTENT}" apply -input=false -auto-approve
}

refuse_if_vm_exists() {
  local rg stderr_output
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "dry run: skipping VM existence check"
    return 0
  fi
  rg="$(out_or_placeholder resource_group_name)"
  if stderr_output="$(az vm show -g "${rg}" -n cml-controller -o none 2>&1 >/dev/null)"; then
    die "VM cml-controller already exists in ${rg}. Run scripts/40-down.sh first."
  fi
  if grep -qE "ResourceNotFound|ResourceGroupNotFound|was not found|could not be found" <<<"${stderr_output}"; then
    pass "no existing CML VM in ${rg}"
  else
    die "cannot query VM state: $(head -1 <<<"${stderr_output}")"
  fi
}

# The VM being built will present a new host key. Drop the previous one
# from the repo-local known_hosts so accept-new can pin the new key instead
# of refusing it. ssh-keygen -R is a no-op on a missing file or entry.
forget_host_key() {
  local ip
  ip="$(out_or_placeholder public_ip_address)"
  if [[ "${DRY_RUN}" == "1" || -f "${CML_KNOWN_HOSTS}" ]]; then
    run ssh-keygen -R "[${ip}]:1122" -f "${CML_KNOWN_HOSTS}"
  fi
}

apply_cml() {
  local tenant
  tenant="$(az account show --query tenantId -o tsv)"
  export TF_VAR_cfg_file="${CML_YML}"
  export TF_VAR_azure_subscription_id="${ARM_SUBSCRIPTION_ID}"
  export TF_VAR_azure_tenant_id="${tenant}"
  confirm "Apply the CML root (creates the VM, registers the license)?" || die "declined"
  run terraform -chdir="${CLOUD_CML}" init -input=false
  run terraform -chdir="${CLOUD_CML}" apply -input=false -auto-approve
}

write_env_and_report() {
  local ip pw
  ip="$(out_or_placeholder public_ip_address)"
  pw="$(out_or_placeholder app_admin_password)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ write ${ENV_FILE}"
  else
    mkdir -p "$(dirname "${ENV_FILE}")"
    ( umask 077; printf 'CML_URL=https://%s\nCML_USERNAME=admin\nCML_PASSWORD=%s\nCML_VERIFY_SSL=false\n' "${ip}" "${pw}" > "${ENV_FILE}" )
    pass "wrote ${ENV_FILE}"
  fi
  echo
  echo "CML URL:      https://${ip}"
  echo "CML IP:       ${ip}"
  echo "SSH:          ssh -p 1122 -i ${KEY_FILE} sysadmin@${ip}"
  echo "Deregister:   ssh -p 1122 -i ${KEY_FILE} sysadmin@${ip} /provision/del.sh"
  echo "Next:         scripts/90-smoke-test.sh"
}

main() {
  DRY_RUN="$(parse_dry_run_only "$@")"
  require_env ARM_SUBSCRIPTION_ID
  require_cmd terraform az python3 ssh-keygen jq
  check_preflight_marker
  ensure_ssh_key
  apply_bootstrap
  apply_persistent
  refuse_if_vm_exists
  render_config
  forget_host_key
  apply_cml
  write_env_and_report
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
