#!/usr/bin/env bash
# Dry-run and unit tests for the Active Directory root's operator scripts
# (ADR 0010): scripts/24-ad-up.sh and scripts/46-ad-down.sh, plus static
# checks on the PowerShell that terraform/ad delivers by run command.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UP="${REPO_ROOT}/scripts/24-ad-up.sh"
DOWN="${REPO_ROOT}/scripts/46-ad-down.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

stubbed() { PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=x ASSUME_YES=1 "$@"; }

# 1. Up, dry run: init, then an apply given the persistent root's tfvars and
#    outputs, then the env file, the three checks, and the ISE form values.
out="$(stubbed bash "${UP}" --dry-run 2>&1)"
assert_contains "init planned" "+ terraform -chdir=${REPO_ROOT}/terraform/ad init -input=false" "${out}"
assert_contains "apply planned" "+ terraform -chdir=${REPO_ROOT}/terraform/ad apply" "${out}"
assert_contains "owner and expires from the persistent tfvars" "-var-file=${REPO_ROOT}/terraform/persistent/terraform.tfvars" "${out}"
assert_contains "resource group from the persistent output" "-var=resource_group_name=rg-cml-lab" "${out}"
assert_contains "subnet passed" "-var=apps_subnet_id=" "${out}"
assert_contains "auto-approve only because ASSUME_YES=1" "-auto-approve" "${out}"
assert_contains "failed run commands cleared before the apply" "+ delete any Failed run command on dc1" "${out}"
assert_contains "env file step planned" "mode 0600 from terraform output (values never printed)" "${out}"
assert_contains "directory check planned" "(Get-ADDomain).DNSRoot" "${out}"
assert_contains "DNS check planned" "Resolve-DnsName login.microsoftonline.com" "${out}"
assert_contains "CA check planned" "certutil -ping" "${out}"
assert_contains "prints ISE's name server" "Primary Name Server: 10.20.2.10" "${out}"
assert_contains "prints ISE's domain" "DNS domain name:     corp.rooez.com" "${out}"
a="$(line_of "terraform/ad init" "${out}")"; b="$(line_of "terraform/ad apply" "${out}")"; c="$(line_of "Get-ADDomain" "${out}")"
if [[ "${a}" -lt "${b}" && "${b}" -lt "${c}" ]]; then echo "[OK]    order init < apply < checks"; else
  echo "[FAIL]  order: ${a} ${b} ${c}"; failures=$((failures + 1)); fi

# 2. Without ASSUME_YES the apply keeps terraform's own approval prompt.
out="$(printf 'y\n' | PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=x bash "${UP}" --dry-run 2>&1)"
assert_not_contains "no auto-approve without ASSUME_YES" "-auto-approve" "${out}"

# 3. write_ad_env: the file is 0600, holds the passwords quoted, and no
#    password reaches stdout or stderr.
# shellcheck source=scripts/24-ad-up.sh
source "${UP}"
AD_ENV="${TMP}/ad.env"
DRY_RUN=0
out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" write_ad_env 2>&1)"
mode="$(ls -l "${AD_ENV}" | cut -c1-10)"
assert_eq "ad.env is mode 0600" "-rw-------" "${mode}"
body="$(cat "${AD_ENV}")"
assert_contains "admin password written, quoted" "AD_ADMIN_PASSWORD='StubAdminPw1'" "${body}"
assert_contains "symbols survive quoting" "AD_SVC_ISE_PASSWORD='StubSvc!Pw#2'" "${body}"
assert_contains "domain written" "AD_DOMAIN=corp.example" "${body}"
for secret in StubAdminPw1 'StubSvc!Pw#2' 'StubLab*Pw=3'; do
  assert_not_contains "password never echoed" "${secret}" "${out}"
done
sourced="$(bash -c "source '${AD_ENV}'; printf '%s' \"\${AD_LAB_USER_PASSWORD}\"")"
assert_eq "sourcing the file returns the password unchanged" 'StubLab*Pw=3' "${sourced}"

# 4. Down, dry run: destroys terraform/ad with the same variables, removes
#    the env file, and can never name another root.
out="$(stubbed bash "${DOWN}" --dry-run 2>&1)"
assert_contains "destroy planned" "+ terraform -chdir=${REPO_ROOT}/terraform/ad destroy -auto-approve" "${out}"
assert_contains "destroy gets the same variables" "-var=apps_subnet_id=" "${out}"
assert_contains "env file removed" "+ rm -f -- ${REPO_ROOT}/config/mcp-env/ad.env" "${out}"
if grep -qE 'chdir="\$\{REPO_ROOT\}/terraform/(persistent|bootstrap)"|vendor/cloud-cml' "${DOWN}"; then
  echo "[FAIL]  46-ad-down.sh names a root other than terraform/ad"; failures=$((failures + 1))
