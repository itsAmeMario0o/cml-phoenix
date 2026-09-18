#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/40-down.sh"
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=x ASSUME_YES=1 bash "${SCRIPT}" --dry-run 2>&1)"
assert_contains "export first" "30-export-labs.sh --dry-run" "${out}"
assert_contains "stop labs" "+ cml_remote stop-labs" "${out}"
assert_contains "deregister via del.sh" "/provision/del.sh" "${out}"
assert_contains "destroy cml root" "+ terraform -chdir=${REPO_ROOT}/vendor/cloud-cml destroy" "${out}"
a="$(line_of "30-export-labs.sh" "${out}")"; b="$(line_of "cml_remote stop-labs" "${out}")"; c="$(line_of "/provision/del.sh" "${out}")"; d="$(line_of "vendor/cloud-cml destroy" "${out}")"
if [[ "${a}" -lt "${b}" && "${b}" -lt "${c}" && "${c}" -lt "${d}" ]]; then echo "[OK]    order export < stop < deregister < destroy"; else
  echo "[FAIL]  order: ${a} ${b} ${c} ${d}"; failures=$((failures + 1)); fi

# config/cml.yml is rendered again before the destroy: Terraform re-reads
# it, and the build's copy went stale on 2026-09-17 (LESSONS-LEARNED).
assert_contains "render before destroy planned" "+ python3 ${REPO_ROOT}/scripts/lib/render_cml_config.py" "${out}"
r="$(line_of "render_cml_config.py" "${out}")"
if [[ "${c}" -lt "${r}" && "${r}" -lt "${d}" ]]; then echo "[OK]    order deregister < render < destroy"; else
  echo "[FAIL]  render order: ${c} ${r} ${d}"; failures=$((failures + 1)); fi
assert_contains "dry run says what would happen" "dry run: would destroy the CML VM" "${out}"
assert_not_contains "dry run never claims a destroy" "CML VM destroyed." "${out}"

# --skip-export: no export, no lab stop, the license gate and the destroy
# as before. ASSUME_YES answers the VM-name prompt only alongside the flag.
skip="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=x ASSUME_YES=1 bash "${SCRIPT}" --dry-run --skip-export 2>&1)"
assert_not_contains "skip-export skips the export" "30-export-labs.sh" "${skip}"
assert_not_contains "skip-export skips the lab stop" "cml_remote stop-labs" "${skip}"
assert_contains "skip-export warns about lab loss" "every lab on cml-controller is lost with it" "${skip}"
assert_contains "skip-export keeps the license gate" "/provision/del.sh" "${skip}"
assert_contains "skip-export keeps the license status check" "+ license gate (status from host)" "${skip}"
assert_contains "skip-export still renders" "render_cml_config.py" "${skip}"
assert_contains "skip-export still destroys" "vendor/cloud-cml destroy" "${skip}"

# Without ASSUME_YES the operator must type the VM name; y is not enough.
rc=0; typed="$(printf 'y\n' | PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=x bash "${SCRIPT}" --dry-run --skip-export 2>&1)" || rc=$?
assert_eq "wrong name declines" "1" "${rc}"
assert_contains "wrong name says declined" "declined" "${typed}"
assert_not_contains "wrong name never reaches the destroy" "vendor/cloud-cml destroy" "${typed}"
rc=0; typed="$(printf 'cml-controller\n' | PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=x bash "${SCRIPT}" --dry-run --skip-export 2>&1)" || rc=$?
assert_eq "typed VM name proceeds" "0" "${rc}"
assert_contains "typed VM name reaches the destroy" "vendor/cloud-cml destroy" "${typed}"
rc=0; bash "${SCRIPT}" --skip-exports >/dev/null 2>&1 || rc=$?
assert_eq "misspelt flag exits 1" "1" "${rc}"

# The script must never be able to destroy the other roots.
if grep -qiE '(persistent|bootstrap)[^ ]* +\bdestroy\b|\bdestroy\b[^\n]*(persistent|bootstrap)' "${SCRIPT}"; then
  echo "[FAIL]  script references destroy on persistent or bootstrap"; failures=$((failures + 1))
else
  echo "[OK]    no destroy on persistent or bootstrap"
fi

# license_blocked: 0 (blocked) for anything but a confirmed NOT_REGISTERED.
# shellcheck source=scripts/40-down.sh
source "${SCRIPT}"
assert_license_blocked() {
  local label="$1" status="$2" expected="$3" actual
  if license_blocked "${status}"; then actual=0; else actual=1; fi
  if [[ "${actual}" == "${expected}" ]]; then
    echo "[OK]    license_blocked ${label}"
  else
    echo "[FAIL]  license_blocked ${label}: expected ${expected}, got ${actual}"
    failures=$((failures + 1))
  fi
}
assert_license_blocked "REGISTERED blocks" "REGISTERED" 0
assert_license_blocked "UNKNOWN blocks" "UNKNOWN" 0
assert_license_blocked "empty blocks" "" 0
assert_license_blocked "two-line value blocks" "$(printf 'REGISTERED\nREGISTERED')" 0
assert_license_blocked "NOT_REGISTERED does not block" "NOT_REGISTERED" 1

finish "test_down_dry_run"
