# 0010: A fourth Terraform root, session lifetime, for Active Directory

Status: accepted, 2026-09-17

## Context

ISE needs a directory to authenticate real users against, a DNS server for
internal names, and a certificate authority for its EAP and admin
certificates. One Windows Server domain controller covers all three. ADR
0002 sorted everything the kit builds into three roots by lifetime:
bootstrap and persistent are never destroyed, the CML VM is rebuilt every
session. A domain controller fits none of them. It must not be persistent,
because the operator rejected a second disk that bills every month, and it
does not belong in the cloud-cml fork, which builds one VM from upstream's
module.

## Decision

`terraform/ad` is a fourth root with local state and the lifetime of a
session: `scripts/24-ad-up.sh` builds it before the ISE portal deploy, and
`scripts/46-ad-down.sh` destroys it after `scripts/45-ise-down.sh`. It
creates one Windows Server 2025 VM, `dc1`, at 10.20.2.10 on `snet-apps`
beside ISE, with no public IP. Everything durable it depends on, the
resource group, the subnet, the tags' owner and review date, comes from the
persistent root's outputs and tfvars at apply time, so the two roots cannot
disagree and this one never recreates network resources.

Three PowerShell scripts under `scripts/ad/` promote the forest
`corp.rooez.com`, install an Enterprise Root CA, and create lab identities
from the tracked `config/ad-identities.csv`. Terraform delivers each as its
own run command, in order. The forest and CA cmdlets and values are taken
from the operator's AWS Quick Start forks, with the AWS wrapping removed.

Between ISE and the DC there is no port policy, by the operator's choice:
a domain join, Kerberos, LDAP, RPC, and certificate enrollment use too many
ports to list usefully in a lab. The DC's NSG allows the whole apps subnet
on every port. Azure's default rules would already permit that; the rule
states the intent so a later deny cannot cut ISE off by accident. Nothing
from the internet reaches the DC.

## Consequences

- The directory is a prerequisite for ISE, not a companion. ISE's DNS
  domain is `corp.rooez.com` and its name server is the DC, so that every
  lab name resolves in one place. The scripts are numbered in that order,
  the ISE walkthrough refuses to start without it in words, and
  `25-ise-up.sh` warns when it finds no directory.

- The domain, its users, and its CA are rebuilt from tracked data each
  session. Nothing about them is precious, and nothing bills between
  sessions.
- Four passwords live in this root's local state file, protected only by
  `.gitignore` and the Mac's disk. That is a narrower guarantee than the
  persistent root's blob state (ADR 0004), accepted because the root and
  everything it protects end with the session.
- Lab nodes can reach the DC at their own addresses. The `VirtualNetwork`
  tag on a NIC in `snet-apps` includes the lab summary, because that subnet
  carries the route for it (ADR 0003 amendment). A domain-joined endpoint
  inside CML therefore works without another rule.
- The VM size is `Standard_B2ms`. The size first chosen, `B2as_v2`, and its
  fallback both sit in families with no quota in this subscription.
- Run commands execute as SYSTEM by default, which on a DC is only the
  machine account. The CA and identity scripts run as the domain
  administrator instead, since an Enterprise CA needs Enterprise Admins.

## Options considered

1. A persistent DC with its own disk. Rejected by the operator: a second
   monthly bill for something a script rebuilds in twenty minutes.
2. Microsoft Entra Domain Services. Rejected: a managed domain costs more
   per month than this whole lab and cannot host an Enterprise CA.
3. Samba as the directory, in CML. Rejected: the point is to show ISE
   against the Active Directory a customer runs.
4. A disposable Windows VM in its own root. Chosen.

## Amendment, 2026-09-17: the DC allows the legacy SAM password change methods

The decision stands. One setting on the DC was not foreseen, and it lowers a
Windows Server 2025 default, so it is recorded here.

ISE could not join the domain. A Server 2025 domain controller refuses the
legacy SAM RPC password change methods when they are called remotely, and
ISE uses one of them during a join, which then ends in "Access is denied",
error code 5. Cisco describes this in Field Notice FN74321 (regression bug
CSCwr77017), for ISE 3.1 through 3.4 P1. Our ISE is 3.5.0.527, which the
notice does not list, so it was proven and not assumed: with SAM's
logging-only audit value turned on, the DC recorded `ISE1$` at 10.20.2.20
calling `SamrUnicodeChangePasswordUser2`, one of the three blocked methods,
during the join.

`dc1` therefore carries Cisco's workaround, the policy "Configure SAM change
password RPC methods policy" set to allow all methods:
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SAM`, DWORD
`SamrChangeUserPasswordApiPolicy` = 3. The operator approved it on
2026-09-17. The DC reads the value at startup, so
`scripts/ad/10-promote-forest.ps1` sets it before the promotion reboot. On
the DC of that day it was set by hand and took effect only after a restart,
after which the join succeeded.

The risk accepted: the DC again accepts the older password change methods,
whose encryption is weaker, as Server 2022 and earlier did by default. The
bounds: `dc1` has no public address, and nothing from the internet reaches
it. What does reach it, on every port, is the whole VNet and every lab node
in 10.100.0.0/16. Azure's `AllowVnetInBound` default admits the VNet, and
because `snet-apps` carries the route for the lab summary (ADR 0003
amendment), the lab range counts as VNet on that subnet. The two custom
allow rules in `terraform/ad/main.tf` narrow nothing; they only state the
intent, as `docs/LESSONS-LEARNED.md` explains under "An NSG's custom allow
rules never narrow anything by themselves". Since CML has peer and student
accounts, "lab nodes" includes other people's. The residual risk is
accepted for a session-lifetime lab in which every password in the domain
is generated and the DC is destroyed with the session. The 2026-09-17
architecture review recommends one deny rule for 3389 from the VNet, with
the CML host excepted, so that the RDP rule means something; that is not
yet in the code.

Alternatives rejected:

1. A Windows Server 2022 image. It would join without the setting, and it
   would no longer match the Server 2025 environment the lab is there to
   model. Finding this problem is part of what the lab is for.
2. No Active Directory. It blocks the lab's purpose, which is ISE against
   the directory a customer runs.

Exit condition: an ISE 3.5 release or patch that fixes CSCwr77017. When the
lab's ISE runs it, remove the value from `10-promote-forest.ps1` and confirm
a join on a fresh DC. A customer with a Server 2025 domain faces the same
choice, this setting or a fixed ISE.
