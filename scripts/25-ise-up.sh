#!/usr/bin/env bash
# Bring up the disposable ISE VM by az CLI, not Terraform. The operator
# chose az CLI over a terraform/ise root after a bad ISE-on-Terraform
# experience; see the TrustSec Phase 1 plan. Run this after
# scripts/20-up.sh: it reuses the persistent apps subnet and needs the
# CML host as an SSH jump for the readiness check, since ADR 0003 keeps
# ISE off any public address.
#
#   scripts/25-ise-up.sh [--dry-run]
#
# Order:
#   1. Read config/mcp-env/ise.env: Marketplace coordinates, size,
#      private IP, hostname, admin password (ADR 0004, gitignored).
#   2. Resolve resource_group_name, location, apps_subnet_id,
#      apps_subnet_cidr, lab_summary_cidr, public_ip_address from the
#      persistent root's outputs.
#   3. Render the ISE custom-data (scripts/lib/ise-userdata.sh) to
#      config/mcp-env/ise-userdata, mode 600. The admin password never
#      appears on the az command line.
#   4. Create the ISE NSG: RADIUS 1812/1813 UDP and CoA 1700 UDP from the
#      lab summary, admin 443 TCP and SSH 22 TCP from the operator
#      addresses in config/cml.tfvars. Never 0.0.0.0/0.
#   5. az vm create: the Marketplace image and plan, the static private
#      IP on the apps subnet, --custom-data the rendered file, no public
#      IP, project/role tags.
#   6. Tag the VM's auto-created NIC to match (az vm create tags only the
#      VM itself).
#   7. Poll https://<ise_private_ip>/admin/API/mnt/Version through the
#      CML host jump (port 1122) until it answers. Typically 30-45 min.
#
# The create prompts unless ASSUME_YES=1. --dry-run prints the plan and
# touches no Azure resource.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=scripts/lib/ise-userdata.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/ise-userdata.sh"

ISE_ENV_FILE="${ISE_ENV_FILE:-${REPO_ROOT}/config/mcp-env/ise.env}"
CML_TFVARS="${CML_TFVARS:-${REPO_ROOT}/config/cml.tfvars}"
TFVARS_PY="${REPO_ROOT}/scripts/lib/tfvars.py"
USERDATA_FILE="${REPO_ROOT}/config/mcp-env/ise-userdata"
SSH_PUBKEY="${REPO_ROOT}/keys/cml-lab.pub"
NSG_NAME="ise-nsg"
VM_NAME="ise"
READY_TIMEOUT_S="${ISE_READY_TIMEOUT_S:-2700}"
READY_INTERVAL_S="${ISE_READY_INTERVAL_S:-30}"
# An arbitrary high local port for the SSH forward to ISE's ERS API
# (ADR 0003: ISE has no public address, only the CML host jump reaches
# it). Fixed rather than picked at random so a dry run prints one
# deterministic plan.
ISE_FORWARD_LOCAL_PORT="${ISE_FORWARD_LOCAL_PORT:-18443}"
ISE_FORWARD_PID=""
DRY_RUN=0

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

# In a dry run the persistent root may not be applied, so an output falls
# back to a visible placeholder instead of aborting. Mirrors 20-up.sh.
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

load_ise_env() {
  [[ -f "${ISE_ENV_FILE}" ]] || die "${ISE_ENV_FILE} missing. Copy config/ise.env.example and fill it in"
  set -a
  # shellcheck disable=SC1090
  source "${ISE_ENV_FILE}"
  set +a
  : "${ISE_IMAGE_PUBLISHER:?missing in ${ISE_ENV_FILE}}"
  : "${ISE_IMAGE_OFFER:?missing in ${ISE_ENV_FILE}}"
  : "${ISE_IMAGE_SKU:?missing in ${ISE_ENV_FILE}}"
  : "${ISE_IMAGE_VERSION:?missing in ${ISE_ENV_FILE}}"
  : "${ISE_VM_SIZE:?missing in ${ISE_ENV_FILE}}"
  : "${ISE_PRIVATE_IP:?missing in ${ISE_ENV_FILE}}"
  : "${ISE_HOSTNAME:?missing in ${ISE_ENV_FILE}, see config/ise.env.example}"
  : "${ISE_ADMIN_PASSWORD:?missing in ${ISE_ENV_FILE}, see config/ise.env.example}"
  # Required up front, not just when the policy step runs: apply_ise_policy
  # (scripts/lib/ise_config.py) is the RADIUS client secret for the NAD it
  # registers, and a build should fail fast rather than 30-45 minutes into
  # wait_for_ise_ready.
  : "${RADIUS_SECRET:?missing in ${ISE_ENV_FILE}, see config/ise.env.example}"
}

