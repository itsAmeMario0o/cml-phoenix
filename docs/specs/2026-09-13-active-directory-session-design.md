# Active Directory for the ISE session

Status: shipped (2026-09-17, built by `scripts/24-ad-up.sh` and joined
by ISE the same night, then torn down with the session; see ADR 0010,
`docs/AD.md`, `docs/ISE-AD-BUILD.md`). Written 2026-09-13, revised
2026-09-17 to match what the week's live work settled; the section "What
changed on 2026-09-17" lists the differences.

ISE needs a DNS server it can trust for internal names, an identity store to
authenticate lab users against, and a certificate authority to sign its
admin and EAP certificates. One Windows Server VM running Active Directory
Domain Services covers all three. This spec adds that VM as a disposable
Terraform root that is built before ISE and destroyed after it, so that no
disk, no domain, and no certificate outlives a session.

## What changed on 2026-09-17

The first draft was written before ISE had ever been deployed or the routed
path proven. Six things it assumed are now known to be otherwise:

- **ISE is reached through the CML host, not its public IP.** The kit's NSG
  admits 443 and 22 to ISE from the CML host's address only, the GUI is an
  SSH forward (`ise 8443 10.20.2.20 443` in `config/tunnels.conf`), and the
  ISE CLI answers key-based SSH through the same jump. The draft's plan to
  open ISE to the operator's addresses is dropped.
- **`scripts/25-ise-up.sh --post-deploy` already exists** and has run
  against real ISE twice. This spec no longer adds it, only relies on it.
- **An ISE is already running with a public resolver.** The portal form is
  still the supported way to point ISE at the DC, on the next deploy. A
  running ISE can be repointed from its CLI (`ip name-server`,
  `ip domain-name`), at the cost of an application restart.
- **ISE's host name is `ise1`.** The DNS record this spec creates is
  `ise1.corp.rooez.com`, not `ise`.
- **Lab nodes can reach the apps subnet at their own addresses.** The
  routed path works (ADR 0003 and its 09-17 amendment), so a lab endpoint
  can reach the DC. The draft said nothing in the lab would talk to it;
  a domain-joined Windows endpoint in CML now could, and should be able to.
- **The CA does not need the subject alternative name flag.** The draft had
  the CA script set `EDITF_ATTRIBSUBJECTALTNAME2`, on the belief that a
  Windows CA strips SANs from a request. It does not strip SANs that are
  inside the CSR when the template takes its subject from the request, as
  `WebServer` does, and that is how ISE sends them. The flag is an
  escalation path and Server 2025's `certutil` rejects its name. Dropped.
- **802.1X is proven with ISE's internal users** (PEAP from a Linux
  supplicant, MAB, CoA). AD replaces the identity store behind a working
  path; it is no longer a prerequisite for proving the path.

Nothing about the lifetime, the domain name, the VM, the three scripts, or
the delivery method changed.

## Context

The ISE portal deploy asks for a DNS server and a domain name. The current
walkthrough enters a public resolver and `rooez.com`, which gets ISE booted
but leaves it unable to resolve anything inside the VNet and with no
directory to join. The TrustSec Phase 1 lab authenticates its `test aaa`
check against an ISE internal user because there was nothing else to
authenticate against.

The operator has built this before on AWS with the Quick Start PowerShell
(the `cfn-ps-microsoft-pki` module and the `quickstart-microsoft-utilities`
scripts) and wants the same experience here: the VM boots, the scripts run,
and a working domain with DNS and a CA is there when they log in. Both repos
were read for this spec. Neither contains a forest install; the PKI module
configures a CA on a server that is already domain joined, and the utilities
repo is deprecated one-line wrappers around `Add-Computer` and
`Set-DnsClientServerAddress`. The CA function in the PKI module is plain
Windows cmdlets with CloudFormation signals, Secrets Manager reads, and S3
CRL publishing wrapped around them. The cmdlet choices and hardening values
carry over. The wrapping does not.

The operator does not want anything long lived. The existing rule is that
only `terraform/persistent` survives a rebuild, and that root holds one
512 GB disk that already bills every month. A second persistent disk for a
domain controller was rejected. The DC is rebuilt from scratch with ISE each
time, and the identities it holds are populated after the build from tracked
data, the same way ISE will be under the ISEEE approach on the roadmap.

