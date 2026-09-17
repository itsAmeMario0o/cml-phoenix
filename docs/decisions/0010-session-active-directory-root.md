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
