#!/usr/bin/env bash
# scripts/mcp-cml.sh: the cml-mcp version is pinned, CML_MCP_VERSION
# overrides it, and the admin password reaches the server through the
# environment only. uvx is a stub on PATH that prints its arguments.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/mcp-cml.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

FAKE_PASSWORD="Sup3rSecretTestOnly-DoNotLeak"
mkdir -p "${TMP}/bin"
# The $* and ${CML_PASSWORD} below are the fake uvx's own, on purpose.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "uvx $*"\necho "server sees password: ${CML_PASSWORD:-unset}"\n' > "${TMP}/bin/uvx"
chmod +x "${TMP}/bin/uvx"
printf 'CML_URL=https://203.0.113.5\nCML_USERNAME=admin\nCML_PASSWORD=%s\nCML_VERIFY_SSL=false\n' "${FAKE_PASSWORD}" > "${TMP}/cml.env"

launch() { PATH="${TMP}/bin:${PATH}" CML_MCP_ENV="${TMP}/cml.env" CML_LAB_ENV="${TMP}/no-labs.env" bash "${SCRIPT}" 2>&1; }

out="$(launch)"
assert_contains "cml-mcp is pinned by default" "uvx cml-mcp[pyats]==0.31.2" "${out}"
assert_contains "password reaches the server by environment" "server sees password: ${FAKE_PASSWORD}" "${out}"
assert_not_contains "password never on the command line" "${FAKE_PASSWORD}" "$(grep '^uvx ' <<<"${out}")"

out="$(CML_MCP_VERSION=9.9.9 launch)"
assert_contains "CML_MCP_VERSION overrides the pin" "uvx cml-mcp[pyats]==9.9.9" "${out}"

rc=0; out="$(PATH="${TMP}/bin:${PATH}" CML_MCP_ENV="${TMP}/missing.env" bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "missing env file exits 1" "1" "${rc}"
assert_contains "missing env file names the remedy" "Run scripts/20-up.sh first" "${out}"

finish "test_mcp_cml"
