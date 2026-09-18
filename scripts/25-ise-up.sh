#!/usr/bin/env bash
# Post-deploy config for ISE, run after the portal Marketplace deploy
# (docs/ISE-MARKETPLACE-DEPLOY.md). The automated `az deployment group
# create` path is retired: ISE terminally fails Azure's OS-provisioning
# handshake on that path (ADR 0008 amendment, 2026-09-13), even though the
# portal's Marketplace flow deploys the same image and lets it boot. This
# script never creates the VM. It attaches the NSG the wizard cannot,
# tags the VM and its disk, waits for ISE to answer, and applies the
# minimal TrustSec Phase 1 policy.
#
#   scripts/25-ise-up.sh --post-deploy [--dry-run]
#
# --post-deploy is required, not optional: there is no other mode left,
# and naming it keeps this command line matching what the walkthrough and
# docs/superpowers/specs/2026-09-13-active-directory-session-design.md
# already document.
#
# Order:
#   1. Read config/mcp-env/ise.env: hostname, private IP, admin password,
#      admin source CIDR, the RADIUS shared secret (ADR 0004, gitignored).
#   2. Resolve resource_group_name, location, lab_summary_cidr,
#      public_ip_address from the persistent root's outputs.
#   3. Create the ISE NSG (RADIUS from the lab summary, admin 443/22 from
#      ISE_ADMIN_SOURCE_CIDR only, never 0.0.0.0/0) and attach it to the
#      NIC the wizard created, since the wizard's own NSG handling cannot
#      do that itself.
#   4. Tag the VM and its OS disk role=ise so teardown by tag
#      (scripts/45-ise-down.sh) catches both.
#   5. Poll https://<ise_private_ip>/admin/API/mnt/Version through the CML
#      host jump (port 1122) until it answers. Typically 30-45 min.
#   6. Apply the minimal TrustSec Phase 1 policy (scripts/lib/ise_config.py)
#      through a local forward to the same jump.
#
# ADR 0003 routes operator administration of every lab node, ISE
# included, through the CML host jump; ADR 0008 keeps that even though
# ISE gets its own public IP. The deploy prompts unless ASSUME_YES=1.
# --dry-run prints the plan and touches no Azure resource.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ISE_ENV_FILE="${ISE_ENV_FILE:-${REPO_ROOT}/config/mcp-env/ise.env}"
NSG_NAME="ise-nsg"
READY_TIMEOUT_S="${ISE_READY_TIMEOUT_S:-2700}"
READY_INTERVAL_S="${ISE_READY_INTERVAL_S:-30}"
# An arbitrary high local port for the SSH forward to ISE's ERS API
# (ADR 0003: operator administration of ISE goes through the CML host
# jump, never ISE's own public IP). Fixed rather than picked at random so
# a dry run prints one deterministic plan.
ISE_FORWARD_LOCAL_PORT="${ISE_FORWARD_LOCAL_PORT:-18443}"
ISE_FORWARD_PID=""
DRY_RUN=0

usage() {
  echo "usage: scripts/25-ise-up.sh --post-deploy [--dry-run]" >&2
  exit 2
}

load_ise_env() {
  [[ -f "${ISE_ENV_FILE}" ]] || die "${ISE_ENV_FILE} missing. Copy config/ise.env.example and fill it in"
  set -a
  # shellcheck disable=SC1090
  source "${ISE_ENV_FILE}"
  set +a
  : "${ISE_HOSTNAME:?missing in ${ISE_ENV_FILE}, see config/ise.env.example}"
  : "${ISE_PRIVATE_IP:?missing in ${ISE_ENV_FILE}}"
  : "${ISE_ADMIN_PASSWORD:?missing in ${ISE_ENV_FILE}, see config/ise.env.example}"
  # Scopes the ISE admin/SSH NSG rule. Required up front, same reasoning
  # as RADIUS_SECRET below: fail fast, not 30-45 minutes into
  # wait_for_ise_ready.
  : "${ISE_ADMIN_SOURCE_CIDR:?missing in ${ISE_ENV_FILE}, see config/ise.env.example}"
  # apply_ise_policy (scripts/lib/ise_config.py) is the RADIUS client
  # secret for the NAD it registers, and a build should fail fast rather
  # than partway through the deploy.
  : "${RADIUS_SECRET:?missing in ${ISE_ENV_FILE}, see config/ise.env.example}"
}

