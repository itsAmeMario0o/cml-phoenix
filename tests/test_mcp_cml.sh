#!/usr/bin/env bash
# scripts/mcp-cml.sh: the cml-mcp version is pinned, CML_MCP_VERSION
# overrides it, the admin password reaches the server through the
# environment only, and the server is pointed at the cml SSH forward
# (CML_API_BASE), never the public CML_URL (ADR 0012). uvx is a stub on
# PATH that prints its arguments; a fake API on 18011 stands in for the
# forward, and 18012 is left closed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/mcp-cml.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
PORT=18011
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

python3 "${REPO_ROOT}/tests/fake_cml_api.py" "${PORT}" &
API_PID=$!
trap 'kill "${API_PID}" 2>/dev/null || true; rm -rf "${TMP}"' EXIT
sleep 1

FAKE_PASSWORD="Sup3rSecretTestOnly-DoNotLeak"
PUBLIC="https://203.0.113.5"
mkdir -p "${TMP}/bin"
printf '#!/usr/bin/env bash\necho "uvx $*"\necho "server sees password: ${CML_PASSWORD:-unset}"\necho "server sees url: ${CML_URL:-unset}"\n' > "${TMP}/bin/uvx"
chmod +x "${TMP}/bin/uvx"
printf 'CML_URL=%s\nCML_API_BASE=http://127.0.0.1:%s\nCML_USERNAME=admin\nCML_PASSWORD=%s\nCML_VERIFY_SSL=false\n' "${PUBLIC}" "${PORT}" "${FAKE_PASSWORD}" > "${TMP}/cml.env"

launch() { PATH="${TMP}/bin:${PATH}" CML_MCP_ENV="${TMP}/cml.env" CML_LAB_ENV="${TMP}/no-labs.env" bash "${SCRIPT}" 2>&1; }

out="$(launch)"
assert_contains "cml-mcp is pinned by default" "uvx cml-mcp[pyats]==0.31.2" "${out}"
assert_contains "password reaches the server by environment" "server sees password: ${FAKE_PASSWORD}" "${out}"
assert_not_contains "password never on the command line" "${FAKE_PASSWORD}" "$(grep '^uvx ' <<<"${out}")"
assert_contains "server is pointed at the forward" "server sees url: http://127.0.0.1:${PORT}" "${out}"
assert_not_contains "server never sees the public address" "${PUBLIC}" "${out}"

out="$(CML_MCP_VERSION=9.9.9 launch)"
assert_contains "CML_MCP_VERSION overrides the pin" "uvx cml-mcp[pyats]==9.9.9" "${out}"

rc=0; out="$(PATH="${TMP}/bin:${PATH}" CML_MCP_ENV="${TMP}/missing.env" bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "missing env file exits 1" "1" "${rc}"
assert_contains "missing env file names the remedy" "Run scripts/20-up.sh first" "${out}"

printf 'CML_URL=%s\nCML_API_BASE=http://127.0.0.1:18012\nCML_USERNAME=admin\nCML_PASSWORD=%s\nCML_VERIFY_SSL=false\n' "${PUBLIC}" "${FAKE_PASSWORD}" > "${TMP}/down.env"
rc=0; out="$(PATH="${TMP}/bin:${PATH}" CML_MCP_ENV="${TMP}/down.env" bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "forward down exits 1" "1" "${rc}"
assert_contains "forward down names the remedy" "Run: scripts/50-tunnels.sh up" "${out}"
assert_not_contains "forward down never starts the server" "uvx " "${out}"

finish "test_mcp_cml"
