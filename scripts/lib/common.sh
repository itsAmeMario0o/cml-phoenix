#!/usr/bin/env bash
# Shared helpers for every script in scripts/. Source it, do not run it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Provides: REPO_ROOT, pass/warn/miss counters, summary_and_exit, die,
# require_cmd, require_env, tf_out, cml_ip, cml_ssh, confirm.
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

# cml_ssh CMD...: run a command on the CML host as sysadmin. Port 1122 is the
# system shell on a CML host; 22 is the console server (ADR 0003 notes).
cml_ssh() {
  local key="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
  ssh -p 1122 -i "${key}" \
    -o StrictHostKeyChecking=accept-new \
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
