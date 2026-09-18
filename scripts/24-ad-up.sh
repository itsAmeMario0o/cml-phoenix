#!/usr/bin/env bash
# Bring up the session's Active Directory domain controller.
#
#   scripts/24-ad-up.sh [--dry-run]
#
# 1. terraform init and apply in terraform/ad: one Windows Server VM on the
#    apps subnet beside ISE, then forest promotion, an Enterprise Root CA,
#    and the lab identities, each by run command
# 2. Write config/mcp-env/ad.env, mode 0600, from the root's outputs
# 3. Three readiness checks over az vm run-command
# 4. Print the two values the ISE portal form needs
#
# Runs before the ISE portal deploy; scripts/46-ad-down.sh tears it down
# after ISE. ADR 0010. --dry-run prints the sequence. The apply asks for
# its own approval unless ASSUME_YES=1.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

AD_ROOT="${REPO_ROOT}/terraform/ad"
PERSISTENT_TFVARS="${REPO_ROOT}/terraform/persistent/terraform.tfvars"
AD_ENV="${AD_ENV:-${REPO_ROOT}/config/mcp-env/ad.env}"
DC_NAME="dc1"
DRY_RUN="${DRY_RUN:-0}"

# ad_tf_args: fill AD_TF_ARGS with the -var arguments both apply and
# destroy need. Owner and expires come from the persistent root's tfvars,
# the network values from its outputs, so nothing is typed twice. It sets
# an array in the calling shell rather than printing lines: bash runs a
# "$(...)" with errexit off, so `-var=x=$(out_or_placeholder x)` once gave
# five empty -var= lines and exit 0, and `done < <(ad_tf_args)` hid the
# status from both callers (architecture review, 2026-09-17). Each plain
# assignment below is what set -e stops on.
ad_tf_args() {
  local rg location subnet_id subnet_cidr cml_ip
  rg="$(out_or_placeholder resource_group_name)"
  location="$(out_or_placeholder location)"
  subnet_id="$(out_or_placeholder apps_subnet_id)"
  subnet_cidr="$(out_or_placeholder apps_subnet_cidr)"
  cml_ip="$(out_or_placeholder cml_private_ip)"
  AD_TF_ARGS=(
    "-var-file=${PERSISTENT_TFVARS}"
    "-var=resource_group_name=${rg}"
    "-var=location=${location}"
    "-var=apps_subnet_id=${subnet_id}"
    "-var=apps_subnet_cidr=${subnet_cidr}"
    "-var=cml_private_ip=${cml_ip}"
  )
}

# clear_failed_run_commands: a run command that failed exists in Azure but
# not in Terraform's state, so the next apply stops at "already exists".
# Deleting it first is what makes rerunning this script a real recovery
# (learned 2026-09-17). Quiet when the VM does not exist yet.
clear_failed_run_commands() {
  local rg name
  rg="$(out_or_placeholder resource_group_name)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ delete any Failed run command on ${DC_NAME} (az vm run-command list, then delete)"
    return 0
  fi
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    warn "removing failed run command ${name} so terraform can send it again"
    az vm run-command delete -g "${rg}" --vm-name "${DC_NAME}" --run-command-name "${name}" --yes >/dev/null
  done < <(az vm run-command list -g "${rg}" --vm-name "${DC_NAME}" \
    --query "[?provisioningState=='Failed'].name" -o tsv 2>/dev/null || true)
}

apply_root() {
  ad_tf_args
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    AD_TF_ARGS+=("-auto-approve")
  fi
  run terraform -chdir="${AD_ROOT}" init -input=false
  run terraform -chdir="${AD_ROOT}" apply "${AD_TF_ARGS[@]}"
}

