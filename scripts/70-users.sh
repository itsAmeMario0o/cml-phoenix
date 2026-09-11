#!/usr/bin/env bash
# Create CML users from a CSV and grant every lab to every non-admin user.
#
#   scripts/70-users.sh [--dry-run] [--csv FILE]
#   scripts/70-users.sh class NAME COUNT DOMAIN     # print rows for a class
#
# Reads config/mcp-env/users.csv by default (columns: email, fullname,
# role) and the controller login from cml.env. The email is the CML
# username. Every non-admin user joins one managed group (LAB_GROUP,
# default lab-users) that holds LAB_PERMISSION (default lab_exec) on
# every lab on the controller, so rerunning after importing a lab grants
# it to everyone. Users that already exist are left alone. Generated
# passwords go to config/mcp-env/users-credentials.csv, mode 0600, and
# nowhere else. Each email still needs its Access policy entry; the
# script prints the list. ADR 0007, docs/ACCESS.md "Adding a person".
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CML_ENV_FILE="${CML_ENV_FILE:-${REPO_ROOT}/config/mcp-env/cml.env}"
USERS_CSV="${USERS_CSV:-${REPO_ROOT}/config/mcp-env/users.csv}"
USERS_CREDENTIALS="${USERS_CREDENTIALS:-${REPO_ROOT}/config/mcp-env/users-credentials.csv}"
USERS_PY="${REPO_ROOT}/scripts/lib/users.py"

usage() {
  echo "usage: scripts/70-users.sh [--dry-run] [--csv FILE]" >&2
  echo "       scripts/70-users.sh class NAME COUNT DOMAIN" >&2
  exit 2
}

load_env() {
  [[ -f "${CML_ENV_FILE}" ]] || die "${CML_ENV_FILE} missing. Run scripts/20-up.sh first."
  set -a
  # shellcheck disable=SC1090
  source "${CML_ENV_FILE}"
  set +a
}

main() {
  local dry_run=() csv="${USERS_CSV}"
  if [[ "${1:-}" == "class" ]]; then
    shift
    [[ $# -eq 3 ]] || usage
    exec python3 "${USERS_PY}" class "$@"
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run=(--dry-run) ;;
      --csv) [[ -n "${2:-}" ]] || usage; csv="$2"; shift ;;
      *) usage ;;
    esac
    shift
  done
  require_cmd python3
  [[ -f "${csv}" ]] || die "${csv} missing. Start from config/users.csv.example, or: scripts/70-users.sh class NAME COUNT"
  load_env
  # Bash 3.2 calls an empty array unbound under set -u, hence the guard.
  python3 "${USERS_PY}" apply --csv "${csv}" --credentials "${USERS_CREDENTIALS}" ${dry_run[@]+"${dry_run[@]}"}
}

main "$@"
