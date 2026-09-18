#!/usr/bin/env bash
# scripts/40-down.sh with dry run OFF, against the stubbed terraform, az,
# ssh, scp, curl and azcopy (tests/stubs). The export runs the real
# scripts/30-export-labs.sh underneath. What matters is what stands
# between a bad answer and the destroy: a failed export, a license the
# host cannot confirm released, a declined prompt, a dead jump host.
# tests/test_down_dry_run.sh still covers the printed plan.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/40-down.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

LOG="${TMP}/calls.log"
# run_down STDIN [ENV=VALUE...] -- [ARGS...]: the script for real, calls
# logged, config/cml.yml rendered into TMP and the export pulled into
# TMP, never into the repo. Sets rc, out and log.
run_down() {
  # envs starts non-empty: bash 3.2 treats an empty array as unbound.
  local stdin="$1" envs=(STUB_LOG="${LOG}"); shift
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  rm -rf "${LOG}" "${TMP}/exports"; rc=0
  out="$(printf '%b' "${stdin}" | PATH="${REPO_ROOT}/tests/stubs:${PATH}" \
    ARM_SUBSCRIPTION_ID=x CML_TFVARS="${REPO_ROOT}/config/cml.tfvars.example" \
    CML_YML="${TMP}/cml.yml" LOCAL_EXPORTS="${TMP}/exports" \
    env "${envs[@]}" bash "${SCRIPT}" "$@" 2>&1)" || rc=$?
  log="$(cat "${LOG}" 2>/dev/null || true)"
}
ONE_LAB='lab-1\tOne\tSTOPPED\n'

# 1. Clean run: export, count check, upload, stop, del.sh, license
#    confirmed, render, destroy, in that order.
run_down '' ASSUME_YES=1 SSH_STUB_LABS="${ONE_LAB}"
assert_eq "clean run exits 0" "0" "${rc}"
assert_contains "clean run destroys" "[OK]    CML VM destroyed." "${out}"
assert_contains "license confirmed" "[OK]    license NOT_REGISTERED" "${out}"
assert_before "API checked before the export" "/api/v0/system_information" "bash -s -- export-labs" "${log}"
assert_before "export before the copy" "bash -s -- export-labs" "scp -P 1122" "${log}"
assert_before "copy before the count check" "scp -P 1122" "bash -s -- list-labs" "${log}"
assert_before "count check before the upload" "bash -s -- list-labs" "azcopy copy" "${log}"
assert_before "upload before the labs stop" "azcopy copy" "bash -s -- stop-labs" "${log}"
assert_before "labs stopped before del.sh" "bash -s -- stop-labs" "/provision/del.sh" "${log}"
assert_before "del.sh before the status check" "/provision/del.sh" "bash -s -- license-status" "${log}"
assert_before "status check before the destroy" "bash -s -- license-status" "vendor/cloud-cml destroy" "${log}"
assert_not_contains "no deregister retry when del.sh worked" "bash -s -- deregister" "${log}"
assert_contains "destroy names the cml root only" "terraform -chdir=${REPO_ROOT}/vendor/cloud-cml destroy -input=false -auto-approve" "${log}"
assert_eq "one destroy" "1" "$(grep -c ' destroy ' <<<"${log}")"
assert_eq "cml.yml rendered into the test's path" "present" "$([[ -f "${TMP}/cml.yml" ]] && echo present || echo absent)"
assert_contains "export copied into the test's path" "${TMP}/exports/" "${log}"

# 2. The API is down: nothing exported, nothing stopped, nothing
#    destroyed, no ssh at all.
run_down '' ASSUME_YES=1 CURL_STUB_HTTP=000
assert_eq "API down exits 1" "1" "${rc}"
assert_contains "API down names the export" "[FAIL]  CML API at https://203.0.113.5 is not ready. Nothing exported." "${out}"
assert_contains "API down refuses the destroy" "[FAIL]  export failed, not destroying." "${out}"
assert_not_contains "API down never destroys" " destroy " "${log}"
assert_not_contains "API down never exports" "export-labs" "${log}"
assert_not_contains "API down never runs del.sh" "/provision/del.sh" "${log}"
assert_eq "API down: the only ssh is the readiness probe" "1" "$(grep -c '^ssh ' <<<"${log}")"
assert_not_contains "API down never claims success" "[OK]" "${out}"

# 3. The export comes up short: no upload, no destroy.
run_down '' ASSUME_YES=1 SSH_STUB_LABS="${ONE_LAB}${ONE_LAB}"
assert_eq "short export exits 1" "1" "${rc}"
assert_contains "short export names the counts" "[FAIL]  exported 1 files but the controller lists 2 labs." "${out}"
assert_not_contains "short export never uploads" "azcopy" "${log}"
assert_not_contains "short export never destroys" " destroy " "${log}"

