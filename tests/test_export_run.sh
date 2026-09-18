#!/usr/bin/env bash
# scripts/30-export-labs.sh with dry run OFF, against the stubbed
# terraform, curl, ssh, scp and azcopy (tests/stubs). The scp stub
# creates SCP_STUB_FILES YAML files at the destination, so the count
# check compares real files with the stubbed list-labs. The folder is
# pulled into TMP, never the repo's exports/.
# tests/test_export_dry_run.sh still covers the printed plan.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/30-export-labs.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

LOG="${TMP}/calls.log"
run_export() {
  rm -rf "${LOG}" "${TMP}/exports"; rc=0
  out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" STUB_LOG="${LOG}" LOCAL_EXPORTS="${TMP}/exports" \
    env "$@" bash "${SCRIPT}" 2>&1)" || rc=$?
  log="$(cat "${LOG}" 2>/dev/null || true)"
}
TWO_LABS='lab-1\tOne\tSTOPPED\nlab-2\tTwo\tSTARTED\n'

# 1. Two labs listed, two files pulled: uploaded to the persistent
#    root's storage account, one folder per run.
run_export SSH_STUB_LABS="${TWO_LABS}" SCP_STUB_FILES=2
assert_eq "matching export exits 0" "0" "${rc}"
assert_contains "count confirmed" "[OK]    export holds 2 labs, matching the controller" "${out}"
assert_contains "uploaded to the persistent storage account" "azcopy copy ${TMP}/exports/" "${log}"
assert_contains "upload target is the exports container" "https://stfake.blob.core.windows.net/exports/ --recursive" "${log}"
assert_before "exported on the host before the copy" "bash -s -- export-labs /data/exports/" "scp -P 1122" "${log}"
assert_before "copied before the count check" "scp -P 1122" "bash -s -- list-labs" "${log}"
assert_before "count checked before the upload" "bash -s -- list-labs" "azcopy copy" "${log}"
assert_eq "two files on disk" "2" "$(find "${TMP}/exports" -name '*.yaml' | wc -l | tr -d ' ')"

# 2. Two labs listed, one file pulled: no upload, exit 1.
run_export SSH_STUB_LABS="${TWO_LABS}" SCP_STUB_FILES=1
assert_eq "short export exits 1" "1" "${rc}"
assert_contains "short export is a FAIL" "[FAIL]  exported 1 files but the controller lists 2 labs. Nothing is safe to destroy." "${out}"
assert_not_contains "short export never uploads" "azcopy" "${log}"

# 3. The copy fails: no count check, no upload.
run_export SSH_STUB_LABS="${TWO_LABS}" SCP_STUB_FAIL=1
assert_eq "failed copy exits 1" "1" "${rc}"
assert_not_contains "failed copy never counts" "bash -s -- list-labs" "${log}"
assert_not_contains "failed copy never uploads" "azcopy" "${log}"
assert_not_contains "failed copy never claims success" "[OK]" "${out}"

# 4. The upload fails: exit 1 after a confirmed count, no [OK] summary.
run_export SSH_STUB_LABS="${TWO_LABS}" SCP_STUB_FILES=2 AZCOPY_STUB_FAIL=1
assert_eq "failed upload exits 1" "1" "${rc}"
assert_contains "failed upload: count was confirmed first" "export holds 2 labs" "${out}"
assert_not_contains "failed upload never claims the blob copy" "and blob container exports/" "${out}"

# 5. The API is not ready (a 502 page, not JSON): nothing touches the host.
run_export CURL_STUB_HTTP=502
assert_eq "API 502 exits 1" "1" "${rc}"
assert_contains "API 502 is a FAIL" "[FAIL]  CML API at https://203.0.113.5 is not ready. Nothing exported." "${out}"
assert_not_contains "API 502 never exports" "export-labs" "${log}"
assert_eq "API 502: the only ssh is the readiness probe" "1" "$(grep -c '^ssh ' <<<"${log}")"

finish "test_export_run"
