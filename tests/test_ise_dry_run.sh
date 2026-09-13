#!/usr/bin/env bash
# Dry-run tests for scripts/25-ise-up.sh and scripts/45-ise-down.sh. az and
# terraform are stubbed through PATH; real config/mcp-env/ise.env and
# config/cml.tfvars are never read, so this runs on a fresh clone with no
# operator secrets and never depends on either file's real contents.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UP_SCRIPT="${REPO_ROOT}/scripts/25-ise-up.sh"
DOWN_SCRIPT="${REPO_ROOT}/scripts/45-ise-down.sh"
chmod +x "${REPO_ROOT}/tests/stubs/"*
failures=0

# Fake secrets, distinct enough that an accidental leak cannot be
# mistaken for anything else. If either string appears anywhere in the
# up script's dry-run output, the test must fail.
FAKE_PASSWORD="Sup3rSecretTestOnly-DoNotLeak"
FAKE_RADIUS_SECRET="Sup3rRadiusTestOnly-DoNotLeak"

FIXTURE_DIR="${REPO_ROOT}/tests/.tmp-ise-dry-run"
rm -rf "${FIXTURE_DIR}"
mkdir -p "${FIXTURE_DIR}"

# The rendered custom-data file is a real repo path (scripts/lib take no
# override for it), so an operator's real file, if one exists, is backed
# up and restored rather than clobbered.
USERDATA_FILE="${REPO_ROOT}/config/mcp-env/ise-userdata"
if [[ -f "${USERDATA_FILE}" ]]; then
  mv "${USERDATA_FILE}" "${USERDATA_FILE}.saved"
