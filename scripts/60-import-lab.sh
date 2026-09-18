#!/usr/bin/env bash
# Render a tracked topology from labs/ and import it into the running CML.
#
#   scripts/60-import-lab.sh labs/cilium-evpn-blank.yaml [--dry-run]
#
# 1. Read CML_API_BASE and credentials from config/mcp-env/cml.env (written
#    by 20-up.sh) and LAB_PASSWORD from config/mcp-env/labs.env (yours).
#    CML_API_BASE is the "cml" SSH forward from 50-tunnels.sh, so curl -k
#    below only ever skips verification on 127.0.0.1 (ADR 0012)
# 2. Render placeholders into exports/.rendered/<name>.yaml, mode 0600
# 3. Authenticate, POST the YAML to /api/v0/import, print the new lab id
#
# The lab is created stopped. Start it from the UI or through cml-mcp.
# The rendered copy stays in exports/ (gitignored) in case you want to
# import it through the UI instead. ADR 0006 for why labs render this way.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PUBKEY_FILE="${PUBKEY_FILE:-${REPO_ROOT}/keys/cml-lab.pub}"
RENDER="${REPO_ROOT}/scripts/lib/render_lab.py"
RENDERED_DIR="${REPO_ROOT}/exports/.rendered"
DRY_RUN=0
TOKEN=""

usage() {
  echo "usage: scripts/60-import-lab.sh labs/<topology>.yaml [--dry-run]" >&2
  exit 2
}

curl_opts() {
  if [[ "${CML_VERIFY_SSL:-true}" == "false" ]]; then
    echo "-k"
  fi
}

render_topology() {
  local src="$1" out="$2"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ python3 ${RENDER} ${src} --pubkey ${PUBKEY_FILE} --out ${out}"
    return 0
  fi
  mkdir -p "${RENDERED_DIR}"
  chmod 700 "${RENDERED_DIR}"
  python3 "${RENDER}" "${src}" --pubkey "${PUBKEY_FILE}" --out "${out}"
}

authenticate() {
  local opts
  opts="$(curl_opts)"
  # shellcheck disable=SC2086
  TOKEN="$(printf '{"username":"%s","password":"%s"}' "${CML_USERNAME}" "${CML_PASSWORD}" |
    curl -sf ${opts} -m 20 -H "Content-Type: application/json" -d @- "${CML_API_BASE}/api/v0/authenticate" | jq -r .)" || TOKEN=""
  [[ -n "${TOKEN}" && "${TOKEN}" != "null" ]] || die "authentication to ${CML_API_BASE} failed"
}

# The controller reads the body as YAML with no content type, the way
# virl2_client sends it. An empty -H drops curl's form default.
import_topology() {
  local file="$1" title="$2" opts encoded
  encoded="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${title}")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ curl -X POST ${CML_API_BASE}/api/v0/import?title=${encoded} --data-binary @${file}"
    return 0
  fi
  opts="$(curl_opts)"
  # shellcheck disable=SC2086
  curl -sf ${opts} -m 60 -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type:" \
    --data-binary "@${file}" "${CML_API_BASE}/api/v0/import?title=${encoded}" | jq -r '.id'
}

main() {
  local src="" title out lab_id
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      -*) usage ;;
      *) [[ -z "${src}" ]] || usage; src="$1" ;;
    esac
    shift
  done
  [[ -n "${src}" && -f "${src}" ]] || usage
  require_cmd python3 curl jq
  load_cml_env --require-labs
  : "${LAB_PASSWORD:?LAB_PASSWORD missing in ${LAB_ENV_FILE}}"
  title="$(python3 "${RENDER}" "${src}" --pubkey "${PUBKEY_FILE}" --print-title)"
  [[ -n "${title}" ]] || die "${src} has no lab title"
  out="${RENDERED_DIR}/$(basename "${src}")"
  render_topology "${src}" "${out}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ authenticate ${CML_USERNAME} at ${CML_API_BASE}"
    import_topology "${out}" "${title}"
    pass "dry run: would import '${title}'"
    summary_and_exit
  fi
  authenticate
  lab_id="$(import_topology "${out}" "${title}")" || die "import of '${title}' failed: POST ${CML_API_BASE}/api/v0/import did not answer 2xx"
  [[ -n "${lab_id}" && "${lab_id}" != "null" ]] || die "import of '${title}' returned no lab id"
  pass "imported '${title}' as lab ${lab_id}, stopped. Rendered copy: ${out}"
  summary_and_exit
}

main "$@"
