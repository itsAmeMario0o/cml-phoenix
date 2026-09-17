# ISE and Active Directory

Two servers sit side by side on the apps subnet and between them answer the
lab's identity questions. ISE decides who and what gets on the network.
Active Directory is where the people are, and it also runs the two services
ISE leans on: DNS and a certificate authority. This document explains how
the directory is built, what runs on it, who is in it, and how ISE uses it.

Both are disposable. Neither holds anything that a script and a tracked file
cannot rebuild, and neither bills between sessions. The decisions behind that
are ADR 0008 for ISE and ADR 0010 for the directory.

    snet-apps 10.20.2.0/24
    +---------------------------+        +---------------------------+
    | dc1         10.20.2.10    |        | ise1        10.20.2.20    |
    | Windows Server 2025       | <----> | ISE 3.5, evaluation       |
    | AD DS, DNS, AD CS         |  any   | RADIUS, profiling,        |
    | corp.rooez.com  / CORP    |  port  | TrustSec, ERS, pxGrid     |
    +---------------------------+        +---------------------------+
             ^                                      ^
             | RDP 3389                             | 443 and 22
             +--------- CML host 10.20.1.10 --------+
                        (SSH forwards from the Mac)

    lab nodes 10.100.0.0/16 reach both at their own addresses, no NAT

## The Windows server

| | |
|---|---|
| Name | `dc1`, the only domain controller |
| Address | 10.20.2.10, static, on `snet-apps`. No public IP |
| Image | Windows Server 2025 Datacenter, `2025-datacenter-smalldisk-g2` |
| Size | `Standard_B2ms`, 2 vCPU and 8 GB, burstable, because a lab DC idles |
| Disk | The image's own 30 GB OS disk, Standard SSD. No data disk |
| Patching | Off. It has no route to Windows Update and lives for one session |
| Built by | `terraform/ad`, a root of its own with local state (ADR 0010) |

Windows stays in its activation grace period for the life of a session. That
is accepted; nothing in a lab session outlasts it.

The image is deliberately not an `azure-edition` one. Those are hotpatch
images, which Azure only accepts with platform-managed patching, and the
first build was refused for it.

## How the directory is constructed

`scripts/24-ad-up.sh` runs `terraform apply`. Terraform creates the VM and
then hands it three PowerShell scripts, one after another, as Azure run
commands. Each script checks its own state first, and `24-ad-up.sh` clears
any run command that failed before it applies again, so running the whole
thing after a failure only does what is left. The order matters, and the
reasons are below.

**1. `scripts/ad/10-promote-forest.ps1`: a server becomes a forest.**
It installs the AD DS and DNS roles and calls `Install-ADDSForest` for
`corp.rooez.com`, NetBIOS name `CORP`, with a Directory Services Restore Mode
password that Terraform generated and that is never written anywhere else.
Promotion needs a reboot. The script schedules it fifteen seconds out instead
of taking it at once, so the run command can report success before the
machine goes down. If the server is already a domain controller, it says so
and stops.

**2. `scripts/ad/20-install-ca.ps1`: DNS forwarding, then the CA.**
It points the DNS server's forwarder at Azure's resolver, installs the
certificate services role, and creates the certification authority. This
script cannot run as SYSTEM like the first one. An Enterprise CA writes into
the forest's configuration partition, which takes membership of Enterprise
Admins, and SYSTEM on a domain controller is only the machine account. It
runs as `CORP\labadmin`, and getting it there takes a wrapper, described
next.

**3. `scripts/ad/30-create-identities.ps1`: people, a service account, and
ISE's name.** It reads `config/ad-identities.csv`, creates the groups and
users, creates `svc-ise`, and adds ISE's DNS records. It also runs as
`CORP\labadmin`, through the same wrapper.

**The wrapper, `scripts/ad/run-as-admin.ps1`.** Azure's run command has a
run-as option, and it does not work here: it looks the user up as a local
account, and a domain controller has none. So steps 2 and 3 are delivered
inside a small wrapper that runs as SYSTEM. It waits, up to twenty five
minutes, for `Get-ADDomain` to answer, which is the signal that the reboot
finished and the directory is up; a domain logon attempted before that
fails, which is how the first build died. Then it writes the inner script to
`C:\lab\bin`, registers a one-shot scheduled task as `CORP\labadmin` with
that account's password, runs it, waits for it, prints the end of its
transcript, and removes the task. A scheduled task gets a full logon token,
which an Enterprise CA install needs and a remote session would not give.
The inner script's arguments, passwords among them for step 3, travel as one
protected parameter and reach the task through a file that only
administrators can read and that is deleted afterward. Nothing sensitive
appears on a command line.

