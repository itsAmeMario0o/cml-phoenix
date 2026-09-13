#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/30-export-labs.sh"
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" bash "${SCRIPT}" --dry-run 2>&1)"
assert_contains "remote export planned" "+ cml_remote export-labs /data/exports/" "${out}"
assert_contains "scp planned" "+ cml_scp -q -r" "${out}"
assert_contains "blob upload planned" "https://stfake.blob.core.windows.net/exports/" "${out}"
e="$(line_of "cml_remote export-labs /data/exports/" "${out}")"; s="$(line_of "+ cml_scp -q -r" "${out}")"; u="$(line_of "blob.core.windows.net/exports/" "${out}")"
if [[ "${e}" -lt "${s}" && "${s}" -lt "${u}" ]]; then echo "[OK]    order export < scp < upload"; else
  echo "[FAIL]  order: ${e} ${s} ${u}"; failures=$((failures + 1)); fi

finish "test_export_dry_run"
