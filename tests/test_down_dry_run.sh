#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/40-down.sh"
chmod +x "${REPO_ROOT}/tests/stubs/"*
failures=0
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
line_of() { grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1; }

out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=x ASSUME_YES=1 bash "${SCRIPT}" --dry-run 2>&1)"
assert_contains "export first" "30-export-labs.sh --dry-run" "${out}"
assert_contains "stop labs" "bash -s -- stop-labs" "${out}"
assert_contains "deregister via del.sh" "/provision/del.sh" "${out}"
assert_contains "destroy cml root" "+ terraform -chdir=${REPO_ROOT}/vendor/cloud-cml destroy" "${out}"
a="$(line_of "30-export-labs.sh" "${out}")"; b="$(line_of "stop-labs" "${out}")"; c="$(line_of "/provision/del.sh" "${out}")"; d="$(line_of "vendor/cloud-cml destroy" "${out}")"
if [[ "${a}" -lt "${b}" && "${b}" -lt "${c}" && "${c}" -lt "${d}" ]]; then echo "[OK]    order export < stop < deregister < destroy"; else
  echo "[FAIL]  order: ${a} ${b} ${c} ${d}"; failures=$((failures + 1)); fi

# The script must never be able to destroy the other roots.
if grep -qE 'chdir=[^ ]*(persistent|bootstrap)[^ ]* +destroy' "${SCRIPT}"; then
  echo "[FAIL]  script references destroy on persistent or bootstrap"; failures=$((failures + 1))
else
  echo "[OK]    no destroy on persistent or bootstrap"
fi

if [[ "${failures}" -gt 0 ]]; then echo "test_down_dry_run: ${failures} failure(s)"; exit 1; fi
echo "test_down_dry_run: all passed"