The forest call and the CA's values come from scripts the operator already
trusted on AWS (the `cfn-ps-microsoft-activedirectory` and
`cfn-ps-microsoft-pki` Quick Start forks), with the AWS wrapping taken off:
no SSM parameters, no Secrets Manager, no CloudFormation signals, no S3.

Every script writes a transcript on the server under `C:\lab\log`, named
after itself. That is the first place to look when something went wrong.

## What runs on it

### Active Directory Domain Services

One forest, one domain, one domain controller. `dc1` holds all five
operations master roles and is a global catalog, which is simply what the
first controller of a new forest is. With AD DS come the protocols a
directory speaks: Kerberos on 88, LDAP on 389 and 636, the global catalog on
3268 and 3269, SMB on 445 for SYSVOL and NETLOGON, and RPC for replication
and management. There are no organizational units beyond the defaults, no
group policy of our own, and no second controller. Users live in the default
`Users` container and joined machines land in `Computers`.

### DNS

`dc1` is the authoritative DNS server for `corp.rooez.com`, in an Active
Directory integrated zone that promotion created. It holds the service
records that let a client find the domain, which is what ISE follows when it
joins.

| Record | Value | Why |
|---|---|---|
| `dc1.corp.rooez.com` | 10.20.2.10 | Registered by the controller itself |
| `ise1.corp.rooez.com` | 10.20.2.20 | Added by the identities script, with a PTR |
| `2.20.10.in-addr.arpa` | reverse zone | So ISE's address resolves back to its name |

Everything the server is not authoritative for goes to one forwarder,
168.63.129.16. That is Azure's own resolver, reachable from any VM in a
virtual network without an internet route, so the DC can answer public names
(ISE needs a few, Security Cloud Control and Entra among them) while having
no way out itself.

The domain is `corp.rooez.com` and not `rooez.com` on purpose.
`lab.rooez.com` is the Cloudflare front door to CML and lives in the public
zone. A child zone does not shadow it; the apex would.

Nothing at the virtual network level points at this server. The VNet keeps
Azure DNS, so the CML host and everything else resolve as they always have.
A machine uses the DC for DNS only when it is told to: ISE through its
deployment form, a domain-joined lab endpoint through its own settings.

### Active Directory Certificate Services

One tier: an Enterprise Root CA on the domain controller itself. A real PKI
would keep the root offline and issue from a subordinate. A lab that is
destroyed every night has nothing for that to protect.

