#!/usr/bin/env bash
# Shared helpers for every script in scripts/. Source it, do not run it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Provides: REPO_ROOT, pass/warn/miss counters, summary_and_exit, die,
# require_cmd, require_env, tf_out, cml_ip, cml_ssh, cml_remote, cml_scp,
# cml_api_ready, port_listening, confirm, load_cml_env, run,
# out_or_placeholder, parse_dry_run_only, azcopy_env_init, render_config.
#
# Must stay bash 3.2 compatible: this runs on macOS.

# Resolve the repo root from this file, two levels up, regardless of cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

ok=0
warns=0
fail=0

if [[ -t 1 ]]; then
  green='\033[32m'; yellow='\033[33m'; red='\033[31m'; reset='\033[0m'
else
  green=''; yellow=''; red=''; reset=''
fi

pass() { printf "${green}[OK]${reset}    %s\n" "$1"; ok=$((ok + 1)); }
warn() { printf "${yellow}[WARN]${reset}  %s\n" "$1"; warns=$((warns + 1)); }
miss() { printf "${red}[FAIL]${reset}  %s\n" "$1"; fail=$((fail + 1)); }

summary_and_exit() {
  printf "\nsummary: %d OK, %d WARN, %d FAIL\n" "${ok}" "${warns}" "${fail}"
  if [[ "${fail}" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

die() {
  printf "${red}[FAIL]${reset}  %s\n" "$1" >&2
  exit 1
}

require_cmd() {
  local tool
  for tool in "$@"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      die "${tool} is not installed. See docs/PREREQUISITES.md section 4."
    fi
  done
}

require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      die "${name} is not set. See docs/PREREQUISITES.md section 2.2."
    fi
  done
}

# tf_out ROOT NAME: value of output NAME from terraform/ROOT. Uses -json
# because "output -raw" prints a warning to stdout and exits 0 when the
# state has no outputs yet. Returns 1 when the output is absent or empty,
# so callers can fall back or die.
tf_out() {
  local root="$1" name="$2" value
  value="$(terraform -chdir="${REPO_ROOT}/terraform/${root}" output -json 2>/dev/null |
    jq -r --arg n "${name}" 'if type == "object" and has($n) then .[$n].value else empty end')" || return 1
  [[ -n "${value}" ]] || return 1
  echo "${value}"
}

cml_ip() {
  tf_out persistent public_ip_address
}

# Every rebuild gives the controller new host keys. They live in a repo-local
# file, never ~/.ssh/known_hosts, and 20-up.sh forgets the old entry before
# each build. accept-new then trusts the fresh key once and pins it.
CML_KNOWN_HOSTS="${CML_KNOWN_HOSTS:-${REPO_ROOT}/keys/known_hosts}"
CML_SSH_OPTS=(-o "UserKnownHostsFile=${CML_KNOWN_HOSTS}" -o StrictHostKeyChecking=accept-new)

# cml_ssh CMD...: run a command on the CML host as sysadmin. Port 1122 is the
# system shell on a CML host; 22 is the console server (ADR 0003 notes).
cml_ssh() {
  local key="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
  ssh -p 1122 -i "${key}" \
    "${CML_SSH_OPTS[@]}" \
    -o ConnectTimeout=10 \
    "sysadmin@$(cml_ip)" "$@"
}

# confirm QUESTION: prompt for y/yes. ASSUME_YES=1 skips the prompt so
# scripts can run unattended when the human has already decided.
confirm() {
  local question="$1" answer
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  printf "%s [y/N] " "${question}"
  read -r answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# run CMD...: execute CMD, or under DRY_RUN=1 print "+ CMD..." instead of
# running it. Every mutating script sets its own DRY_RUN; this wrapper is
# syntactic (mirrors set -x's "+" convention) so a dry run exercises the
# same argument construction as a real run, never a separate mocked path.
run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

# out_or_placeholder NAME: a persistent-root output, or the literal
# "<NAME>" under DRY_RUN=1 when the root may not be applied yet, or a
# hard failure otherwise. Shared by every script that resolves a
# persistent-root value before rendering config or naming a resource.
out_or_placeholder() {
  local value
  if value="$(tf_out persistent "$1" 2>/dev/null)" && [[ -n "${value}" ]]; then
    echo "${value}"
  elif [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "<$1>"
  else
    die "persistent output $1 unavailable"
  fi
}

# render_config: config/cml.yml from the persistent outputs, cml.tfvars
# and refplat.txt. 20-up.sh renders it before the build and 40-down.sh
# again before the destroy: Terraform re-reads the rendered file for a
# destroy too, and a copy left from the build named a customize script
# the fork had since renamed (LESSONS-LEARNED, 2026-09-17). Every output
# is resolved into a variable before the command line is built. A die
# inside "$(...)" in argument position only empties that argument, since
# bash runs a command substitution with errexit off; a plain assignment
# is what set -e stops on (architecture review, 2026-09-17).
CML_TFVARS="${CML_TFVARS:-${REPO_ROOT}/config/cml.tfvars}"
REFPLAT_FILE="${REFPLAT_FILE:-${REPO_ROOT}/config/refplat.txt}"
CML_YML="${REPO_ROOT}/config/cml.yml"
render_config() {
  local app_pw sys_pw rg sa container vnet subnet ip pip disk apps_cidr lab_cidr key_name
  app_pw="$(out_or_placeholder app_admin_password)"
  sys_pw="$(out_or_placeholder sys_admin_password)"
  rg="$(out_or_placeholder resource_group_name)"
  sa="$(out_or_placeholder storage_account_name)"
  container="$(out_or_placeholder cml_container_name)"
  vnet="$(out_or_placeholder vnet_name)"
  subnet="$(out_or_placeholder cml_subnet_name)"
  ip="$(out_or_placeholder cml_private_ip)"
  pip="$(out_or_placeholder public_ip_name)"
  disk="$(out_or_placeholder data_disk_id)"
  apps_cidr="$(out_or_placeholder apps_subnet_cidr)"
  lab_cidr="$(out_or_placeholder lab_summary_cidr)"
  key_name="$(out_or_placeholder ssh_key_name)"
  # Passwords go through the environment, not --set, so they never appear
  # in a process listing.
  APP_PASSWORD="${app_pw}" SYS_PASSWORD="${sys_pw}" run python3 "${REPO_ROOT}/scripts/lib/render_cml_config.py" \
    --template "${REPO_ROOT}/config/cml.yml.tftpl" \
    --tfvars "${CML_TFVARS}" --refplat "${REFPLAT_FILE}" --out "${CML_YML}" \
    --set "RESOURCE_GROUP=${rg}" \
    --set "STORAGE_ACCOUNT=${sa}" \
    --set "CONTAINER_NAME=${container}" \
    --set "VNET_NAME=${vnet}" \
    --set "SUBNET_NAME=${subnet}" \
    --set "PRIVATE_IP=${ip}" \
    --set "PUBLIC_IP_NAME=${pip}" \
    --set "DATA_DISK_ID=${disk}" \
    --set "OS_DISK_TYPE=${OS_DISK_TYPE:-Premium_LRS}" \
    --set "APPS_SUBNET_CIDR=${apps_cidr}" \
    --set "LAB_SUMMARY_CIDR=${lab_cidr}" \
    --set "SSH_KEY_NAME=${key_name}"
}

# parse_dry_run_only "$@": for a script whose only accepted argument is
# --dry-run. Dies on anything else rather than silently discarding it, so
# a typo like --dryrun cannot fall through and run for real against
# Azure. Echoes 0 or 1; callers do DRY_RUN="$(parse_dry_run_only "$@")".
parse_dry_run_only() {
  local dry=0 arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) dry=1 ;;
      *) die "usage: $(basename "$0") [--dry-run]" ;;
    esac
  done
  echo "${dry}"
}

# cml_remote SUBCOMMAND [ARGS...]: run one of cml-remote.sh's subcommands
# (list-labs, export-labs, stop-labs, license-status, deregister) on the
# CML host over the same jump cml_ssh uses. cml-remote.sh never runs on
# the Mac; it is piped over SSH and executed on the host itself.
cml_remote() {
  cml_ssh "bash -s -- $*" < "${REPO_ROOT}/scripts/lib/cml-remote.sh"
}

# cml_scp ARGS...: scp through the CML host's system shell port (1122,
# same jump cml_ssh uses), forwarding every argument (source, dest, and
# any scp flags) straight through.
cml_scp() {
  local key="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
  scp -P 1122 -i "${key}" "${CML_SSH_OPTS[@]}" "$@"
}

# cml_api_ready: true if the CML controller's own API reports ready. Asked
# on the host itself, over the pinned SSH jump, so the self-signed leg that
# curl -k accepts is the host's own loopback and nothing reaches the public
# address unverified (ADR 0012).
cml_api_ready() {
  [[ "$(cml_ssh "curl -sk -m 10 https://127.0.0.1/api/v0/system_information" 2>/dev/null | jq -r .ready 2>/dev/null)" == "true" ]]
}

# port_listening PORT: something on this Mac listens on TCP PORT. Shared by
# 50-tunnels.sh and load_cml_env so both judge "forward up" the same way.
port_listening() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

# azcopy_env_init: point azcopy's logs and job plans at .azcopy/ inside
# the repo, never a dotfile under $HOME (CLAUDE.md: never create files
# outside this repo), and use the az CLI's own login session instead of
# a separate azcopy login.
azcopy_env_init() {
  export AZCOPY_AUTO_LOGIN_TYPE=AZCLI
  export AZCOPY_LOG_LOCATION="${REPO_ROOT}/.azcopy" AZCOPY_JOB_PLAN_LOCATION="${REPO_ROOT}/.azcopy"
  mkdir -p "${AZCOPY_LOG_LOCATION}"
}

# load_cml_env [--require-labs]: source config/mcp-env/cml.env (mandatory)
# and config/mcp-env/labs.env (optional unless --require-labs), exporting
# every key so a caller's python3 or curl subprocess inherits them
# without either ever crossing a command line (ADR 0004). A caller may
# override CML_ENV_FILE/LAB_ENV_FILE before calling. Validates only the
# keys every caller needs (CML_API_BASE, CML_USERNAME, CML_PASSWORD); a
# script-specific key like LAB_PASSWORD is the caller's own check, made
# right after calling this.
#
# CML_API_BASE is where every script and the MCP server send the admin
# password: a loopback URL that the "cml" forward from 50-tunnels.sh
# carries to the controller's own 443 inside the pinned SSH session
# (ADR 0012). CML_URL, the public address, stays in the file for humans
# and the browser and is never dialled from here. The forward has to be
# up before this returns; there is no fallback to the public address.
load_cml_env() {
  local require_labs=0
  case "${1:-}" in --require-labs) require_labs=1 ;; esac
  CML_ENV_FILE="${CML_ENV_FILE:-${REPO_ROOT}/config/mcp-env/cml.env}"
  LAB_ENV_FILE="${LAB_ENV_FILE:-${REPO_ROOT}/config/mcp-env/labs.env}"
  [[ -f "${CML_ENV_FILE}" ]] || die "${CML_ENV_FILE} missing. Run scripts/20-up.sh first."
  set -a
  # shellcheck disable=SC1090
  source "${CML_ENV_FILE}"
  if [[ -f "${LAB_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${LAB_ENV_FILE}"
  elif [[ "${require_labs}" == "1" ]]; then
    set +a
    die "${LAB_ENV_FILE} missing. Start from config/labs.env.example"
  fi
  set +a
  : "${CML_USERNAME:?CML_USERNAME missing in ${CML_ENV_FILE}}"
  : "${CML_PASSWORD:?CML_PASSWORD missing in ${CML_ENV_FILE}}"
  require_cml_forward
}

# require_cml_forward: CML_API_BASE must be a loopback URL and its port
# must be listening, otherwise die naming the remedy. The loopback rule is
# the whole point of ADR 0012: a public address here would send the admin
# password across the internet with certificate checks off again.
require_cml_forward() {
  local port
  [[ -n "${CML_API_BASE:-}" ]] || die "CML_API_BASE missing in ${CML_ENV_FILE}. Rerun scripts/20-up.sh, or add CML_API_BASE=https://127.0.0.1:${CML_FORWARD_LOCAL_PORT} (ADR 0012)"
  [[ "${CML_API_BASE}" =~ ^https?://127\.0\.0\.1:[0-9]+$ ]] ||
    die "CML_API_BASE must be a loopback URL like https://127.0.0.1:${CML_FORWARD_LOCAL_PORT}, got ${CML_API_BASE} (ADR 0012)"
  port="${CML_API_BASE##*:}"
  port_listening "${port}" || die "CML API forward not up on 127.0.0.1:${port}. Run: scripts/50-tunnels.sh up"
}

# The local port the "cml" forward listens on. 20-up.sh writes it into
# cml.env and config/tunnels.conf.example carries the matching line; the
# two must agree, and require_cml_forward is what notices when they do not.
CML_FORWARD_LOCAL_PORT="${CML_FORWARD_LOCAL_PORT:-9443}"
