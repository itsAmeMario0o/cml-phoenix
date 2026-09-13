#!/usr/bin/env bash
# Dry-run tests for scripts/25-ise-up.sh --post-deploy and
# scripts/45-ise-down.sh. az and terraform are stubbed through PATH; real
# config/mcp-env/ise.env is never read, so this runs on a fresh clone with
# no operator secrets and never depends on the file's real contents.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
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

cleanup() {
  rm -rf "${FIXTURE_DIR}"
}
trap cleanup EXIT

cat > "${FIXTURE_DIR}/ise.env" <<EOF
ISE_HOSTNAME=ise1
ISE_PRIVATE_IP=10.20.2.20
ISE_ADMIN_SOURCE_CIDR=10.20.1.10/32
ISE_ADMIN_PASSWORD=${FAKE_PASSWORD}
RADIUS_SECRET=${FAKE_RADIUS_SECRET}
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

# --post-deploy is required: no other invocation is accepted.
rc=0
bash "${UP_SCRIPT}" --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "missing --post-deploy exits 2" "2" "${rc}"

# --- 25-ise-up.sh --post-deploy --dry-run ---

rc=0
up_out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" \
  ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000 \
  ASSUME_YES=1 \
  ISE_ENV_FILE="${FIXTURE_DIR}/ise.env" \
  bash "${UP_SCRIPT}" --post-deploy --dry-run 2>&1)" || rc=$?
assert_eq "up dry run exits 0" "0" "${rc}"

assert_contains "nsg create planned" "+ az network nsg create -g rg-cml-lab -n ise-nsg" "${up_out}"
assert_contains "radius rule name and ports" "-n allow-radius" "${up_out}"
assert_contains "radius rule ports" "1812 1813" "${up_out}"
assert_contains "radius rule source is the lab summary" "10.100.0.0/16" "${up_out}"
assert_contains "admin rule name and ports" "-n allow-admin" "${up_out}"
assert_contains "admin rule ports" "443 22" "${up_out}"
assert_contains "admin rule scoped to ISE_ADMIN_SOURCE_CIDR" "10.20.1.10/32" "${up_out}"
assert_contains "nsg attached to the wizard's nic" "+ az network nic update -g rg-cml-lab -n ise1nic --network-security-group ise-nsg" "${up_out}"
assert_not_contains "no 0.0.0.0/0 anywhere" "0.0.0.0/0" "${up_out}"

assert_contains "vm tagged" "+ az resource tag -g rg-cml-lab" "${up_out}"
assert_contains "vm tag name" "--name ise1 --resource-type Microsoft.Compute/virtualMachines" "${up_out}"
assert_contains "os disk tagged" "+ az disk update -g rg-cml-lab -n ise1osdisk" "${up_out}"
assert_contains "os disk tag role" "tags.role=ise" "${up_out}"

assert_contains "readiness wait planned" "+ poll https://10.20.2.20/admin/API/mnt/Version through 203.0.113.5:1122" "${up_out}"
assert_contains "ise forward planned" "+ ssh -p 1122 -i ${REPO_ROOT}/keys/cml-lab" "${up_out}"
assert_contains "ise forward local port and target" "-N -L 18443:10.20.2.20:443" "${up_out}"
assert_contains "ise forward jump host" "sysadmin@203.0.113.5" "${up_out}"
assert_contains "ise policy step planned" "+ python3 ${REPO_ROOT}/scripts/lib/ise_config.py" "${up_out}"

assert_not_contains "admin password never printed" "${FAKE_PASSWORD}" "${up_out}"
assert_not_contains "radius secret never printed" "${FAKE_RADIUS_SECRET}" "${up_out}"
# ISE_API_BASE carries no secret (it is just the forwarded local URL),
# and apply_ise_policy sets it as a prefix assignment on the run() call
# rather than an argument, so it never appears in the dry-run plan at
# all, secret or not.
assert_not_contains "ISE_API_BASE never appears in the plan" "ISE_API_BASE" "${up_out}"

# --- 45-ise-down.sh --dry-run ---

# The az stub's role=ise listing returns one of each of the five resource
# types 25-ise-up.sh's attach_nsg and tag_resources tag, plus what the
# Marketplace wizard itself creates: VM, NIC, NSG, disk, public IP.
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