## Goal and scope

In scope:

- A new Terraform root, `terraform/ad/`, with local state, that creates one
  Windows Server 2025 VM on the existing apps subnet with an NSG and no
  public IP.
- Three PowerShell scripts under `scripts/ad/` that promote the forest,
  install the CA, and create the lab identities. Terraform delivers them to
  the VM with run commands.
- The domain `corp.rooez.com`, NetBIOS `CORP`, with the DC as its only DNS
  server, forwarding everything else to Azure's resolver.
- A one tier Enterprise Root CA on the DC, named `corp-rooez-CA`.
- A tracked CSV of lab users and groups in a Nintendo theme, plus one
  service account for ISE to join the domain with.
- Operator scripts `24-ad-up.sh`, `46-ad-down.sh`, and `27-ad-ca.sh`, with
  dry run tests, and a concepts document, `docs/AD.md` (the runbook is
  `docs/ISE-AD-BUILD.md`).
- Changes to the ISE walkthrough so ISE is deployed with the DC as its DNS
  server and `corp.rooez.com` as its domain, and a short procedure for
  repointing an ISE that is already running. `scripts/25-ise-up.sh
  --post-deploy` is used as it stands.
- A `dc` line in `config/tunnels.conf.example` for RDP through the CML
  host.
- ADR 0010 for a fourth root with session lifetime.

Out of scope, each with its own item on the roadmap or in a later spec:

- Joining ISE to the domain and enrolling its certificate from code. This
  round documents both as manual steps in the ISE walkthrough, with the CA
  helper doing the signing. The `cisco.ise` Ansible item on the roadmap
  automates them.
- A second domain controller, organizational units, group policy, a two tier
  CA, or CRL publishing anywhere but the DC itself.
- Pester unit tests and continuous integration in GitHub. Lint runs locally.
  CI is out of scope per `CLAUDE.md` until it has a spec, and it goes on the
  roadmap as its own item.
- Azure Bastion as a Terraform resource. The free Developer SKU deploys
  itself from the portal on first use and needs nothing from this repo.

## Architecture

### The virtual machine

One `azurerm_windows_virtual_machine` named `dc1`, size `Standard_B2as_v2`
(2 vCPU, 8 GB), image `MicrosoftWindowsServer:WindowsServer:
2025-datacenter-azure-edition-smalldisk:latest`, on a 32 GB Standard SSD OS
disk. No data disk. A static private address `10.20.2.10` on `snet-apps`,
which the persistent root already owns. The apps subnet's route table sends
the lab summary toward the CML host, so the DC, like ISE, can answer a lab
node at its own address. That is wanted: a domain-joined endpoint inside
CML needs DNS, Kerberos, and LDAP from the DC.

The size is a burstable one because a lab domain controller idles. If the
subscription's quota for that family is zero, `Standard_D2s_v5` is the
fallback and the variable is the only change.

The VM has no public IP and no NAT gateway. It does not need an internet
route: both roles are in the image, the scripts use cmdlets that ship with
Windows, and the DNS forwarder target `168.63.129.16` is Azure's link local
resolver, which answers public names for any VM in the VNet. The one thing
this costs is Windows activation, which stays in its grace period for the
life of a session. That is accepted.

Local administrator is `labadmin`. Its password is twelve characters of
mixed case letters and digits, which is Azure's minimum for a Windows admin
and easy to type at an RDP prompt. The operator can set their own in the
gitignored tfvars instead.

### Network rules

The NSG on the DC NIC admits, from the `VirtualNetwork` service tag only:
DNS 53 on both protocols, Kerberos 88 on both, RPC endpoint mapper 135, NTP
123, LDAP 389 on both, SMB 445, LDAPS 636, global catalog 3268 and 3269, the
RPC dynamic range 49152 to 65535, and RDP 3389. The default rules deny
everything else inbound. Nothing from the internet reaches the DC on any
port.

`VirtualNetwork` means more here than the VNet's own prefix. Azure expands
that tag per NIC from the NIC's effective routes, and `snet-apps` carries
the route for the lab summary, so on the DC's NIC the tag includes
`10.100.0.0/16` (LESSONS-LEARNED, 2026-09-17; visible under `tagMap` in
`az network nic list-effective-nsg`). Lab endpoints are therefore admitted
on the directory ports by the same rules, on purpose. The forward leg needs
nothing new either: the CML NIC's `lab-transit-out` rule already allows the
lab summary to the apps subnet on any port.