| | |
|---|---|
| Common name | `corp-rooez-CA` |
| Type | Enterprise Root CA |
| Key | RSA 4096, Microsoft Software Key Storage Provider |
| Signature hash | SHA256 |
| CA certificate validity | 5 years |
| Issued certificate validity | up to 5 years |
| CRL overlap | 12 hours (`CRLOverlapUnits`; the Quick Start's `CRLOverlapPeriodUnits` is a value nothing reads) |
| Auditing | filter 127, every CA event |

One setting exists for ISE's sake: domain controllers are granted the right
to enroll from the built-in `WebServer` template, which is the template ISE's
certificate is issued from. That is what lets a certificate request be signed
by a command sent to the DC, without anyone logging in to it.

One setting is absent on purpose. An ISE certificate needs its subject
alternative names, and a common recipe for that is a CA flag,
`EDITF_ATTRIBSUBJECTALTNAME2`, that lets whoever submits a request attach
SANs to it. The lab does not set it. ISE writes its SANs inside the request
itself, `WebServer` is a template that takes the subject from the request,
and the CA copies them into the certificate as they are. The flag is a
well-known way to escalate privileges through a CA, and Windows Server 2025's
`certutil` no longer accepts its name.

Because it is an Enterprise CA, its root certificate is published into the
directory, and any machine that joins the domain trusts it automatically.

### Time

`dc1` holds the PDC emulator role, which makes it the domain's time source.
It takes its own time from the Azure host it runs on (`w32tm` reports the
`VM IC Time Synchronization Provider`), not from an internet server. ISE takes its time from
`time.google.com`, set at deployment. Kerberos tolerates five minutes of
difference, and both track real time closely enough that this has not
needed attention.

## Who is in the directory

The people come from a tracked file, `config/ad-identities.csv`, so the
directory is the same every time it is built.

| Account | Display name | Group |
|---|---|---|
| `mario` | Mario Mario | `Mushroom-Kingdom` |
| `luigi` | Luigi Mario | `Mushroom-Kingdom` |
| `peach` | Princess Peach | `Mushroom-Kingdom` |
| `yoshi` | Yoshi | `Mushroom-Kingdom` |
| `bowser` | Bowser Koopa | `Koopa-Troop` |

`Mushroom-Kingdom` stands for employees and `Koopa-Troop` for contractors,
one of each for when an ISE authorization rule needs to tell two kinds of
people apart. Both are global security groups. Every user in the file shares
one password, their passwords never expire, and their sign-in name is
`name@corp.rooez.com`. To add someone, add a row and run
`scripts/24-ad-up.sh` again; the script creates only what is missing.

Two accounts are not in the file:

- **`CORP\labadmin`** is the administrator. It begins as the VM's local
  administrator, and promotion turns that account into the domain's built-in
  Administrator, a member of Domain Admins and Enterprise Admins.
- **`svc-ise`** is the account ISE joins the domain with. It is an ordinary
  user with one delegation: it may create computer objects in the
  `Computers` container, because ISE creates its own when it joins. It is
  made by the script and not the CSV so that no row in that file is secretly
  special.

### Passwords

Terraform generates four and none of them is ever typed.

| Password | Length | Where it goes |
|---|---|---|
| `labadmin` | 12, letters and digits, easy to type at an RDP prompt | `AD_ADMIN_PASSWORD` in `ad.env` |
| Lab users, shared | 24 with symbols | `AD_LAB_USER_PASSWORD` in `ad.env` |
| `svc-ise` | 24 with symbols | `AD_SVC_ISE_PASSWORD` in `ad.env` |
| Directory Services Restore Mode | 24 with symbols | Nowhere. Nothing outside the VM needs it |

`config/mcp-env/ad.env` is written at mode 0600 and is gitignored. The script
that writes it never prints a value. The passwords also sit in this root's
local Terraform state file, which is protected only by `.gitignore` and the
Mac's disk. That is a weaker guarantee than the persistent root's blob state
and it is accepted, because the state and everything it protects end with
the session.

## ISE

ISE 3.5 runs from Cisco's Azure Marketplace image as `ise1` at 10.20.2.20, on
a 90 day evaluation that a fresh deploy renews. The deploy itself is done by
hand in the portal, because deploying that image through Azure's API fails
(`docs/ISE-MARKETPLACE-DEPLOY.md`, ADR 0008). Everything after the portal is
`scripts/25-ise-up.sh --post-deploy`: its network security group, tags, a
wait for ISE to answer, and its policy, applied as code by
`scripts/lib/ise_config.py`.

What ISE holds today, all of it created through its APIs:

| Object | Value |
|---|---|
| Network devices | `c8000v-edge` 10.100.0.2, `cat9kv-sw1` 10.100.0.3, RADIUS with a shared secret |
| Authorization rules | `trustsec-poc` and `trustsec-poc-sw1`, permit access by the device's address |
| Internal user | `trustsec-verify`, a throwaway identity the pyATS check authenticates as |

Against that, the lab has proven RADIUS, MAB, CoA, and 802.1X with PEAP, all
with ISE's own internal users (`docs/STATUS.md`, 2026-09-17).

### What the directory changes for ISE

Until now ISE has authenticated people it keeps itself. With the directory
beside it, ISE can do what it does in production:

- **Find the domain.** ISE's name server becomes 10.20.2.10 and its domain
  `corp.rooez.com`, which makes it `ise1.corp.rooez.com`, the name the DC
  already holds a record for.
- **Join it**, as `svc-ise`. ISE then appears as a computer object in
  `Computers`.
- **Authenticate against it.** A PEAP login for `mario` is checked against
  Active Directory instead of ISE's internal store.
- **Authorize by group.** `Mushroom-Kingdom` and `Koopa-Troop` become
  conditions in authorization rules, which is how a person ends up with a
  Security Group Tag in the TrustSec Phase 2 design.
- **Carry a certificate the lab trusts.** ISE's EAP and admin certificates,
  signed by `corp-rooez-CA`, replace the self-signed one that supplicants
  are currently told not to check.

None of those five is done yet. They are by hand in the ISE GUI for now, and
the last section lists them.

### The rule: the directory first, and one domain

ISE depends on DNS, and the lab's names resolve in one place. So ISE's
domain is the directory's, `corp.rooez.com`, its name server is the domain
controller, and the domain controller is built and checked before ISE is
deployed. That is the operator's decision of 2026-09-17, and it is why
`24-ad-up.sh` is numbered ahead of `25-ise-up.sh` and ends by printing the
two values the ISE portal form takes. `25-ise-up.sh` warns when it finds no
directory.

The first ISE of that day predates the rule. It was deployed with a public
resolver and the domain `rooez.com`, so it calls itself `ise1.rooez.com` and
knows nothing of the lab's names. An ISE in that state is repointed from its
command line with `ip name-server 10.20.2.10` and
`ip domain-name corp.rooez.com`. Either restarts the ISE application, about
fifteen minutes, and a new domain name means a new self-signed certificate,
which the CA step replaces anyway. Every deploy after it simply starts
right.

## Network

There is no port policy between the two servers, by the operator's choice. A
domain join, Kerberos, LDAP, RPC's dynamic ports, and certificate enrollment
together make a list too long to be worth keeping in a lab.

| Group | On | Admits |
|---|---|---|
| `dc-nsg` | `dc1` | The whole apps subnet on every port; RDP from the CML host |
| `ise-nsg` | `ise1` | RADIUS from the lab range; 443 and 22 from the CML host |

Azure's default rules already allow any traffic inside a virtual network, so
`ise-nsg` lets the DC reach ISE on every port without saying so, and
`dc-nsg`'s first rule states out loud what the defaults would have permitted
anyway. It is there so that a deny added later cannot cut ISE off by
accident. Neither server admits anything from the internet, and the DC has no
public address at all.

Lab nodes inside CML reach both servers at their own addresses, through the
routed path and with no NAT (ADR 0003). On a NIC in `snet-apps` Azure counts
the lab range as part of the virtual network, because that subnet carries
the route for it, so the default rules cover lab nodes too. That is what lets
a domain-joined Windows endpoint in a lab find its controller.

From the Mac, everything goes through the CML host, the same as every other
lab VM. `config/tunnels.conf` holds the forwards and `scripts/50-tunnels.sh
up` opens them:

    ise 8443 10.20.2.20 443      then https://localhost:8443
    dc  3389 10.20.2.10 3389     then an RDP client at localhost:3389

Sign in to the DC as `CORP\labadmin`.

## Running it

    scripts/20-up.sh                       # CML
    scripts/24-ad-up.sh                    # the directory, about 20 minutes
    (ISE portal deploy)                    # with the two values 24-ad-up prints
    scripts/25-ise-up.sh --post-deploy
    ...work...
    scripts/45-ise-down.sh                 # ISE first: it depends on the DC
    scripts/46-ad-down.sh
    scripts/40-down.sh

The directory comes before ISE so that ISE can be deployed already pointing
at it, and it goes after ISE for the same reason in reverse. The script
numbers follow that order.

`24-ad-up.sh` ends with three checks, each run on the DC itself:

1. `Get-ADDomain` answers `corp.rooez.com`.
2. DNS resolves `dc1.corp.rooez.com` and `login.microsoftonline.com`, which
   proves the zone and the forwarder.
3. `certutil -ping` finds the CA alive.

Then it prints what ISE's portal form needs:

    Primary Name Server: 10.20.2.10
    DNS domain name:     corp.rooez.com

### When it goes wrong

| Symptom | Likely cause | What to do |
|---|---|---|
| The apply fails on a run command | Anything a script threw; its message is in the apply error | Fix it and run `scripts/24-ad-up.sh` again. It deletes the failed run command first, because one that failed exists in Azure but not in Terraform's state and would stop the next apply at "already exists". Finished steps are skipped |
| The VM is refused with a `patch_mode` error | An `azure-edition` image SKU | Keep `image_sku` on a non-hotpatch SKU |
| The VM is refused for quota | The size's family has none | `vm_size` in `terraform/ad/terraform.tfvars`. `Standard_B2ms` and `Standard_D2s_v4` had room on 2026-09-17 |
| `System error thrown for RunAs user` | Someone set `run_as_user` on a run command; it cannot log a domain account on to a DC | Remove it. The wrapper is the way to run as `CORP\labadmin` |
| The CA script fails with access denied | It ran as SYSTEM, outside the wrapper | Deliver it through `run-as-admin.ps1` |
| A check fails but the apply succeeded | The directory was still starting | Rerun the script; the checks run again |
| Anything else | | The transcripts under `C:\lab\log` on the DC, over RDP |

## Not built yet

These are done by hand in the ISE GUI for now, in this order:

1. Point ISE at the DC for DNS, at deploy or from its CLI.
2. Add `corp.rooez.com` as an Active Directory join point and join as
   `svc-ise`.
3. Select the groups `Mushroom-Kingdom` and `Koopa-Troop` and put Active
   Directory in the identity source sequence.
4. Import `corp-rooez-CA`'s root certificate into ISE's trusted store,
   generate a certificate request for EAP and admin use, have the CA sign it
   from the `WebServer` template, and bind the result.

Also not built: a helper script to export the root certificate and sign a
request from the Mac, a quota check for the DC in preflight, and any of the
above as code. They wait for the ISE policy as code work (roadmap item 22).
