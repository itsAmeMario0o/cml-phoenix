#!/usr/bin/env bash
# Preflight is read-only, so the test runs it for real when RUN_AZ_TESTS=1
# and otherwise only checks the failure path that needs no Azure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/00-preflight.sh"
failures=0

# Never destroy an operator's real preflight marker. Save it aside and
# restore it no matter how this test exits. Also clear the scratch
# directory used for the ISE env fixture below (matches the .gitignore
# tests/.tmp*/ pattern, so nothing here is ever tracked).
MARKER="${REPO_ROOT}/.preflight-ok"
ISE_TMP_DIR="${REPO_ROOT}/tests/.tmp-ise"
if [[ -f "${MARKER}" ]]; then
  mv "${MARKER}" "${MARKER}.saved"
fi
cleanup() {
  mv "${MARKER}.saved" "${MARKER}" 2>/dev/null || true
  rm -rf "${ISE_TMP_DIR}"
}
trap cleanup EXIT
rm -rf "${ISE_TMP_DIR}"
mkdir -p "${ISE_TMP_DIR}"

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "[OK]    ${label}"
  else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"
    failures=$((failures + 1))
  fi
}

# sas_seconds is a pure parser; source the script (common.sh's counters are
# harmless here) to unit test it directly without touching Azure.
sas_of() { bash -c "source '${SCRIPT}'; sas_seconds '$1'"; }
assert_eq "sas_seconds 4h" "14400" "$(sas_of 4h)"
assert_eq "sas_seconds 4h30m" "16200" "$(sas_of 4h30m)"
assert_eq "sas_seconds 30m" "1800" "$(sas_of 30m)"
assert_eq "sas_seconds 240" "240" "$(sas_of 240)"
assert_eq "sas_seconds abc" "0" "$(sas_of abc)"
assert_eq "sas_seconds 4h30 (missing trailing m)" "0" "$(sas_of 4h30)"
assert_eq "sas_seconds 08h (no octal parse)" "28800" "$(sas_of 08h)"
assert_eq "sas_seconds 08h08m (no octal parse, compound)" "29280" "$(sas_of 08h08m)"

# Missing tfvars must be a FAIL line, not a crash, and the marker must not exist.
rm -f "${REPO_ROOT}/.preflight-ok"
out="$(CML_TFVARS="${REPO_ROOT}/does-not-exist.tfvars" bash "${SCRIPT}" 2>&1 || true)"
assert_contains "missing tfvars is a FAIL" "[FAIL]  config/cml.tfvars" "${out}"
assert_contains "summary line printed" "summary:" "${out}"
if [[ -f "${REPO_ROOT}/.preflight-ok" ]]; then
  echo "[FAIL]  marker written despite failure"; failures=$((failures + 1))
else
  echo "[OK]    no marker on failure"
fi

# check_ise_marketplace: point ISE_ENV_FILE at a scratch path instead of
# the operator's real config/mcp-env/ise.env. FAIL_COUNT proves an absent
# file only WARNs and never fails preflight.
ise_of() {
  local env_file="$1"
  PATH="${REPO_ROOT}/tests/stubs:${PATH}" ISE_ENV_FILE="${env_file}" \
    bash -c "source '${SCRIPT}'; check_ise_marketplace; echo FAIL_COUNT=\${fail}"
}

out="$(ise_of "${ISE_TMP_DIR}/absent.env")"
assert_contains "ise.env absent warns" "[WARN]  config/mcp-env/ise.env missing" "${out}"
assert_contains "ise.env absent does not fail preflight" "FAIL_COUNT=0" "${out}"

cat > "${ISE_TMP_DIR}/ise.env" <<'EOF'
ISE_IMAGE_PUBLISHER=cisco
ISE_IMAGE_OFFER=cisco-ise-virtual
ISE_IMAGE_SKU=cisco-ise_3_5
ISE_IMAGE_VERSION=latest
EOF
out="$(ise_of "${ISE_TMP_DIR}/ise.env")"
assert_contains "ise.env present gives OK" "[OK]    ISE Marketplace terms accepted" "${out}"
assert_contains "ise.env present does not fail preflight" "FAIL_COUNT=0" "${out}"

if [[ "${RUN_AZ_TESTS:-0}" == "1" ]]; then
  out="$(bash "${SCRIPT}" 2>&1 || true)"
  assert_contains "az login check ran" "azure login:" "${out}"
  assert_contains "quota check ran" "quota" "${out}"
fi

if [[ "${failures}" -gt 0 ]]; then echo "test_preflight: ${failures} failure(s)"; exit 1; fi
echo "test_preflight: all passed"
