#!/usr/bin/env bash
# Launch cml-mcp for Claude Code with credentials from config/mcp-env/cml.env.
# Referenced by .mcp.json. Claude Code cannot source a file itself, hence
# this wrapper. The env file is written by scripts/20-up.sh.
#
# cml-mcp reads CML_URL, so it is handed CML_API_BASE under that name: the
# loopback port of the "cml" forward from scripts/50-tunnels.sh, never the
# public address. The forward must be up first; load_cml_env refuses to
# continue otherwise and says which command to run (ADR 0012).
#
# The pyats extra is what lets send_cli_command reach a running node. It
# logs in to devices as PYATS_USERNAME/PYATS_PASSWORD, cisco/cisco by
# default, so when config/mcp-env/labs.env exists the lab password from
# it is handed over for the admin user every topology under labs/ creates
# (ADR 0006). Override either variable in the environment if a lab differs.
#
# The server runs with the CML admin password in its environment, so the
# version is pinned rather than whatever PyPI serves next; bump
# CML_MCP_VERSION in the environment, or the default here, on purpose.
# 0.31.2 is the version uvx last resolved on this Mac (uv cache, 2026-09-05)
# and the one LESSONS-LEARNED names.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CML_ENV_FILE="${CML_MCP_ENV:-${REPO_ROOT}/config/mcp-env/cml.env}"
LAB_ENV_FILE="${CML_LAB_ENV:-${REPO_ROOT}/config/mcp-env/labs.env}"
CML_MCP_VERSION="${CML_MCP_VERSION:-0.31.2}"

main() {
  load_cml_env
  if [[ -f "${LAB_ENV_FILE}" ]]; then
    export PYATS_USERNAME="${PYATS_USERNAME:-admin}"
    export PYATS_PASSWORD="${PYATS_PASSWORD:-${LAB_PASSWORD:-}}"
    # FTDv nodes carry their own admin password; see config/labs.env.example.
    export FTD_ADMIN_PASSWORD="${FTD_ADMIN_PASSWORD:-}"
  fi
  CML_URL="${CML_API_BASE}" exec uvx "cml-mcp[pyats]==${CML_MCP_VERSION}" "$@"
}

main "$@"