# 4. del.sh leaves the license UNKNOWN and the API retry cannot fix it:
#    refused, no destroy. The retry is proven from the log.
run_down '' ASSUME_YES=1 SSH_STUB_LABS="${ONE_LAB}" SSH_STUB_LICENSE=UNKNOWN SSH_STUB_DEREGISTER=UNKNOWN
assert_eq "UNKNOWN license exits 1" "1" "${rc}"
assert_contains "UNKNOWN license warns before the retry" "[WARN]  del.sh left the license UNKNOWN, retrying through the API" "${out}"
assert_before "retry after the status check" "bash -s -- license-status" "bash -s -- deregister" "${log}"
assert_contains "UNKNOWN license refuses" "[FAIL]  license still UNKNOWN. Fix it, or rerun with --force-license" "${out}"
assert_not_contains "UNKNOWN license never destroys" " destroy " "${log}"
assert_not_contains "UNKNOWN license never renders" "render_cml_config" "${out}"

# 5. Same, but the API retry releases it: destroy goes ahead.
run_down '' ASSUME_YES=1 SSH_STUB_LABS="${ONE_LAB}" SSH_STUB_LICENSE=REGISTERED SSH_STUB_DEREGISTER=NOT_REGISTERED
assert_eq "released on retry exits 0" "0" "${rc}"
assert_contains "released on retry is confirmed" "[OK]    license NOT_REGISTERED" "${out}"
assert_contains "released on retry destroys" " destroy " "${log}"

# 6. Same as 4 with --force-license: a warning, then the destroy.
run_down '' ASSUME_YES=1 SSH_STUB_LABS="${ONE_LAB}" SSH_STUB_LICENSE=UNKNOWN SSH_STUB_DEREGISTER=UNKNOWN -- --force-license
assert_eq "force-license exits 0" "0" "${rc}"
assert_contains "force-license warns" "[WARN]  license still UNKNOWN, continuing because of --force-license." "${out}"
assert_contains "force-license destroys" " destroy " "${log}"

# 7. A dead jump host: every ssh exits 255. del.sh is tolerated, the
#    status is UNKNOWN, the retry fails too, the destroy is refused.
run_down '' ASSUME_YES=1 SSH_STUB_EXIT=255 -- --skip-export
assert_eq "dead host exits 1" "1" "${rc}"
assert_contains "dead host refuses" "[FAIL]  license still UNKNOWN." "${out}"
assert_not_contains "dead host never destroys" " destroy " "${log}"

# 8. --skip-export with ASSUME_YES: no export, no stop, the license gate
#    and the destroy still run.
run_down '' ASSUME_YES=1 -- --skip-export
assert_eq "skip-export exits 0" "0" "${rc}"
assert_contains "skip-export warns about lab loss" "[WARN]  skipping the export and the lab stop" "${out}"
assert_not_contains "skip-export never exports" "export-labs" "${log}"
assert_not_contains "skip-export never checks the API" "system_information" "${log}"
assert_not_contains "skip-export never stops labs" "stop-labs" "${log}"
assert_contains "skip-export runs del.sh" "/provision/del.sh" "${log}"
assert_contains "skip-export checks the status" "bash -s -- license-status" "${log}"
assert_contains "skip-export destroys" " destroy " "${log}"

# 9. --skip-export without ASSUME_YES: the typed VM name, then y at the
#    destroy prompt. y alone at the first prompt is a decline.
run_down 'cml-controller\ny\n' -- --skip-export
assert_eq "typed name then y exits 0" "0" "${rc}"
assert_contains "typed name then y destroys" " destroy " "${log}"
run_down 'cml-controller\nn\n' -- --skip-export
assert_eq "typed name then n exits 1" "1" "${rc}"
assert_contains "typed name then n is declined" "[FAIL]  declined" "${out}"
assert_contains "typed name then n still ran the license gate" "bash -s -- license-status" "${log}"
assert_not_contains "typed name then n never destroys" " destroy " "${log}"
run_down 'y\ny\n' -- --skip-export
assert_eq "y for the name exits 1" "1" "${rc}"
assert_not_contains "y for the name never touches the host" "ssh " "${log}"

# 10. The destroy itself fails: exit 1 and no claim of success.
run_down '' ASSUME_YES=1 TF_STUB_FAIL="cloud-cml destroy" -- --skip-export
assert_eq "failed destroy exits 1" "1" "${rc}"
assert_contains "terraform's error reaches the operator" "Error: terraform stub: cloud-cml destroy failed" "${out}"
assert_not_contains "failed destroy never claims success" "CML VM destroyed." "${out}"

finish "test_down_run"