RDP from inside the VNet covers the one supported path: an SSH forward
through the CML host that `scripts/50-tunnels.sh` already manages, the same
pattern the kit uses for every other lab VM. Azure Bastion is out of scope
per `CLAUDE.md` and this design does not depend on it. An operator who wants
a browser RDP session can turn on the free Developer SKU from the portal on
their own initiative; it needs no subnet and nothing from this repo, but
nothing here assumes it is there. `docs/AD.md` documents the SSH forward
only.

### ISE reachability

Unchanged from how the kit works today. ISE keeps the Standard public IP its
Marketplace deploy creates, used only for outbound to Security Cloud Control
and Entra. The NSG `scripts/25-ise-up.sh` attaches admits RADIUS from the
lab summary and 443 and 22 from the CML host alone. The operator reaches the
GUI through the `ise` SSH forward and the CLI by key through the same jump.
The DC is reached the same way: a `dc 3389 10.20.2.10 3389` forward and an
RDP client pointed at `localhost`.

### The three scripts

Each script is short, has a plain prose header saying what it does and why,
runs under strict mode with `$ErrorActionPreference = 'Stop'`, writes a
transcript to `C:\lab\log\<script>.txt`, and checks its own state before
acting so a rerun skips finished work. Functions stay under 40 lines. There
is no shared module; three files that a reader can hold in their head beat
one library.

`10-promote-forest.ps1` installs the `AD-Domain-Services` and `DNS` features,
runs `Install-ADDSForest` for `corp.rooez.com` with the restore mode
password, sets the DNS forwarder to `168.63.129.16`, and schedules a reboot
fifteen seconds after it exits. If the machine is already a domain
controller it logs that and exits. It returns before the reboot so the run
command completes cleanly.

`20-install-ca.ps1` waits up to ten minutes for `Get-ADDomain` to answer,
which is the signal that the reboot finished and the directory is up. It
installs `ADCS-Cert-Authority` and runs
`Install-AdcsCertificationAuthority` as an Enterprise Root CA with the
values taken from the PKI module: SHA256, RSA 4096, the Microsoft Software
Key Storage Provider, five year validity, and a common name of
`corp-rooez-CA`. It then sets the CRL overlap to twelve hours and the audit
filter to 127 with `certutil -setreg`, points the CRL and AIA URLs at the
DC's own `CertEnroll` share, publishes the first CRL, and restarts the CA
service. If the CA role is already installed it logs that and exits. The
built in `WebServer` template is what ISE's certificate is issued from, but
a Windows CA strips subject alternative names from a request by default, so
the script also sets `EDITF_ATTRIBSUBJECTALTNAME2` with `certutil -setreg
policy\EditFlags` and restarts the CA service a second time. Without that
flag ISE's SAN never survives signing, no matter what the request asks for.

`30-create-identities.ps1` takes the CSV content as a parameter, creates the
groups it names, creates each user with the shared lab password and adds it
to its groups, creates `svc-ise` with its own password and delegates it the
right to create computer objects in the default Computers container, and
adds the `ise1` A record at `10.20.2.20`, matching the host name the ISE
walkthrough uses, plus the reverse zone for `10.20.2.0/24`. Every step is skipped when its object already exists.

### Delivery to the VM

Two `azurerm_virtual_machine_run_command` resources, `promote` and
`configure`. The first carries `10-promote-forest.ps1` inline from `file()`.
The second carries `20-install-ca.ps1` and `30-create-identities.ps1`
concatenated in order and depends on the first. Passwords and the CSV travel
as `protected_parameter` values, which Azure does not return in the
resource's output and Terraform marks sensitive. The run command output,
which includes each script's transcript, is captured by Terraform so a
failed apply shows the cause.

A run command whose script has already completed is not re-run by a second
apply unless its content changes, which is what a rerun after a partial
failure needs: the scripts themselves are the idempotency layer, the run
command is the transport.

### DNS

