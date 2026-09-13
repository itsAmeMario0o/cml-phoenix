#!/usr/bin/env bash
# Bring up the disposable ISE VM from Cisco's Azure solution template
# (ADR 0008), by az CLI, not Terraform. The operator chose az CLI over a
# terraform/ise root after a bad ISE-on-Terraform experience; see the
# TrustSec Phase 1 plan. Run this after scripts/20-up.sh: it joins the
# persistent root's vnet/subnet by name and needs the CML host as an SSH
# jump for the readiness check and policy apply, since ADR 0003 routes
# operator administration of every lab node, ISE included, through that
# jump (ADR 0008 keeps that even though ISE gets its own public IP).
#
#   scripts/25-ise-up.sh [--dry-run]
#
# Order:
#   1. Read config/mcp-env/ise.env: Marketplace coordinates, size,
#      private IP, hostname, admin password, admin source CIDR
#      (ADR 0004, gitignored).
#   2. Resolve resource_group_name, location, lab_summary_cidr,
#      public_ip_address from the persistent root's outputs.
#   3. Create the ISE NSG: RADIUS 1812/1813 UDP from the lab summary,
#      admin 443 TCP and SSH 22 TCP from ISE_ADMIN_SOURCE_CIDR only.
#      Never 0.0.0.0/0.
#   4. Render the deployment parameters file (scripts/lib/ise_params.py)
#      to a 0600 mktemp path under config/mcp-env/, deleted on exit. The
#      admin password never appears on the az command line.
#   5. az deployment group create against config/ise/template.json,
#      Cisco's solution template (ADR 0008). It builds the public IP,
#      NIC, and VM, tagged project/role by the template itself.
#   6. Tag the VM's OS disk to match (the template does not tag it).
#   7. Poll https://<ise_private_ip>/admin/API/mnt/Version through the
#      CML host jump (port 1122) until it answers. Typically 30-45 min.
#   8. Apply the minimal TrustSec Phase 1 policy (scripts/lib/ise_config.py)
#      through a local forward to the same jump.
#
# The deploy prompts unless ASSUME_YES=1. --dry-run prints the plan and
# touches no Azure resource.
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
PARAMS_FILE=""
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
  : "${ISE_IMAGE_SKU:?missing in ${ISE_ENV_FILE}}"
  : "${ISE_VM_SIZE:?missing in ${ISE_ENV_FILE}}"
  : "${ISE_PRIVATE_IP:?missing in ${ISE_ENV_FILE}}"
  : "${ISE_HOSTNAME:?missing in ${ISE_ENV_FILE}, see config/ise.env.example}"
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

# ensure_nsg: RADIUS from the lab summary (switches reaching ISE, ADR
# 0003); admin and SSH from ISE_ADMIN_SOURCE_CIDR only, the CML host
# address per ADR 0008. Never 0.0.0.0/0.
ensure_nsg() {
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
}

# render_params: scripts/lib/ise_params.py (Task 2) reads ISE_ADMIN_PASSWORD
# and the rest of the ISE_* keys from this shell's environment, already
# exported by load_ise_env's `set -a` source, so the password never
# reaches this command line (ADR 0004, senior-secops). PARAMS_FILE is a
# mktemp path under config/mcp-env/, the repo's one gitignored spot for
# rendered secrets, and it is removed on exit by the trap in main(): it
# holds the password in plain JSON, so it must not outlive this run.
render_params() {
  PARAMS_FILE="$(mktemp "${REPO_ROOT}/config/mcp-env/ise-params.XXXXXX")"
  run python3 "${REPO_ROOT}/scripts/lib/ise_params.py" "${PARAMS_FILE}" --nsg "${NSG_NAME}"
}

# deploy: Cisco's solution template (ADR 0008) builds the public IP, NIC,
# and VM in one deployment. --parameters @file, never inline values, so
# nothing in PARAMS_FILE reaches the command line either.
deploy() {
  run az deployment group create -g "${RESOURCE_GROUP}" -n "ise-$(date +%s)" \
    --template-file "${REPO_ROOT}/config/ise/template.json" \
    --parameters "@${PARAMS_FILE}"
}

# tag_osdisk: the template tags the public IP, NIC, and VM (ADR 0008) but
# not the OS disk it creates alongside them. Tag it too so every ISE
# resource, the disk included, is disposable by role=ise.
tag_osdisk() {
  run az disk update -g "${RESOURCE_GROUP}" -n "${ISE_HOSTNAME}osdisk" \
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
# port instead of ISE's private address (ADR 0003); the forward is torn
# down on the way out even if ise_config.py fails, via the EXIT trap.
apply_ise_policy() {
  local ise_ip="$1" jump="$2" key="$3"
  open_ise_forward "${ise_ip}" "${jump}" "${key}"
  ISE_API_BASE="https://127.0.0.1:${ISE_FORWARD_LOCAL_PORT}" \
    run python3 "${REPO_ROOT}/scripts/lib/ise_config.py"
  close_ise_forward
}

# cleanup_on_exit: the one EXIT trap for the whole script, set once in
# main() rather than stacked per function (bash 3.2 traps replace, not
# stack, so a second `trap ... EXIT` would silently drop the first).
# Closes any still-open ISE forward and removes PARAMS_FILE, which holds
# the ISE admin password in plain JSON (ADR 0004). Both halves are
# already guarded no-ops when there is nothing to clean up, so this is
# safe to run on every exit path, success or failure, at any stage.
cleanup_on_exit() {
  close_ise_forward
  # `if`, not `[[ ... ]] && rm`: the trap's own exit status becomes the
  # script's final exit code in bash, and a false `&&` short-circuit
  # would silently turn an intended exit 0 into 1 whenever PARAMS_FILE is
  # still empty (an early failure, before render_params runs).
  if [[ -n "${PARAMS_FILE}" ]]; then
    rm -f "${PARAMS_FILE}"
  fi
}

main() {
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
  require_env ARM_SUBSCRIPTION_ID
  require_cmd az terraform jq python3 ssh
  load_ise_env
  resolve_network
  # Set once, before PARAMS_FILE exists: cleanup_on_exit no-ops until
  # render_params gives it something to remove, so an early failure is
  # still safe to trap.
  trap cleanup_on_exit EXIT
  confirm "Deploy ISE ${ISE_IMAGE_SKU} (${ISE_VM_SIZE}) into ${RESOURCE_GROUP} at ${ISE_PRIVATE_IP}?" || die "declined"
  ensure_nsg
  render_params
  deploy
  tag_osdisk
  wait_for_ise_ready "${ISE_PRIVATE_IP}" "${CML_PUBLIC_IP}" "${REPO_ROOT}/keys/cml-lab"
  apply_ise_policy "${ISE_PRIVATE_IP}" "${CML_PUBLIC_IP}" "${REPO_ROOT}/keys/cml-lab"
  pass "ISE ready. Reach it through the CML host jump (ADR 0003), never directly."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