else
  echo "[OK]    46-ad-down.sh touches only terraform/ad"
fi

# 5. The PowerShell: strict mode, stop on error, a transcript, and a guard
#    that makes a rerun safe. Parsed with pwsh when it is installed.
for ps in 10-promote-forest 20-install-ca 30-create-identities; do
  src="$(cat "${REPO_ROOT}/scripts/ad/${ps}.ps1")"
  assert_contains "${ps}: strict mode" "Set-StrictMode -Version Latest" "${src}"
  assert_contains "${ps}: stops on error" "\$ErrorActionPreference = 'Stop'" "${src}"
  assert_contains "${ps}: transcript" "Start-Transcript -Path 'C:\\lab\\log\\${ps}.txt'" "${src}"
  assert_contains "${ps}: param block" "param(" "${src}"
done
assert_contains "promotion is skipped on a DC" "already a domain controller" "$(cat "${REPO_ROOT}/scripts/ad/10-promote-forest.ps1")"
assert_contains "CA install is skipped when present" "already installed" "$(cat "${REPO_ROOT}/scripts/ad/20-install-ca.ps1")"
ca_src="$(cat "${REPO_ROOT}/scripts/ad/20-install-ca.ps1")"
assert_contains "certutil failures are not discarded" "if (\$LASTEXITCODE -ne 0)" "${ca_src}"
assert_contains "CRL overlap uses the value the CA reads" "CA\\CRLOverlapUnits" "${ca_src}"
assert_not_contains "the unread Quick Start value is gone" "CRLOverlapPeriodUnits'" "${ca_src}"
assert_not_contains "the SAN attribute flag is never set" "-setreg policy" "${ca_src}"
if command -v pwsh >/dev/null 2>&1; then
  for ps in "${REPO_ROOT}"/scripts/ad/*.ps1; do
    if pwsh -NoProfile -NonInteractive -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('${ps}',[ref]\$null,[ref]\$e); exit \$e.Count" >/dev/null 2>&1; then
      echo "[OK]    $(basename "${ps}") parses"
    else
      echo "[FAIL]  $(basename "${ps}") has PowerShell syntax errors"; failures=$((failures + 1))
    fi
  done
else
  echo "[WARN]  pwsh not installed, PowerShell syntax not checked"
fi

# 5b. What terraform delivers for the CA and identity steps is the wrapper
#     with the inner script substituted for its marker line. Compose it
#     the same way and check the result still parses, and that the marker
#     sits inside a single-quoted here-string the inner scripts cannot end.
wrapper="${REPO_ROOT}/scripts/ad/run-as-admin.ps1"
assert_eq "wrapper has exactly one marker" "1" "$(grep -c '^__INNER_SCRIPT__$' "${wrapper}")"
for inner in 20-install-ca 30-create-identities; do
  if grep -q "^'@" "${REPO_ROOT}/scripts/ad/${inner}.ps1"; then
    echo "[FAIL]  ${inner}.ps1 has a line starting with '@, which would end the wrapper's here-string"; failures=$((failures + 1))
  else
    echo "[OK]    ${inner}.ps1 cannot end the wrapper's here-string"
  fi
  python3 - "${wrapper}" "${REPO_ROOT}/scripts/ad/${inner}.ps1" "${TMP}/${inner}.composed.ps1" <<'PY'
import sys
w, i, o = sys.argv[1:4]
open(o, "w").write(open(w).read().replace("__INNER_SCRIPT__", open(i).read()))
PY
  if command -v pwsh >/dev/null 2>&1; then
    if pwsh -NoProfile -NonInteractive -Command "\$e=\$null; [void][System.Management.Automation.Language.Parser]::ParseFile('${TMP}/${inner}.composed.ps1',[ref]\$null,[ref]\$e); exit \$e.Count" >/dev/null 2>&1; then
      echo "[OK]    wrapper composed with ${inner}.ps1 parses"
    else
      echo "[FAIL]  wrapper composed with ${inner}.ps1 has syntax errors"; failures=$((failures + 1))
    fi
  fi
done
assert_contains "wrapper waits for the directory as SYSTEM" "function Wait-Directory" "$(cat "${wrapper}")"
assert_contains "wrapper removes the arguments file" "Remove-Item -Path \$argsFile" "$(cat "${wrapper}")"
if grep -q "run_as_user" "${REPO_ROOT}/terraform/ad/main.tf"; then
  echo "[FAIL]  terraform/ad uses run_as_user, which cannot log a domain account on to a DC"; failures=$((failures + 1))
else
  echo "[OK]    terraform/ad does not use run_as_user"
fi

# 6. The identities file the third script consumes.
assert_eq "identities CSV header" "username,display,groups" "$(head -1 "${REPO_ROOT}/config/ad-identities.csv")"

finish "test_ad_dry_run"