resolve_network() {
  RESOURCE_GROUP="$(out_or_placeholder resource_group_name)"
  LOCATION="$(out_or_placeholder location)"
  LAB_SUMMARY_CIDR="$(out_or_placeholder lab_summary_cidr)"
  CML_PUBLIC_IP="$(out_or_placeholder public_ip_address)"
}

# attach_nsg: RADIUS from the lab summary (switches reaching ISE, ADR
# 0003); admin and SSH from ISE_ADMIN_SOURCE_CIDR only, the CML host
# address per ADR 0008; never 0.0.0.0/0. The portal wizard's NSG handling
# is limited, so it deploys with none, and this is the first place these
# rules actually take effect (docs/ISE-MARKETPLACE-DEPLOY.md).
attach_nsg() {
  run az network nsg create -g "${RESOURCE_GROUP}" -n "${NSG_NAME}" -l "${LOCATION}" \
    --tags project=cml-azure-lab role=ise
  run az network nsg rule create -g "${RESOURCE_GROUP}" --nsg-name "${NSG_NAME}" \
    -n allow-radius --priority 100 --direction Inbound --access Allow \
    --protocol Udp --destination-port-ranges 1812 1813 \
    --source-address-prefixes "${LAB_SUMMARY_CIDR}"
  run az network nsg rule create -g "${RESOURCE_GROUP}" --nsg-name "${NSG_NAME}" \
    -n allow-admin --priority 110 --direction Inbound --access Allow \
    --protocol Tcp --destination-port-ranges 443 22 \
    --source-address-prefixes "${ISE_ADMIN_SOURCE_CIDR}"
  run az network nic update -g "${RESOURCE_GROUP}" -n "${ISE_HOSTNAME}nic" \
    --network-security-group "${NSG_NAME}"
}

# tag_resources: the wizard tags nothing. Tag the VM and its OS disk
# role=ise so 45-ise-down.sh's tag-based teardown catches both; the NSG
# is already tagged by attach_nsg above.
tag_resources() {
  run az resource tag -g "${RESOURCE_GROUP}" --tags project=cml-azure-lab role=ise \
    --name "${ISE_HOSTNAME}" --resource-type Microsoft.Compute/virtualMachines
  run az disk update -g "${RESOURCE_GROUP}" -n "${ISE_HOSTNAME}osdisk" \
    --set tags.project=cml-azure-lab tags.role=ise
  # The wizard names the NIC <host>nic and the public IP <host>-ip. Without
  # the tag, 45-ise-down.sh leaves both behind; seen on 2026-09-17.
  run az resource tag -g "${RESOURCE_GROUP}" --tags project=cml-azure-lab role=ise \
    --name "${ISE_HOSTNAME}nic" --resource-type Microsoft.Network/networkInterfaces
  run az resource tag -g "${RESOURCE_GROUP}" --tags project=cml-azure-lab role=ise \
    --name "${ISE_HOSTNAME}-ip" --resource-type Microsoft.Network/publicIPAddresses
}

# wait_for_ise_ready: any HTTP response (curl's %{http_code} not 000)
# proves the API is answering, even before ISE has full credentials for
# it to authenticate a caller. Runs as a foreground loop with visible
# elapsed-time progress rather than a single blocking call, since the
# wait is the long pole (30-45 minutes).
# is_ready_status CODE: true for a three-digit status below 500. ISE's
# front end answers 502 for minutes before the application behind it is
# up, so a 5xx is still "not ready"; 200, 401, and 404 all prove the
# application is serving.
is_ready_status() {
  [[ "$1" =~ ^[1-4][0-9][0-9]$ ]]
}

