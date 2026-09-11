#!/usr/bin/env bash
# Launch cml-mcp for Claude Code with credentials from config/mcp-env/cml.env.
# Referenced by .mcp.json. Claude Code cannot source a file itself, hence
# this wrapper. The env file is written by scripts/20-up.sh.
#
# The pyats extra is what lets send_cli_command reach a running node. It
# logs in to devices as PYATS_USERNAME/PYATS_PASSWORD, cisco/cisco by
# default, so when config/mcp-env/labs.env exists the lab password from
# it is handed over for the admin user every topology under labs/ creates
# (ADR 0006). Override either variable in the environment if a lab differs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${CML_MCP_ENV:-${REPO_ROOT}/config/mcp-env/cml.env}"
LAB_ENV_FILE="${CML_LAB_ENV:-${REPO_ROOT}/config/mcp-env/labs.env}"

main() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "mcp-cml: ${ENV_FILE} missing. Run scripts/20-up.sh first." >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  if [[ -f "${LAB_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${LAB_ENV_FILE}"
    PYATS_USERNAME="${PYATS_USERNAME:-admin}"
    PYATS_PASSWORD="${PYATS_PASSWORD:-${LAB_PASSWORD:-}}"
    # FTDv nodes carry their own admin password; see config/labs.env.example.
    FTD_ADMIN_PASSWORD="${FTD_ADMIN_PASSWORD:-}"
  fi
  set +a
  exec uvx "cml-mcp[pyats]" "$@"
}

main "$@"
