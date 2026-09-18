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

assert_contains "count check planned" "+ compare exports/" "${out}"
v="$(line_of "+ compare exports/" "${out}")"
if [[ "${s}" -lt "${v}" && "${v}" -lt "${u}" ]]; then echo "[OK]    count check after scp, before upload"; else
  echo "[FAIL]  count check order: ${s} ${v} ${u}"; failures=$((failures + 1)); fi

# verify_export_count, for real: the local folder must hold one YAML per
# lab list-labs prints, or the export is not trusted and 40-down.sh stops.
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/exports/stamp1"
printf 'lab:\n' > "${TMP}/exports/stamp1/one-lab-1.yaml"
run_count() {
  ROWS="$1" bash -c "source '${SCRIPT}'; DRY_RUN=0; LOCAL_EXPORTS='${TMP}/exports'
    cml_remote() { printf '%b' \"\${ROWS}\"; }
    verify_export_count stamp1" 2>&1
}
rc=0; out="$(run_count 'lab-1\tOne\tSTOPPED\n')" || rc=$?
assert_eq "matching count passes" "0" "${rc}"
assert_contains "matching count says so" "export holds 1 labs" "${out}"
rc=0; out="$(run_count 'lab-1\tOne\tSTOPPED\nlab-2\tTwo\tSTOPPED\n')" || rc=$?
assert_eq "short export exits 1" "1" "${rc}"
assert_contains "short export names the counts" "exported 1 files but the controller lists 2 labs" "${out}"
rc=0; out="$(bash -c "source '${SCRIPT}'; DRY_RUN=0; LOCAL_EXPORTS='${TMP}/exports'
    cml_remote() { return 1; }
    verify_export_count stamp1" 2>&1)" || rc=$?
assert_eq "unlistable labs exit 1" "1" "${rc}"
assert_contains "unlistable labs named" "cannot list labs" "${out}"

finish "test_export_dry_run"
