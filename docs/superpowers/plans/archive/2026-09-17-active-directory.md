# Active Directory implementation plan

> Executed on 2026-09-17: `terraform/ad`, `scripts/24-ad-up.sh`,
> `scripts/46-ad-down.sh`, and the three PowerShell scripts merged in
> PR #18, the DC was built, and ISE joined the domain the same night.
> Eight of the fourteen boxes below were ticked at the time and the rest
> were not; `docs/STATUS.md` is the record of what shipped. See ADR 0010,
> `docs/AD.md` for the concepts, and `docs/ISE-AD-BUILD.md` for the
> runbook.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A disposable Windows Server domain controller beside ISE, built by one command, with a forest, DNS, an Enterprise Root CA, and lab identities from a tracked CSV.

**Architecture:** A fourth Terraform root, `terraform/ad`, local state, session lifetime (ADR 0010). It takes its network and tag values from the persistent root at apply time. Three idempotent PowerShell scripts under `scripts/ad/` are delivered as three ordered run commands. Two bash scripts wrap apply and destroy in the kit's usual style.

**Tech Stack:** Terraform azurerm ~> 4.0 and random ~> 3.6, Windows PowerShell 5.1 on the DC, bash 3.2 on the Mac, `az vm run-command` for the readiness checks.

Spec: `docs/superpowers/specs/2026-09-13-active-directory-session-design.md` (revised 2026-09-17).

## Global Constraints

- Domain `corp.rooez.com`, NetBIOS `CORP`, DC `dc1` at `10.20.2.10` on `snet-apps`, CA `corp-rooez-CA`, local admin `labadmin`.
- No public IP on the DC. Nothing from the internet is admitted.
- No port policy between ISE and the DC: the whole apps subnet on every port (operator, 2026-09-17).
- VM size `Standard_B2ms`. `B2as_v2` and the DSv5 fallback have zero quota in this subscription.
- No secret in a tracked file, on a command line, or in output. Passwords are `random_password`, reach the VM as protected parameters, and reach the Mac only as `config/mcp-env/ad.env`, mode 0600.
- Bash: `set -euo pipefail`, bash 3.2, functions under 40 lines, `[OK]` `[WARN]` `[FAIL]`. PowerShell: strict mode, stop on error, a transcript under `C:\lab\log`, a guard that makes a rerun safe.
- Never `terraform apply` or `destroy` without the operator's word (CLAUDE.md).

## Where this plan departs from the spec, and why

| Spec | Plan | Reason |
|---|---|---|
| Two run commands, the second carrying two scripts concatenated | Three run commands | Each script opens with `param()`, which PowerShell accepts only first in a file |
| Run commands as delivered (SYSTEM) | CA and identities run as `CORP\labadmin` | An Enterprise CA needs Enterprise Admins; SYSTEM on a DC is the machine account |
| DNS forwarder set by the promotion script | Set by the CA script, after the reboot | The DNS service is not reliably up between feature install and reboot |
| NSG admits a list of directory ports from `VirtualNetwork` | NSG admits the apps subnet on every port | Operator's direction; the port list never restricted anything anyway, since the default rule already allows the VNet |
| `Standard_B2as_v2` | `Standard_B2ms` | Quota |
| `27-ad-ca.sh`, a preflight quota check, ISE walkthrough edits | Deferred | Not needed to stand the domain up; each is small and is added when ISE is joined |

## File map

| Path | Responsibility |
|---|---|
| `terraform/ad/{versions,providers,variables,main,outputs}.tf` | The root: NSG, NIC, VM, four passwords, three run commands, outputs |
| `scripts/ad/10-promote-forest.ps1` | Roles, `Install-ADDSForest`, delayed reboot |
| `scripts/ad/20-install-ca.ps1` | Wait for the directory, DNS forwarder, Enterprise Root CA, SAN flag, template enroll right |
| `scripts/ad/30-create-identities.ps1` | Groups and users from the CSV, `svc-ise` and its delegation, ISE's A and PTR records |
| `config/ad-identities.csv` | The tracked identities |
| `scripts/24-ad-up.sh` | init, apply, `ad.env`, three checks, the ISE form values |
| `scripts/46-ad-down.sh` | destroy, remove `ad.env` |
| `tests/test_ad_dry_run.sh`, `tests/stubs/terraform` | Dry runs, the env file's mode and silence, PowerShell static and parse checks |
| `docs/decisions/0010-...md`, `docs/AD.md`, `config/tunnels.conf.example` | The decision, the concepts document (the runbook is `docs/ISE-AD-BUILD.md`), the RDP forward |

### Task 1: The Terraform root

- [x] Write `terraform/ad/*.tf` as in the file map.
- [x] `terraform -chdir=terraform/ad fmt -check` and `validate`. Expected: `Success! The configuration is valid.`

### Task 2: The PowerShell

- [x] Write the three scripts, taking the forest call from `cfn-ps-microsoft-activedirectory/scripts/archive/Install-ADDSForest.ps1` and the CA call and `certutil` block from `cfn-ps-microsoft-pki/scripts/archive/Invoke-EnterpriseCaConfig.ps1`.
- [x] Parse each with `pwsh` (no execution). Expected: three `parses` lines.

### Task 3: The operator scripts and their test

- [x] Write `tests/test_ad_dry_run.sh` and the `terraform/ad` case in the stub.
- [x] Write `scripts/24-ad-up.sh` and `scripts/46-ad-down.sh`; the down script sources the up script for `ad_tf_args`, so destroy is given exactly what apply was.
- [x] `bash tests/test_ad_dry_run.sh`. Expected: `test_ad_dry_run: all passed`.

### Task 4: Documents, gate, commit

- [x] ADR 0010, `docs/AD.md`, the tunnels example.
- [ ] `tests/run.sh && pre-commit run --all-files`, one commit, push, PR.
- [ ] **Operator-gated:** `CLAUDE.md` names the repo layout, the commands, and what is in scope. It needs `terraform/ad`, `scripts/ad/`, `24-ad-up.sh`, `46-ad-down.sh`, and Active Directory added. Editing that file is a stop-and-ask.

### Task 5: The live build (operator-gated)

- [ ] `scripts/24-ad-up.sh`. About twenty minutes. Expected: three `[OK]` checks and the two ISE form values.
- [ ] If a run command fails, read its message in the apply error, fix, and rerun the script; the scripts skip finished work.
- [ ] `terraform -chdir=terraform/persistent plan` shows no changes.
- [ ] STATUS entry.

## Risks

- A run command that starts in the seconds before the promotion reboot is killed by it. The CA script waits up to twenty minutes for the directory, and a rerun of the up script recovers.
- A transcript on the DC may record a protected parameter in its header. The DC is admin only and lives for one session.
- Windows stays unactivated in its grace period for the life of a session. Accepted in the spec.