The forest install makes the DC authoritative for `corp.rooez.com` and
points its own DNS client at itself. Nothing at VNet level changes: the
VNet keeps Azure DNS as its default, so the CML host and every future VM
resolve as they do today. ISE uses the DC because its portal form gets
`10.20.2.10` as the primary name server and `corp.rooez.com` as the domain,
which makes it `ise1.corp.rooez.com`. An ISE that is already running with a
public resolver is repointed from its CLI with `ip name-server 10.20.2.10`
and `ip domain-name corp.rooez.com`; ISE restarts its application for
either, about fifteen minutes, and a changed domain name means a new
self-signed certificate, which the CA step replaces anyway. A lab endpoint
that joins the domain points its own DNS at the DC the same way. Public names ISE needs, Security Cloud
Control and Entra among them, resolve through the forwarder.

`lab.rooez.com` is the Cloudflare front door and lives in the public zone.
A child zone at `corp.` does not shadow it, which is why the domain is not
the apex.

### The identities

`config/ad-identities.csv` is tracked, with columns `username`, `display`,
and `groups`, where `groups` is a semicolon separated list:

| username | display | groups |
|---|---|---|
| mario | Mario Mario | Mushroom-Kingdom |
| luigi | Luigi Mario | Mushroom-Kingdom |
| peach | Princess Peach | Mushroom-Kingdom |
| yoshi | Yoshi | Mushroom-Kingdom |
| bowser | Bowser Koopa | Koopa-Troop |

`Mushroom-Kingdom` is the employees group and `Koopa-Troop` the contractors
group when ISE authorization rules need one of each. `mario` is the TrustSec
`test aaa` user. `svc-ise` is created by the script, not the CSV, because it
is a service account with a different password and a delegation, and a
reader should not have to know that one CSV row is special.

## Secrets

Terraform generates four `random_password` values: the local admin (twelve
alphanumeric characters), directory services restore mode, `svc-ise`, and
the shared lab user password (the last three 24 characters with symbols).
All four are `sensitive` outputs. `24-ad-up.sh` writes them to
`config/mcp-env/ad.env`, mode 0600, gitignored by the existing `mcp-env/`
rule, as `AD_ADMIN_PASSWORD`, `AD_SVC_ISE_PASSWORD`, and
`AD_LAB_USER_PASSWORD`, plus `AD_DOMAIN`, `AD_DC_IP`, and `AD_NETBIOS` for
scripts that need them. The restore mode password is never written out;
nothing outside the VM needs it.

The local state file holds the four passwords, generated with the same
`random_password` pattern ADR 0004 established, but as this root's local
state rather than the persistent root's blob state that ADR 0004 actually
uses for CML's admin passwords. That is a narrower guarantee: no Azure AD
authentication, versioning, or soft delete behind it, only `.gitignore` and
the Mac's disk. It is accepted because the root itself, and everything it
protects, does not outlive the session.

`TRUSTSEC_TEST_USERNAME` becomes `mario` and `TRUSTSEC_TEST_PASSWORD` is read
from `AD_LAB_USER_PASSWORD` once ISE authenticates against the domain. Until
then the ISE internal user path still works and the env example says so.

## Operator flow

1. `scripts/24-ad-up.sh`. Runs `terraform init` and `apply` in
   `terraform/ad/` with `-auto-approve` only under `ASSUME_YES=1`, writes
   `ad.env`, runs the three readiness checks below, and prints the two values
   the ISE portal form needs: primary name server `10.20.2.10` and domain
   `corp.rooez.com`. About fifteen minutes end to end, most of it the
   Windows first boot and the reboot after promotion.
2. The ISE portal deploy, per `docs/ISE-AD-BUILD.md (Part 2)`, with those
   two values entered.
3. `scripts/25-ise-up.sh --post-deploy`, unchanged: the NSG, tagging,
   readiness, and policy steps. Then `scripts/50-tunnels.sh up` for the
   `ise` and `dc` forwards.
4. In the ISE GUI, by hand this round: import the root CA certificate that
   `scripts/27-ad-ca.sh export-root` saved to
   `config/mcp-env/ad-root-ca.cer`, generate a CSR, sign it with
   `scripts/27-ad-ca.sh sign <csr file>`, bind the result, and join the
   domain as `svc-ise`. The walkthrough gains a section with these steps.