fi
cleanup() {
  rm -rf "${FIXTURE_DIR}"
  rm -f "${USERDATA_FILE}"
  mv "${USERDATA_FILE}.saved" "${USERDATA_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

cat > "${FIXTURE_DIR}/ise.env" <<EOF
ISE_IMAGE_PUBLISHER=cisco
ISE_IMAGE_OFFER=cisco-ise-virtual
ISE_IMAGE_SKU=cisco-ise_3_5
ISE_IMAGE_VERSION=latest
ISE_VM_SIZE=Standard_D8s_v4
ISE_PRIVATE_IP=10.20.2.20
ISE_HOSTNAME=ise-lab
ISE_ADMIN_PASSWORD=${FAKE_PASSWORD}
RADIUS_SECRET=${FAKE_RADIUS_SECRET}
EOF

cat > "${FIXTURE_DIR}/cml.tfvars" <<'EOF'
allowed_ipv4_subnets_mgmt = ["203.0.113.10/32"]
allowed_ipv4_subnets_cml2 = ["203.0.113.10/32"]
EOF

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "[FAIL]  ${label}: found forbidden '${needle}'"; failures=$((failures + 1))
  else
    echo "[OK]    ${label}"
  fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

# --- 25-ise-up.sh --dry-run ---

rc=0
up_out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" \
  ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000 \
  ASSUME_YES=1 \
  ISE_ENV_FILE="${FIXTURE_DIR}/ise.env" \
  CML_TFVARS="${FIXTURE_DIR}/cml.tfvars" \
  bash "${UP_SCRIPT}" --dry-run 2>&1)" || rc=$?
assert_eq "up dry run exits 0" "0" "${rc}"

assert_contains "userdata render planned" "+ render_ise_userdata ${REPO_ROOT}/config/mcp-env/ise-userdata" "${up_out}"
assert_contains "nsg create planned" "+ az network nsg create -g rg-cml-lab -n ise-nsg" "${up_out}"
assert_contains "radius rule planned" "1812 1813" "${up_out}"
assert_contains "coa rule planned" "1700" "${up_out}"
assert_contains "admin rule scoped to operator address" "203.0.113.10/32" "${up_out}"
assert_not_contains "no 0.0.0.0/0 anywhere" "0.0.0.0/0" "${up_out}"
assert_contains "vm create image" "--image cisco:cisco-ise-virtual:cisco-ise_3_5:latest" "${up_out}"
assert_contains "vm create plan" "--plan-name cisco-ise_3_5 --plan-product cisco-ise-virtual --plan-publisher cisco" "${up_out}"
assert_contains "vm create size" "--size Standard_D8s_v4" "${up_out}"
assert_contains "vm create subnet" "--subnet <apps_subnet_id>" "${up_out}"
assert_contains "vm create private ip" "--private-ip-address 10.20.2.20" "${up_out}"
assert_contains "vm create no public ip" "--public-ip-address" "${up_out}"
assert_contains "vm create tags" "--tags project=cml-azure-lab role=ise" "${up_out}"
assert_contains "nic tagged too" "+ az network nic update" "${up_out}"
assert_contains "readiness wait planned" "+ poll https://10.20.2.20/admin/API/mnt/Version through 203.0.113.5:1122" "${up_out}"
assert_contains "ise forward planned" "+ ssh -p 1122 -i ${REPO_ROOT}/keys/cml-lab" "${up_out}"
assert_contains "ise forward local port and target" "-N -L 18443:10.20.2.20:443" "${up_out}"
assert_contains "ise forward jump host" "sysadmin@203.0.113.5" "${up_out}"
assert_contains "ise policy step planned" "+ python3 ${REPO_ROOT}/scripts/lib/ise_config.py" "${up_out}"

assert_not_contains "admin password never printed" "${FAKE_PASSWORD}" "${up_out}"
assert_not_contains "no --custom-data content inlined" "password=${FAKE_PASSWORD}" "${up_out}"
assert_not_contains "radius secret never printed" "${FAKE_RADIUS_SECRET}" "${up_out}"
# ISE_API_BASE carries no secret (it is just the forwarded local URL),
# and apply_ise_policy sets it as a prefix assignment on the run() call
# rather than an argument, so it never appears in the dry-run plan at
# all, secret or not.
assert_not_contains "ISE_API_BASE never appears in the plan" "ISE_API_BASE" "${up_out}"

# --- 45-ise-down.sh --dry-run ---

touch "${USERDATA_FILE}"

rc=0
down_out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" \
  ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000 \
  ASSUME_YES=1 \
  bash "${DOWN_SCRIPT}" --dry-run 2>&1)" || rc=$?
assert_eq "down dry run exits 0" "0" "${rc}"

assert_contains "vm delete planned" "+ az vm delete --ids" "${down_out}"
assert_contains "nic delete planned" "+ az network nic delete --ids" "${down_out}"
assert_contains "nsg delete planned" "+ az network nsg delete --ids" "${down_out}"
assert_contains "disk delete planned" "+ az disk delete --ids" "${down_out}"
assert_contains "public ip delete planned" "+ az network public-ip delete --ids" "${down_out}"
assert_contains "userdata file removal planned" "+ rm -f ${USERDATA_FILE}" "${down_out}"

vm_line="$(grep -n '+ az vm delete' <<<"${down_out}" | head -1 | cut -d: -f1)"
nic_line="$(grep -n '+ az network nic delete' <<<"${down_out}" | head -1 | cut -d: -f1)"
if [[ "${vm_line}" -lt "${nic_line}" ]]; then
  echo "[OK]    vm deleted before nic"
else
  echo "[FAIL]  vm delete (${vm_line}) not before nic delete (${nic_line})"; failures=$((failures + 1))
fi

# Never touches bootstrap, persistent, or the CML VM.
if grep -qiE 'cml-controller|terraform.*(bootstrap|persistent)' "${DOWN_SCRIPT}"; then
  echo "[FAIL]  45-ise-down.sh references the CML VM or another root"; failures=$((failures + 1))
else
  echo "[OK]    45-ise-down.sh touches only role=ise resources"
fi

if [[ "${failures}" -gt 0 ]]; then echo "test_ise_dry_run: ${failures} failure(s)"; exit 1; fi
echo "test_ise_dry_run: all passed"
