#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/30-export-labs.sh"
chmod +x "${REPO_ROOT}/tests/stubs/"*
failures=0
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
line_of() { grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1; }

out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" bash "${SCRIPT}" --dry-run 2>&1)"
assert_contains "remote export planned" "bash -s -- export-labs /data/exports/" "${out}"
assert_contains "scp planned" "+ scp -P 1122" "${out}"
assert_contains "blob upload planned" "https://stfake.blob.core.windows.net/exports/" "${out}"
e="$(line_of "export-labs /data/exports/" "${out}")"; s="$(line_of "+ scp -P 1122" "${out}")"; u="$(line_of "blob.core.windows.net/exports/" "${out}")"
if [[ "${e}" -lt "${s}" && "${s}" -lt "${u}" ]]; then echo "[OK]    order export < scp < upload"; else
  echo "[FAIL]  order: ${e} ${s} ${u}"; failures=$((failures + 1)); fi

if [[ "${failures}" -gt 0 ]]; then echo "test_export_dry_run: ${failures} failure(s)"; exit 1; fi
echo "test_export_dry_run: all passed"
