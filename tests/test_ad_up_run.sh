#!/usr/bin/env bash
# scripts/24-ad-up.sh with dry run OFF, against the stubbed terraform and
# az (tests/stubs). What the script does with a real answer: which run
# commands it clears, whether apply runs when the outputs cannot be read,
# whether ad.env exists after a failed apply, and how dc_check reads the
# DC's answer. tests/test_ad_dry_run.sh still covers the printed plan.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/24-ad-up.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

LOG="${TMP}/calls.log"
AD_ENV="${TMP}/ad.env"
# The persistent tfvars only has to exist: the stub never reads it.
touch "${TMP}/persistent.tfvars"
# run_up [ENV=VALUE...]: the script for real, calls logged. Sets rc, out
# and log for the assertions that follow. ad.env starts absent.
run_up() {
  rm -f "${LOG}" "${AD_ENV}"; rc=0
  out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" STUB_LOG="${LOG}" \
    ARM_SUBSCRIPTION_ID=x ASSUME_YES=1 AD_ENV="${AD_ENV}" \
    PERSISTENT_TFVARS="${TMP}/persistent.tfvars" env "$@" bash "${SCRIPT}" 2>&1)" || rc=$?
  log="$(cat "${LOG}" 2>/dev/null || true)"
}

# 1. Clean run with one failed run command left from an earlier attempt:
#    it is deleted before init, apply runs with the persistent values,
#    ad.env is written from the ad root's outputs, the three checks pass.
run_up AZ_STUB_RUN_COMMANDS="10-promote-forest:Failed 20-install-ca:Succeeded"
assert_eq "clean run exits 0" "0" "${rc}"
assert_contains "failed run command deleted" "az vm run-command delete -g rg-cml-lab --vm-name dc1 --run-command-name 10-promote-forest --yes" "${log}"
assert_not_contains "succeeded run command kept" "run-command-name 20-install-ca" "${log}"
assert_before "delete before init" "run-command delete" "terraform/ad init" "${log}"
assert_before "init before apply" "terraform/ad init" "terraform/ad apply" "${log}"
assert_contains "apply gets the persistent values" "-var=apps_subnet_cidr=10.20.2.0/24 -var=cml_private_ip=10.20.1.10 -auto-approve" "${log}"
assert_before "apply before the ad outputs are read" "terraform/ad apply" "terraform/ad output -json" "${log}"
assert_before "outputs read before the first DC check" "terraform/ad output -json" "Get-ADDomain" "${log}"
assert_eq "three DC checks" "3" "$(grep -c 'run-command invoke' <<<"${log}")"
assert_contains "ad.env written" "AD_ADMIN_PASSWORD='StubAdminPw1'" "$(cat "${AD_ENV}")"
assert_contains "DNS check uses the domain from ad.env" "Resolve-DnsName dc1.corp.example" "${log}"
assert_contains "directory check passes" "[OK]    directory answers for corp.example" "${out}"
assert_contains "CA check passes" "[OK]    certification authority is alive" "${out}"
assert_not_contains "no password on stdout or stderr" "StubAdminPw1" "${out}"

# 2. No failed run command: nothing deleted, apply still runs.
run_up AZ_STUB_RUN_COMMANDS="10-promote-forest:Succeeded"
assert_eq "nothing to clear exits 0" "0" "${rc}"
assert_not_contains "nothing to clear deletes nothing" "run-command delete" "${log}"
assert_contains "nothing to clear still applies" "terraform/ad apply" "${log}"

# 3. Documents current behaviour, case-sensitive filter: the query is
#    [?provisioningState=='Failed'] and JMESPath compares exactly, so a
#    state spelled "failed" is not cleared and the apply goes ahead into
#    "already exists". Azure spells it Failed today; the stub mirrors the
#    exact compare. Whether that is a bug is the operator's call.
run_up AZ_STUB_RUN_COMMANDS="10-promote-forest:failed"
assert_eq "documents current behaviour, case-sensitive filter: exits 0" "0" "${rc}"
assert_not_contains "documents current behaviour, case-sensitive filter: 'failed' is not cleared" "run-command delete" "${log}"
assert_contains "documents current behaviour, case-sensitive filter: apply runs anyway" "terraform/ad apply" "${log}"

# 4. The persistent root has no outputs: [FAIL] before any terraform
#    apply or az call, and no ad.env.
run_up TF_STUB_FAIL=1
assert_eq "no persistent outputs exits 1" "1" "${rc}"
assert_contains "no persistent outputs is a FAIL" "[FAIL]  persistent output resource_group_name unavailable" "${out}"
assert_not_contains "no persistent outputs never applies" "terraform/ad apply" "${log}"
assert_not_contains "no persistent outputs never inits" "terraform/ad init" "${log}"
assert_not_contains "no persistent outputs never reaches az" "az " "${log}"
assert_eq "no persistent outputs writes no ad.env" "absent" "$([[ -f "${AD_ENV}" ]] && echo present || echo absent)"

# 5. The apply fails: exit 1, no ad.env, the outputs and the checks are
#    never asked for.
run_up TF_STUB_FAIL="terraform/ad apply"
assert_eq "failed apply exits 1" "1" "${rc}"
assert_contains "terraform's error reaches the operator" "Error: terraform stub: terraform/ad apply failed" "${out}"
assert_eq "failed apply writes no ad.env" "absent" "$([[ -f "${AD_ENV}" ]] && echo present || echo absent)"
assert_not_contains "failed apply never reads the ad outputs" "terraform/ad output" "${log}"
assert_not_contains "failed apply never checks the DC" "run-command invoke" "${log}"
assert_not_contains "failed apply never claims success" "[OK]" "${out}"

# 6. The apply succeeds but the ad root has no outputs: [FAIL], no ad.env.
run_up TF_STUB_FAIL="terraform/ad output"
assert_eq "no ad outputs exits 1" "1" "${rc}"
assert_contains "no ad outputs is a FAIL" "[FAIL]  terraform/ad has no outputs; did the apply finish?" "${out}"
assert_eq "no ad outputs writes no ad.env" "absent" "$([[ -f "${AD_ENV}" ]] && echo present || echo absent)"
assert_not_contains "no ad outputs never checks the DC" "run-command invoke" "${log}"

# 7. The DC's DNS check answers with a PowerShell error instead of dns-ok:
#    that one check is a [FAIL], the other two still run, exit 1.
run_up AZ_STUB_DC_FAIL="dns-ok"
assert_eq "failed DNS check exits 1" "1" "${rc}"
assert_contains "failed DNS check is a FAIL" "[FAIL]  DNS resolves the zone and, through the forwarder, a public name: expected 'dns-ok' in the DC's answer" "${out}"
assert_contains "directory check still passes" "[OK]    directory answers for corp.example" "${out}"
assert_contains "CA check still runs" "[OK]    certification authority is alive" "${out}"
assert_contains "summary counts the failure" "summary: 3 OK, 0 WARN, 1 FAIL" "${out}"

# 8. The DC answers a different domain than ad.env says: [FAIL].
run_up AZ_STUB_DC_DOMAIN="other.example"
assert_eq "wrong domain exits 1" "1" "${rc}"
assert_contains "wrong domain is a FAIL" "[FAIL]  directory answers for corp.example: expected 'corp.example' in the DC's answer" "${out}"

finish "test_ad_up_run"