wait_for_ise_ready() {
  local ip="$1" jump="$2" key="$3" elapsed=0 code
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ poll https://${ip}/admin/API/mnt/Version through ${jump}:1122 (up to $((READY_TIMEOUT_S / 60))m)"
    return 0
  fi
  # The loop below reads any ssh failure as "not ready", so a dead jump
  # would look like 45 minutes of ISE booting (architecture review,
  # 2026-09-17). Prove the jump answers once before waiting on ISE.
  cml_ssh true || die "CML host jump ${jump} does not answer on port 1122; ISE is only reachable through it (ADR 0003)"
  echo "waiting for ISE at https://${ip}/admin/API/mnt/Version through the CML host jump..."
  while (( elapsed < READY_TIMEOUT_S )); do
    code="$(ssh -p 1122 -i "${key}" "${CML_SSH_OPTS[@]}" -o ConnectTimeout=10 "sysadmin@${jump}" \
      "curl -sk -o /dev/null -w '%{http_code}' --max-time 10 https://${ip}/admin/API/mnt/Version" 2>/dev/null || echo 000)"
    # A refused connection makes the remote curl print 000 and exit
    # nonzero, so the fallback above appends a second 000. Only a real
    # HTTP status below 500 counts; "000000" declared ISE ready at 0s and
    # a 502 declared it ready at 28m, both on 2026-09-17.
    if is_ready_status "${code}"; then
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
# port instead of ISE's private address (ADR 0003); the forward is torn
# down on the way out even if ise_config.py fails, via the EXIT trap.
apply_ise_policy() {
  local ise_ip="$1" jump="$2" key="$3"
  open_ise_forward "${ise_ip}" "${jump}" "${key}"
  ISE_API_BASE="https://127.0.0.1:${ISE_FORWARD_LOCAL_PORT}" \
    run python3 "${REPO_ROOT}/scripts/lib/ise_config.py"
  close_ise_forward
}

# cleanup_on_exit: closes any still-open ISE forward. Set once in main()
# rather than stacked per function, since bash 3.2 traps replace, not
# stack, so a second `trap ... EXIT` would silently drop the first.
# Already a guarded no-op when there is nothing to clean up, so this is
# safe to run on every exit path, success or failure, at any stage.
cleanup_on_exit() {
  close_ise_forward
}

# check_directory_first: ISE's DNS server and domain are the directory's
# (ADR 0010), so the DC is built before the portal deploy. This runs after
# the deploy, too late to stop it, so it can only say so loudly.
AD_ENV="${AD_ENV:-${REPO_ROOT}/config/mcp-env/ad.env}"
check_directory_first() {
  if [[ -f "${AD_ENV}" ]]; then
    pass "directory was built first (${AD_ENV} present)"
  else
    warn "no ${AD_ENV}: ISE was deployed without the domain controller. Its DNS and domain will not be the directory's; see docs/AD.md to repoint it"
  fi
}

main() {
  local post_deploy=0 arg
  for arg in "$@"; do
    case "${arg}" in
      --post-deploy) post_deploy=1 ;;
      --dry-run) DRY_RUN=1 ;;
      *) usage ;;
    esac
  done
  [[ "${post_deploy}" == "1" ]] || usage
  require_env ARM_SUBSCRIPTION_ID
  require_cmd az terraform jq python3 ssh
  load_ise_env
  resolve_network
  check_directory_first
  trap cleanup_on_exit EXIT
  confirm "Apply post-deploy config to ISE ${ISE_HOSTNAME} (${ISE_PRIVATE_IP}) in ${RESOURCE_GROUP}?" || die "declined"
  attach_nsg
  tag_resources
  wait_for_ise_ready "${ISE_PRIVATE_IP}" "${CML_PUBLIC_IP}" "${REPO_ROOT}/keys/cml-lab"
  apply_ise_policy "${ISE_PRIVATE_IP}" "${CML_PUBLIC_IP}" "${REPO_ROOT}/keys/cml-lab"
  pass "ISE ready. Reach it through the CML host jump (ADR 0003), never directly."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
