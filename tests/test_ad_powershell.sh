#!/usr/bin/env bash
# Static and behavioural checks on the native command calls in scripts/ad
# (ADR 0010). certutil, dsacls, and icacls fail by exit code, not by
# exception, so every call must go through the Invoke-Native helper that
# throws on a nonzero $LASTEXITCODE. What this file proves:
#
#   1. Statically: no raw "& xxx.exe" call site remains outside the
#      helper's own definition, each script carries its own copy of the
#      helper (the inner scripts run as a separate powershell.exe from a
#      file, so the wrapper's copy is never in scope for them), and the
#      helper checks $LASTEXITCODE.
#   2. With pwsh, when installed: each script's helper, lifted out by the
#      PowerShell parser, throws on exit 1 with the command's output in
#      the message, and does not throw on exit 0 even when the command
#      writes to stderr under $ErrorActionPreference = 'Stop'.
#
# Not proven here: the behaviour under Windows PowerShell 5.1 on the DC,
# which is what actually runs these scripts. pwsh 7 on the Mac is the
# closest stand-in available offline.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AD_DIR="${REPO_ROOT}/scripts/ad"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
# shellcheck source=tests/lib/asserts.sh
source "${REPO_ROOT}/tests/lib/asserts.sh"

# The expected number of Invoke-Native call sites per script: the six
# raw calls the review found, with the five Set-CaRegistry calls in
# 20-install-ca.ps1 routed through one call inside that function.
expected_calls() {
  case "$1" in
    20-install-ca) echo 3 ;;
    30-create-identities) echo 2 ;;
    run-as-admin) echo 1 ;;
  esac
}

# 1. Static checks.
for ps in 20-install-ca 30-create-identities run-as-admin; do
  file="${AD_DIR}/${ps}.ps1"
  # certutil -ping is the CA readiness probe: it is expected to fail until
  # the service answers, so it is the one raw call allowed, by design.
  raw="$(grep -E '&[[:space:]]+(certutil|dsacls|icacls)\.exe' "${file}" | grep -vc 'certutil.exe -ping' || true)"
  assert_eq "${ps}: no raw native call outside the helper (certutil -ping excepted)" "0" "${raw}"
  if [[ "${ps}" == "20-install-ca" ]]; then
    assert_contains "${ps}: waits for the CA to answer before publishing the CRL" "certutil.exe -ping" "$(cat "${file}")"
    ping_line="$(grep -n 'certutil.exe -ping' "${file}" | head -1 | cut -d: -f1)"
    crl_line="$(grep -n "Invoke-Native certutil.exe '-crl'" "${file}" | head -1 | cut -d: -f1)"
    assert_eq "${ps}: the ping wait precedes the CRL publish" "yes" "$([[ "${ping_line}" -lt "${crl_line}" ]] && echo yes || echo no)"
  fi
  defs="$(grep -c '^function Invoke-Native' "${file}" || true)"
  assert_eq "${ps}: carries its own Invoke-Native" "1" "${defs}"
  calls="$(grep -cE '^[[:space:]]+Invoke-Native ' "${file}" || true)"
  assert_eq "${ps}: every native call goes through Invoke-Native" "$(expected_calls "${ps}")" "${calls}"
  # A bare dash flag such as -setreg is read by PowerShell's binder as one
  # of the helper's own parameters (a bare -c binds to -Command), so every
  # dash flag handed to a native command must be quoted.
  bare="$(grep -cE '^[[:space:]]+Invoke-Native [^ ]+ .*[[:space:]]-[A-Za-z]' "${file}" || true)"
  assert_eq "${ps}: dash flags to native commands are quoted" "0" "${bare}"
# The $LASTEXITCODE and $Command below are PowerShell source text
# being searched for, on purpose.
# shellcheck disable=SC2016
  assert_contains "${ps}: helper checks the exit code" 'if ($LASTEXITCODE -ne 0)' "$(cat "${file}")"
  # shellcheck disable=SC2016
  assert_contains "${ps}: helper invokes through the call operator" '& $Command @Arguments' "$(cat "${file}")"
done

# 2. Behaviour, with pwsh. The probe lifts the function out of the script
#    by AST so the script's param block and side effects never run.
if ! command -v pwsh >/dev/null 2>&1; then
  echo "[WARN]  pwsh not installed, Invoke-Native behaviour not checked"
  finish "test_ad_powershell"
fi

cat > "${TMP}/probe.ps1" <<'PS'
param([string]$Script, [string]$Case)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-Native' }, $false)
if ($null -eq $fn) { exit 9 }
Invoke-Expression $fn.Extent.Text
$ErrorActionPreference = 'Stop'
try {
    switch ($Case) {
        'fails' { Invoke-Native sh '-c' 'echo boom >&2; exit 1'; exit 2 }
        'succeeds' { Invoke-Native sh '-c' 'exit 0' }
        'stderr-ok' { Invoke-Native sh '-c' 'echo warning >&2; exit 0' }
    }
}
catch {
    if ($Case -eq 'fails' -and $_.Exception.Message -match 'failed \(1\)' -and $_.Exception.Message -match 'boom') { exit 0 }
    Write-Output $_.Exception.Message
    exit 3
}
if ($Case -eq 'fails') { exit 2 }
if ($ErrorActionPreference -ne 'Stop') { exit 4 }
exit 0
PS

for ps in 20-install-ca 30-create-identities run-as-admin; do
  file="${AD_DIR}/${ps}.ps1"
  for case in fails succeeds stderr-ok; do
    rc=0
    out="$(pwsh -NoProfile -NonInteractive -File "${TMP}/probe.ps1" -Script "${file}" -Case "${case}" 2>&1)" || rc=$?
    case "${case}" in
      fails) label="throws on exit 1 with the output in the message" ;;
      succeeds) label="does not throw on exit 0" ;;
      stderr-ok) label="does not throw on exit 0 with stderr output, and restores 'Stop'" ;;
    esac
    if [[ "${rc}" -eq 0 ]]; then
      echo "[OK]    ${ps}: Invoke-Native ${label} (pwsh 7, not Windows PowerShell 5.1)"
    else
      echo "[FAIL]  ${ps}: Invoke-Native ${label}: probe exit ${rc}: ${out}"; failures=$((failures + 1))
    fi
  done
done

finish "test_ad_powershell"
