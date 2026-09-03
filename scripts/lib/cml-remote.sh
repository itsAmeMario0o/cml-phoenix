#!/usr/bin/env bash
# Runs ON THE CML HOST, piped over SSH from the Mac:
#   cml_ssh "bash -s -- list-labs" < scripts/lib/cml-remote.sh
#
# Talks to the controller's local API with the admin credentials that
# cloud-cml leaves in /provision/vars.sh (group-readable by sysadmin).
#
# Subcommands and output contract (parsed by 30-export, 40-down, 90-smoke):
#   list-labs          id<TAB>title<TAB>state per line
#   export-labs DIR    writes <slug>-<id>.yaml, prints "exported N labs to DIR"
#   stop-labs          stops labs not STOPPED, prints "stopped N labs"
#   license-status     prints registration.status
#   deregister         deregisters, prints new status, exit 1 if still REGISTERED
#
# Overrides for tests: CML_API, VARS_FILE. Needs curl and jq, both present on
# a cloud-cml host. Stays bash 3.2 compatible so tests run on the Mac.
set -euo pipefail

CML_API="${CML_API:-http://ip6-localhost:8001/api/v0}"
VARS_FILE="${VARS_FILE:-/provision/vars.sh}"
TOKEN=""

load_credentials() {
  if [[ ! -r "${VARS_FILE}" ]]; then
    echo "cml-remote: cannot read ${VARS_FILE}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${VARS_FILE}"
  : "${CFG_APP_USER:?missing in ${VARS_FILE}}" "${CFG_APP_PASS:?missing in ${VARS_FILE}}"
}

authenticate() {
  TOKEN="$(printf '{"username":"%s","password":"%s"}' "${CFG_APP_USER}" "${CFG_APP_PASS}" |
    curl -sf -H "Content-Type: application/json" -d @- "${CML_API}/authenticate" | jq -r .)" || TOKEN=""
  if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
    echo "cml-remote: authentication failed" >&2
    exit 1
  fi
}

api() {
  local method="$1" path="$2"
  curl -sf -X "${method}" -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/json" "${CML_API}${path}"
}

# api_raw METHOD PATH: like api(), but sends only the Authorization header.
# The lab download endpoint returns YAML, not JSON, and some CML versions
# answer an Accept: application/json request with an error instead of the
# topology.
api_raw() {
  local method="$1" path="$2"
  curl -sf -X "${method}" -H "Authorization: Bearer ${TOKEN}" "${CML_API}${path}"
}

lab_ids() {
  api GET /labs | jq -r '.[]'
}

lab_row() {
  local id="$1"
  api GET "/labs/${id}" | jq -r '[.id, .lab_title, .state] | @tsv'
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

cmd_list_labs() {
  local id
  for id in $(lab_ids); do
    lab_row "${id}"
  done
}

cmd_export_labs() {
  local dir="$1" id title file count=0
  mkdir -p "${dir}"
  for id in $(lab_ids); do
    title="$(api GET "/labs/${id}" | jq -r .lab_title)"
    file="${dir}/$(slugify "${title}")-${id}.yaml"
    api_raw GET "/labs/${id}/download" > "${file}"
    if [[ "$(head -1 "${file}")" != lab:* ]]; then
      rm -f "${file}"
      echo "export of ${id} did not look like a topology" >&2
      exit 1
    fi
    count=$((count + 1))
  done
  echo "exported ${count} labs to ${dir}"
}

cmd_stop_labs() {
  local id state count=0
  for id in $(lab_ids); do
    state="$(api GET "/labs/${id}" | jq -r .state)"
    if [[ "${state}" != "STOPPED" ]]; then
      api PUT "/labs/${id}/stop" > /dev/null
      count=$((count + 1))
    fi
  done
  echo "stopped ${count} labs"
}

cmd_license_status() {
  api GET /licensing | jq -r '.registration.status'
}

cmd_deregister() {
  local status
  api DELETE /licensing/deregistration > /dev/null || true
  status="$(cmd_license_status)"
  echo "${status}"
  [[ "${status}" != "REGISTERED" ]]
}

main() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    list-labs | export-labs | stop-labs | license-status | deregister) ;;
    *) echo "usage: cml-remote.sh list-labs|export-labs DIR|stop-labs|license-status|deregister" >&2; exit 2 ;;
  esac
  load_credentials
  authenticate
  case "${sub}" in
    list-labs) cmd_list_labs ;;
    export-labs) cmd_export_labs "${1:?export-labs needs a directory}" ;;
    stop-labs) cmd_stop_labs ;;
    license-status) cmd_license_status ;;
    deregister) cmd_deregister ;;
  esac
}

main "$@"