# Operator addresses come from the same tfvars list that scopes the CML
# host's own NSG, so ISE's admin/SSH rules never reach wider than CML's
# already do. Falls back to a placeholder only when both the file is
# absent and this is a dry run, so the plan still prints.
operator_addresses() {
  if [[ -f "${CML_TFVARS}" ]]; then
    python3 "${TFVARS_PY}" "${CML_TFVARS}" allowed_ipv4_subnets_mgmt
  elif [[ "${DRY_RUN}" == "1" ]]; then
    echo "<allowed_ipv4_subnets_mgmt>"
  else
    die "config/cml.tfvars missing. Copy config/cml.tfvars.example and fill it in"
  fi
}

resolve_network() {
  RESOURCE_GROUP="$(out_or_placeholder resource_group_name)"
  LOCATION="$(out_or_placeholder location)"
  APPS_SUBNET_ID="$(out_or_placeholder apps_subnet_id)"
  APPS_SUBNET_CIDR="$(out_or_placeholder apps_subnet_cidr)"
  LAB_SUMMARY_CIDR="$(out_or_placeholder lab_summary_cidr)"
  CML_PUBLIC_IP="$(out_or_placeholder public_ip_address)"
}

render_userdata() {
  run render_ise_userdata "${USERDATA_FILE}"
}

# create_nsg: RADIUS and CoA from the lab summary (switches reaching ISE
# and the return path for CoA, ADR 0003); admin and SSH from the operator
# addresses only. Never 0.0.0.0/0.
create_nsg() {
  local mgmt
  mgmt="$(operator_addresses)"
  run az network nsg create -g "${RESOURCE_GROUP}" -n "${NSG_NAME}" -l "${LOCATION}" \
    --tags project=cml-azure-lab role=ise
  run az network nsg rule create -g "${RESOURCE_GROUP}" --nsg-name "${NSG_NAME}" \
    -n allow-radius --priority 100 --direction Inbound --access Allow \
    --protocol Udp --destination-port-ranges 1812 1813 \
    --source-address-prefixes "${LAB_SUMMARY_CIDR}"
  # Belt and suspenders, not the normal path: CoA is ISE-initiated outbound
  # to the NAD on 1700, and Azure NSGs are stateful, so the return traffic
  # for that flow needs no inbound rule here. This inbound allow is kept,
  # scoped to the lab summary, only to cover a NAD-initiated
  # disconnect/CoA-request edge case.
  run az network nsg rule create -g "${RESOURCE_GROUP}" --nsg-name "${NSG_NAME}" \
    -n allow-coa --priority 110 --direction Inbound --access Allow \
    --protocol Udp --destination-port-ranges 1700 \
    --source-address-prefixes "${LAB_SUMMARY_CIDR}"
  # shellcheck disable=SC2086 # mgmt is a deliberately space-separated list
  run az network nsg rule create -g "${RESOURCE_GROUP}" --nsg-name "${NSG_NAME}" \
    -n allow-admin --priority 120 --direction Inbound --access Allow \
    --protocol Tcp --destination-port-ranges 443 \
    --source-address-prefixes ${mgmt}
  # shellcheck disable=SC2086
  run az network nsg rule create -g "${RESOURCE_GROUP}" --nsg-name "${NSG_NAME}" \
    -n allow-ssh --priority 130 --direction Inbound --access Allow \
    --protocol Tcp --destination-port-ranges 22 \
    --source-address-prefixes ${mgmt}
}

# create_vm: the platform login (--ssh-key-values) is a formality Azure
# requires for every VM; ISE ignores it and never runs an SSH daemon on
# the network-appliance side. ISE's real admin password reaches it only
# through --custom-data, never this command line. No public IP: ADR 0003
# reaches ISE by SSH-forwarding through the CML host only.
create_vm() {
  run az vm create -g "${RESOURCE_GROUP}" -n "${VM_NAME}" -l "${LOCATION}" \
    --image "${ISE_IMAGE_PUBLISHER}:${ISE_IMAGE_OFFER}:${ISE_IMAGE_SKU}:${ISE_IMAGE_VERSION}" \
    --plan-name "${ISE_IMAGE_SKU}" --plan-product "${ISE_IMAGE_OFFER}" --plan-publisher "${ISE_IMAGE_PUBLISHER}" \
    --size "${ISE_VM_SIZE}" \
    --subnet "${APPS_SUBNET_ID}" --private-ip-address "${ISE_PRIVATE_IP}" \
    --nsg "${NSG_NAME}" --public-ip-address "" \
    --custom-data "${USERDATA_FILE}" \
    --authentication-type ssh --admin-username iseadmin --ssh-key-values "${SSH_PUBKEY}" \
    --tags project=cml-azure-lab role=ise
}

tag_nic() {
  run az network nic update -g "${RESOURCE_GROUP}" -n "${VM_NAME}VMNic" \
    --set tags.project=cml-azure-lab tags.role=ise
}

