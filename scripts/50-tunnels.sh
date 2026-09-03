#!/usr/bin/env bash
# SSH port forwards through the CML host, detached with pid files.
#
#   scripts/50-tunnels.sh up [--dry-run] | down | status
#
# Forwards come from config/tunnels.conf: "name local_port remote_host
# remote_port". Each runs as its own ssh -N -L on port 1122. State lives in
# .cml-tunnels/ inside the repo (pid and log per tunnel). "up" is idempotent:
# a tunnel that already listens is left alone. Refuses "up" when the host
# does not answer on 1122.
#
# Overrides: TUNNELS_CONF, STATE_DIR.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

TUNNELS_CONF="${TUNNELS_CONF:-${REPO_ROOT}/config/tunnels.conf}"
STATE_DIR="${STATE_DIR:-${REPO_ROOT}/.cml-tunnels}"
KEY_FILE="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
DRY_RUN=0

port_listening() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

require_conf() {
  [[ -f "${TUNNELS_CONF}" ]] || die "${TUNNELS_CONF} missing. Copy config/tunnels.conf.example."
}

each_tunnel() {
  # Calls "$1 name local_port remote_host remote_port" per config line.
  local callback="$1" name lport rhost rport failed=0
  while read -r name lport rhost rport || [[ -n "${name}" ]]; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    [[ -n "${rport}" ]] || die "${TUNNELS_CONF}: line '${name} ${lport} ${rhost} ${rport}' needs four fields"
    "${callback}" "${name}" "${lport}" "${rhost}" "${rport}" || failed=1
  done < "${TUNNELS_CONF}"
  return "${failed}"
}

host_reachable() {
  local ip="$1"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  nc -z -w 5 "${ip}" 1122 >/dev/null 2>&1
}

start_one() {
  local name="$1" lport="$2" rhost="$3" rport="$4" ip="${CML_HOST_IP}" tries
  if port_listening "${lport}"; then
    echo "${name}: already listening on ${lport}"
    return 0
  fi
  mkdir -p "${STATE_DIR}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ssh -p 1122 -i ${KEY_FILE} -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -N -L ${lport}:${rhost}:${rport} sysadmin@${ip}"
    return 0
  fi
  nohup ssh -p 1122 -i "${KEY_FILE}" -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
    -N -L "${lport}:${rhost}:${rport}" "sysadmin@${ip}" >> "${STATE_DIR}/${name}.log" 2>&1 &
  echo "$!" > "${STATE_DIR}/${name}.pid"
  # shellcheck disable=SC2034
  for tries in 1 2 3 4 5 6 7 8 9 10; do
    if port_listening "${lport}"; then
      echo "${name}: up on localhost:${lport} -> ${rhost}:${rport}"
      return 0
    fi
    sleep 1
  done
  echo "${name}: did not come up, see ${STATE_DIR}/${name}.log" >&2
  return 1
}

stop_one() {
  local name="$1" lport="$2" pid_file="${STATE_DIR}/$1.pid" holder
  if [[ -f "${pid_file}" ]]; then
    kill "$(cat "${pid_file}")" 2>/dev/null || true
    rm -f "${pid_file}"
  fi
  holder="$(lsof -nP -tiTCP:"${lport}" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "${holder}" ]]; then
    # shellcheck disable=SC2086 # holder may be several pids, one per line; want them as separate args
    kill ${holder} 2>/dev/null || true
  fi
  echo "${name}: stopped"
}

status_one() {
  local name="$1" lport="$2" rhost="$3" rport="$4"
  if port_listening "${lport}"; then
    echo "${name}: up (localhost:${lport} -> ${rhost}:${rport})"
  else
    echo "${name}: DOWN (localhost:${lport})"
  fi
}

main() {
  local cmd="${1:-}"
  if [[ "${2:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
  require_conf
  require_cmd ssh lsof nc
  case "${cmd}" in
    up)
      CML_HOST_IP="$(cml_ip)"
      host_reachable "${CML_HOST_IP}" || die "CML host ${CML_HOST_IP} not reachable on 1122"
      each_tunnel start_one || die "one or more tunnels did not come up, see ${STATE_DIR}/*.log"
      ;;
    down) each_tunnel stop_one ;;
    status) each_tunnel status_one ;;
    *) echo "usage: $0 up [--dry-run]|down|status" >&2; exit 1 ;;
  esac
}

main "$@"
