#!/usr/bin/env bash
# Dry-run tests for scripts/25-ise-up.sh and scripts/45-ise-down.sh. az and
# terraform are stubbed through PATH; real config/mcp-env/ise.env and
# keys/cml-lab.pub are never read, so this runs on a fresh clone with no
# operator secrets and never depends on either file's real contents.
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

# ise_params.py (Task 2) reads keys/cml-lab.pub by its real repo-relative
# path (no override is wired through 25-ise-up.sh). An operator's real
# key, if one exists, is backed up and restored rather than clobbered or
# depended on for a deterministic assertion.
PUBKEY_FILE="${REPO_ROOT}/keys/cml-lab.pub"
if [[ -f "${PUBKEY_FILE}" ]]; then
  mv "${PUBKEY_FILE}" "${PUBKEY_FILE}.saved"
fi
mkdir -p "${REPO_ROOT}/keys"
echo "ssh-ed25519 AAAAFAKEKEYFORTESTING test@fixture" > "${PUBKEY_FILE}"

cleanup() {
  rm -rf "${FIXTURE_DIR}"
  rm -f "${PUBKEY_FILE}"
  mv "${PUBKEY_FILE}.saved" "${PUBKEY_FILE}" 2>/dev/null || true
  # A dry run's own mktemp under config/mcp-env/ is left behind by design
  # (only the real python3 invocation, skipped in a dry run, would remove
  # it via the script's own trap); sweep any it leaves.
  rm -f "${REPO_ROOT}/config/mcp-env/ise-params."??????
}
trap cleanup EXIT

cat > "${FIXTURE_DIR}/ise.env" <<EOF
ISE_IMAGE_PUBLISHER=cisco
ISE_IMAGE_OFFER=cisco-ise-virtual
ISE_IMAGE_SKU=cisco-ise_3_5
ISE_IMAGE_VERSION=3.5.527
ISE_VM_SIZE=Standard_D8s_v4
ISE_STORAGE_TYPE=Premium_LRS
ISE_VOLUME_SIZE=600
ISE_PRIVATE_IP=10.20.2.20
ISE_PUBLIC_IP_NAME=ise1-ip
ISE_HOSTNAME=ise1
ISE_DNS_DOMAIN=rooez.com
ISE_PRIMARY_NAMESERVER=8.8.8.8
ISE_PRIMARY_NTP=time.google.com
ISE_TIMEZONE=Etc/UTC
ISE_ERS=yes
ISE_PXGRID=yes
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

# --- 25-ise-up.sh --dry-run ---

rc=0
up_out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" \
  ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000 \
  ASSUME_YES=1 \
  ISE_ENV_FILE="${FIXTURE_DIR}/ise.env" \
  bash "${UP_SCRIPT}" --dry-run 2>&1)" || rc=$?
assert_eq "up dry run exits 0" "0" "${rc}"

assert_contains "nsg create planned" "+ az network nsg create -g rg-cml-lab -n ise-nsg" "${up_out}"
assert_contains "radius rule name and ports" "-n allow-radius" "${up_out}"
assert_contains "radius rule ports" "1812 1813" "${up_out}"
assert_contains "radius rule source is the lab summary" "10.100.0.0/16" "${up_out}"
assert_contains "admin rule name and ports" "-n allow-admin" "${up_out}"
assert_contains "admin rule ports" "443 22" "${up_out}"
assert_contains "admin rule scoped to ISE_ADMIN_SOURCE_CIDR" "10.20.1.10/32" "${up_out}"
assert_not_contains "no 0.0.0.0/0 anywhere" "0.0.0.0/0" "${up_out}"

assert_contains "deployment group create planned" "+ az deployment group create -g rg-cml-lab" "${up_out}"
assert_contains "deployment uses the solution template" "--template-file ${REPO_ROOT}/config/ise/template.json" "${up_out}"
assert_contains "deployment parameters come from a file" "--parameters @" "${up_out}"

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

# The az stub's role=ise listing returns one of each of the five types
# the solution template plus 25-ise-up.sh's tag_osdisk and nsg create
# tag: VM, NIC, NSG, disk, public IP (ADR 0008). No userdata file to
# clean up; the solution-template deploy never renders one (Task 3 uses
# a mktemp params file removed by its own trap).
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
