#!/usr/bin/env bash
# Dry-run test for scripts/20-up.sh: proves the order of operations and that
# nothing is executed. az is stubbed through PATH; terraform is never called
# because every state change goes through run().
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/20-up.sh"
chmod +x "${REPO_ROOT}/tests/stubs/az"
failures=0

# Never destroy an operator's real preflight marker. Save it aside and
# restore it no matter how this test exits.
MARKER="${REPO_ROOT}/.preflight-ok"
if [[ -f "${MARKER}" ]]; then
  mv "${MARKER}" "${MARKER}.saved"
  trap 'mv "${MARKER}.saved" "${MARKER}" 2>/dev/null || true' EXIT
fi

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}
line_of() { grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1; }

rc=0
out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000 ASSUME_YES=1 bash "${SCRIPT}" --dry-run 2>&1)" || rc=$?
assert_eq "dry run exits 0" "0" "${rc}"
assert_contains "bootstrap apply planned" "+ terraform -chdir=${REPO_ROOT}/terraform/bootstrap apply" "${out}"
assert_contains "persistent apply planned" "+ terraform -chdir=${REPO_ROOT}/terraform/persistent apply" "${out}"
assert_contains "render planned" "+ python3 ${REPO_ROOT}/scripts/lib/render_cml_config.py" "${out}"
assert_contains "cml apply planned" "+ terraform -chdir=${REPO_ROOT}/vendor/cloud-cml apply" "${out}"
assert_contains "env file planned" "+ write ${REPO_ROOT}/config/mcp-env/cml.env" "${out}"

b="$(line_of "terraform/bootstrap apply" "${out}")"; p="$(line_of "terraform/persistent apply" "${out}")"
r="$(line_of "render_cml_config.py" "${out}")"; c="$(line_of "vendor/cloud-cml apply" "${out}")"
if [[ "${b}" -lt "${p}" && "${p}" -lt "${r}" && "${r}" -lt "${c}" ]]; then
  echo "[OK]    order bootstrap < persistent < render < cml"
else
  echo "[FAIL]  order wrong: ${b} ${p} ${r} ${c}"; failures=$((failures + 1))
fi

# A real --dry-run now skips the VM existence check entirely (I2), so these
# two scenarios exercise refuse_if_vm_exists directly by sourcing the
# script. tf_out is overridden so out_or_placeholder need not reach real
# terraform state; az comes from the stub on PATH.

# An az auth failure (not a missing VM) must not be treated as "VM absent".
rc=0
out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" AZ_STUB_AUTH_FAIL=1 bash -c "
  source '${SCRIPT}'
  tf_out() { echo rg-cml-lab; }
  DRY_RUN=0
  refuse_if_vm_exists
" 2>&1)" || rc=$?
assert_eq "az auth failure exits 1" "1" "${rc}"
assert_contains "az auth failure names the problem" "cannot query VM state" "${out}"

# A genuinely missing resource group (real az CLI text) must not die either.
rc=0
out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" AZ_STUB_RG_MISSING=1 bash -c "
  source '${SCRIPT}'
  tf_out() { echo rg-cml-lab; }
  DRY_RUN=0
  refuse_if_vm_exists
" 2>&1)" || rc=$?
assert_eq "missing resource group exits 0" "0" "${rc}"
assert_contains "missing resource group passes" "no existing CML VM" "${out}"

# Without the preflight marker, a real run refuses before doing anything.
rm -f "${REPO_ROOT}/.preflight-ok"
rc=0; out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=x bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "refuses without marker" "1" "${rc}"
assert_contains "names the remedy" "scripts/00-preflight.sh" "${out}"

if [[ "${failures}" -gt 0 ]]; then echo "test_up_dry_run: ${failures} failure(s)"; exit 1; fi
echo "test_up_dry_run: all passed"