# wait_for_ise_ready: any HTTP response (curl's %{http_code} not 000)
# proves the API is answering, even before ISE has full credentials for
# it to authenticate a caller. Runs as a foreground loop with visible
# elapsed-time progress rather than a single blocking call, since the
# wait is the long pole (30-45 minutes).
wait_for_ise_ready() {
  local ip="$1" jump="$2" key="$3" elapsed=0 code
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ poll https://${ip}/admin/API/mnt/Version through ${jump}:1122 (up to $((READY_TIMEOUT_S / 60))m)"
    return 0
  fi
  echo "waiting for ISE at https://${ip}/admin/API/mnt/Version through the CML host jump..."
  while (( elapsed < READY_TIMEOUT_S )); do
    code="$(ssh -p 1122 -i "${key}" "${CML_SSH_OPTS[@]}" -o ConnectTimeout=10 "sysadmin@${jump}" \
      "curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://${ip}/admin/API/mnt/Version" 2>/dev/null || echo 000)"
    if [[ "${code}" != "000" ]]; then
      pass "ISE answered (HTTP ${code}) after $((elapsed / 60))m$((elapsed % 60))s"
      return 0
    fi
    sleep "${READY_INTERVAL_S}"
    elapsed=$((elapsed + READY_INTERVAL_S))
    printf "  ... still waiting, %dm%02ds elapsed\n" $((elapsed / 60)) $((elapsed % 60))
  done
  die "ISE did not answer within $((READY_TIMEOUT_S / 60)) minutes"
}

# open_ise_forward: a local SSH port forward through the CML host jump
# (ADR 0003, the same jump wait_for_ise_ready uses) from
# 127.0.0.1:ISE_FORWARD_LOCAL_PORT to ISE's private address on 443.
# ise_config.py stays on the Mac rather than running over an SSH exec, so
# ISE_ADMIN_PASSWORD and RADIUS_SECRET never cross a remote command line
# (ADR 0004); this forward is what lets it reach ISE's private address
# anyway. Backgrounded so apply_ise_policy can run ise_config.py against
# it and then close it again; the plan is printed by hand in a dry run
# since run() cannot both echo a plan and background a real command.
open_ise_forward() {
  local ise_ip="$1" jump="$2" key="$3"
  local cmd=(ssh -p 1122 -i "${key}" "${CML_SSH_OPTS[@]}" -o ConnectTimeout=10 \
    -N -L "${ISE_FORWARD_LOCAL_PORT}:${ise_ip}:443" "sysadmin@${jump}")
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ${cmd[*]}"
    return 0
  fi
  "${cmd[@]}" &
  ISE_FORWARD_PID=$!
  # Give the forward a moment to establish before ise_config.py dials it.
  sleep 2
}

# close_ise_forward: kill the background ssh from open_ise_forward, if
# one is running. Guarded so a dry run (no PID recorded) and a second
# call after an already-closed forward are both no-ops, never an
# unguarded kill.
close_ise_forward() {
  if [[ -n "${ISE_FORWARD_PID}" ]] && kill -0 "${ISE_FORWARD_PID}" 2>/dev/null; then
    kill "${ISE_FORWARD_PID}" 2>/dev/null || true
    wait "${ISE_FORWARD_PID}" 2>/dev/null || true
  fi
  ISE_FORWARD_PID=""
}

# apply_ise_policy: the minimal TrustSec Phase 1 policy, one network
# device and one authorization rule (scripts/lib/ise_config.py). Runs
# only after ISE answers, since the ERS API needs a fully booted node.
# ISE_ADMIN_PASSWORD and RADIUS_SECRET are already in this shell's
# environment from load_ise_env's `set -a` source, so ise_config.py reads
# them from its own environment; neither is ever passed as an argument,
# so neither can appear on a command line or in --dry-run output
# (ADR 0004). ISE_API_BASE points ise_config.py at the forwarded local
# port instead of ISE's unreachable private address (ADR 0003); the
# forward is torn down on the way out even if ise_config.py fails, via
# the EXIT trap.
apply_ise_policy() {
  local ise_ip="$1" jump="$2" key="$3"
  # Process-wide EXIT trap. Safe only because this is main()'s last
  # substantive step; if a later step needs its own EXIT trap, consolidate
  # both in main() instead of stacking traps here.
  trap close_ise_forward EXIT
  open_ise_forward "${ise_ip}" "${jump}" "${key}"
  ISE_API_BASE="https://127.0.0.1:${ISE_FORWARD_LOCAL_PORT}" \
    run python3 "${REPO_ROOT}/scripts/lib/ise_config.py"
  close_ise_forward
  trap - EXIT
}

main() {
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
  require_env ARM_SUBSCRIPTION_ID
  require_cmd terraform az python3 jq ssh
  load_ise_env
  resolve_network
  render_userdata
  confirm "Create the ISE VM (${ISE_VM_SIZE}, ${ISE_IMAGE_SKU}) at ${ISE_PRIVATE_IP} on the apps subnet?" || die "declined"
  create_nsg
  create_vm
  tag_nic
  wait_for_ise_ready "${ISE_PRIVATE_IP}" "${CML_PUBLIC_IP}" "${REPO_ROOT}/keys/cml-lab"
  apply_ise_policy "${ISE_PRIVATE_IP}" "${CML_PUBLIC_IP}" "${REPO_ROOT}/keys/cml-lab"
  pass "ISE ready. Reach it through the CML host jump (ADR 0003), never directly."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