5. Labs as today.
6. Teardown: `scripts/45-ise-down.sh` first, then `scripts/46-ad-down.sh`,
   which runs `terraform destroy` in `terraform/ad/` and removes `ad.env`
   and the exported certificate. ISE goes first because it depends on the
   DC; the script numbers follow that same order so a reader cannot run
   them the wrong way round by pattern-matching the numbering everywhere
   else in `scripts/`.

`27-ad-ca.sh` is two subcommands over `az vm run-command invoke`, so it
needs no network path to the DC. `export-root` runs `certutil -ca.cert` on
the DC and saves the base64 output. `sign` sends the CSR as a parameter,
runs `certreq -submit -attrib "CertificateTemplate:WebServer"` and
`certreq -retrieve`, and saves the signed certificate beside the CSR.

## Verification

`24-ad-up.sh` ends with three checks over run commands, each printing `[OK]`
or `[FAIL]` in the kit's style:

1. `Get-ADDomain` returns `corp.rooez.com`.
2. `Resolve-DnsName dc1.corp.rooez.com` and `Resolve-DnsName
   login.microsoftonline.com` both answer through the DC, which proves the
   zone and the forwarder.
3. `certutil -ping` reaches `corp-rooez-CA`.

After a real build, the manual proof is an RDP session through the CML host
SSH forward as `labadmin`, then ISE resolving `dc1.corp.rooez.com` from its
CLI, then the TrustSec `test aaa` as `mario` returning Access-Accept once
ISE is joined. The pyATS TrustSec verification already asserts the last of
those and only needs its credentials pointed at `ad.env`.

## Testing

Local, in `tests/run.sh`:

- `terraform fmt -check` and `terraform validate` on `terraform/ad/`, added
  to the existing loop over roots.
- PSScriptAnalyzer over `scripts/ad/*.ps1` with the default rule set, run
  through `pwsh` when it is on the path and skipped with `[WARN]` when it is
  not, the same rule the verify venv follows. PowerShell 7.5 is already on
  the Mac; the analyzer module is not, and installing it is a human gated
  step the plan calls out.
- Bash dry run tests for `24-ad-up.sh`, `46-ad-down.sh`, and `27-ad-ca.sh`
  against the existing `terraform` and `az` stubs, asserting the commands
  they would run and that `ad.env` is written with mode 0600 and never
  echoed.
- `shellcheck` and `bash -n` as for every script.

The PowerShell is not unit tested on the Mac. Its correctness is proven by
the three live checks and by the transcripts a failed apply returns. Pester
is a roadmap item alongside CI.

## Risks

- The `B2as_v2` family may have zero quota, as `Edsv5` did in September.
  Preflight gains a check for the family, and the size is a variable.
- A run command's inline script has a size limit of 256 KB. Three scripts of
  a few hundred lines are far under it.
- If Azure retires the `smalldisk` SKU the image reference is one variable.
- ISE's `test aaa` against AD depends on ISE being joined, which is manual
  this round. The verification keeps working against the ISE internal user
  `trustsec-verify` until then.
- `46-ad-down.sh` must not copy the first `45-ise-down.sh`: az 2.89 rejects
  `--tag` together with `--resource-group`. This root is Terraform, so
  `terraform destroy` is the teardown and no tag query is needed.
- Changing an NSG from this session's tooling is refused by its classifier.
  That does not bite here, because the DC's NSG is a Terraform resource and
  `terraform apply` is the operator's step in any case.

## Open questions

The lifetime, domain name, deploy method, identity scope, and script source
were each decided with the operator on 2026-09-13. Two are open after the
2026-09-17 revision:

- Settled 2026-09-17: ISE's domain is `corp.rooez.com` and its name server
  the DC, and the DC is a prerequisite for any ISE deploy. What remains
  open is only the ISE already running that day: repoint it from its CLI
  now, or let the next deploy start right.
- Whether a Windows endpoint inside CML is wanted as the domain-joined
  client. CML 2.10's node definitions support UEFI with Secure Boot
  firmware, an emulated TPM 2.0, and a VNC console, so Windows 11 runs
  there; it would be the natural consumer of this directory and the CA for
  machine and user 802.1X. It would be its own small spec, after this one.
