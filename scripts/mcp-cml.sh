#!/usr/bin/env bash
# Launch cml-mcp for Claude Code with credentials from config/mcp-env/cml.env.
# Referenced by .mcp.json. Claude Code cannot source a file itself, hence
# this wrapper. The env file is written by scripts/20-up.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${CML_MCP_ENV:-${REPO_ROOT}/config/mcp-env/cml.env}"

main() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "mcp-cml: ${ENV_FILE} missing. Run scripts/20-up.sh first." >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  exec uvx cml-mcp "$@"
}

main "$@"