# write_ad_env: the passwords go from terraform's JSON straight into the
# file. Nothing here echoes a value, and the file is created 0600.
write_ad_env() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ write ${AD_ENV} mode 0600 from terraform output (values never printed)"
    return 0
  fi
  local json
  json="$(terraform -chdir="${AD_ROOT}" output -json)" || die "terraform/ad has no outputs; did the apply finish?"
  (
    umask 077
    # Values are single quoted in the file so that sourcing it never
    # expands a symbol in a password; the generated set has no quote.
    jq -r --arg q "'" '
      "AD_DOMAIN=\(.domain_name.value)",
      "AD_NETBIOS=\(.netbios_name.value)",
      "AD_DC_IP=\(.dc_private_ip.value)",
      "AD_ADMIN_USERNAME=\($q)\(.admin_username.value)\($q)",
      "AD_ADMIN_PASSWORD=\($q)\(.admin_password.value)\($q)",
      "AD_SVC_ISE_PASSWORD=\($q)\(.svc_ise_password.value)\($q)",
      "AD_LAB_USER_PASSWORD=\($q)\(.lab_user_password.value)\($q)"
    ' <<<"${json}" > "${AD_ENV}"
  )
  chmod 600 "${AD_ENV}"
  pass "wrote ${AD_ENV} (mode 0600)"
}

# dc_check LABEL EXPECT SCRIPT: run SCRIPT on the DC, pass when its output
# contains EXPECT. Runs as SYSTEM, which on a DC can read the directory.
# SCRIPT runs under $ErrorActionPreference='Stop': cmdlet failures are
# non-terminating by default, so the DNS check's trailing 'dns-ok' was
# printed whether or not Resolve-DnsName resolved anything (architecture
# review, 2026-09-17). With Stop the first failure ends the script and
# EXPECT never appears.
dc_check() {
  local label="$1" expect="$2" script="$3" rg out
  script="\$ErrorActionPreference='Stop'; ${script}"
  rg="$(out_or_placeholder resource_group_name)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ az vm run-command invoke -g ${rg} -n ${DC_NAME} --command-id RunPowerShellScript --scripts ${script}"
    return 0
  fi
  out="$(az vm run-command invoke -g "${rg}" -n "${DC_NAME}" --command-id RunPowerShellScript \
    --scripts "${script}" --query "value[0].message" -o tsv 2>&1 || true)"
  if [[ "${out}" == *"${expect}"* ]]; then
    pass "${label}"
  else
    miss "${label}: expected '${expect}' in the DC's answer"
  fi
}

verify_dc() {
  local domain="corp.rooez.com"
  if [[ "${DRY_RUN}" != "1" ]]; then
    # shellcheck source=/dev/null
    source "${AD_ENV}"
    domain="${AD_DOMAIN}"
  fi
  dc_check "directory answers for ${domain}" "${domain}" "(Get-ADDomain).DNSRoot"
  dc_check "DNS resolves the zone and, through the forwarder, a public name" "dns-ok" \
    "Resolve-DnsName ${DC_NAME}.${domain} -Server 127.0.0.1 | Out-Null; Resolve-DnsName login.microsoftonline.com -Server 127.0.0.1 | Out-Null; 'dns-ok'"
  dc_check "certification authority is alive" "interface is alive" "certutil -ping | Out-String"
}

print_ise_values() {
  local ip="10.20.2.10" domain="corp.rooez.com"
  if [[ "${DRY_RUN}" != "1" ]]; then
    ip="${AD_DC_IP}"
    domain="${AD_DOMAIN}"
  fi
  echo "ISE portal form, Network Settings:"
  echo "  Primary Name Server: ${ip}"
  echo "  DNS domain name:     ${domain}"
  echo "RDP: add 'dc 3389 ${ip} 3389' to config/tunnels.conf, scripts/50-tunnels.sh up, then localhost:3389"
}

main() {
  DRY_RUN="$(parse_dry_run_only "$@")"
  require_env ARM_SUBSCRIPTION_ID
  if [[ "${DRY_RUN}" != "1" ]]; then
    require_cmd terraform az jq
    [[ -f "${PERSISTENT_TFVARS}" ]] || die "missing ${PERSISTENT_TFVARS}; the persistent root supplies owner and expires"
  fi
  confirm "Build the domain controller (terraform/ad, one Windows VM, about 20 minutes)?" || die "declined"
  clear_failed_run_commands
  apply_root
  write_ad_env
  verify_dc
  print_ise_values
  summary_and_exit
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
