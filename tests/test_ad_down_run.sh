#!/usr/bin/env bash
# scripts/46-ad-down.sh with dry run OFF, against the stubbed terraform
# (tests/stubs). The script promises: destroy terraform/ad with the same
# variables apply got, then remove ad.env. So ad.env must survive a
# failed destroy, and no destroy may run when the variables cannot be
# read. tests/test_ad_dry_run.sh still covers the printed plan.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/46-ad-down.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

LOG="${TMP}/calls.log"
AD_ENV="${TMP}/ad.env"
# run_down [ENV=VALUE...]: the script for real, calls logged, with an
# ad.env in place from a previous up. Sets rc, out and log.
run_down() {
  rm -f "${LOG}"; echo "AD_DOMAIN=corp.example" > "${AD_ENV}"; rc=0
  out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" STUB_LOG="${LOG}" \
    ARM_SUBSCRIPTION_ID=x ASSUME_YES=1 AD_ENV="${AD_ENV}" env "$@" bash "${SCRIPT}" 2>&1)" || rc=$?
  log="$(cat "${LOG}" 2>/dev/null || true)"
}
ad_env_state() { [[ -f "${AD_ENV}" ]] && echo present || echo absent; }

# 1. Clean run: one destroy of terraform/ad with the persistent values,
#    then ad.env is gone.
run_down
assert_eq "clean run exits 0" "0" "${rc}"
assert_contains "clean run is an OK" "[OK]    domain controller destroyed." "${out}"
assert_eq "one destroy" "1" "$(grep -c ' destroy ' <<<"${log}")"
assert_contains "destroy names the ad root only" "terraform -chdir=${REPO_ROOT}/terraform/ad destroy -auto-approve" "${log}"
assert_contains "destroy gets the persistent values" "-var=apps_subnet_cidr=10.20.2.0/24 -var=cml_private_ip=10.20.1.10" "${log}"
assert_eq "no apply, ever" "0" "$(grep -c ' apply' <<<"${log}" || true)"
assert_eq "ad.env removed after the destroy" "absent" "$(ad_env_state)"

# 2. The destroy fails: exit 1, no [OK], and ad.env is still there for
#    the rerun.
run_down TF_STUB_FAIL="terraform/ad destroy"
assert_eq "failed destroy exits 1" "1" "${rc}"
assert_contains "terraform's error reaches the operator" "Error: terraform stub: terraform/ad destroy failed" "${out}"
assert_not_contains "failed destroy never claims success" "[OK]" "${out}"
assert_eq "ad.env kept after a failed destroy" "present" "$(ad_env_state)"

# 3. The persistent root has no outputs: [FAIL], no destroy, ad.env kept.
run_down TF_STUB_FAIL=1
assert_eq "no persistent outputs exits 1" "1" "${rc}"
assert_contains "no persistent outputs is a FAIL" "[FAIL]  persistent output resource_group_name unavailable" "${out}"
assert_not_contains "no persistent outputs never destroys" " destroy " "${log}"
assert_eq "ad.env kept when nothing was destroyed" "present" "$(ad_env_state)"

finish "test_ad_down_run"
