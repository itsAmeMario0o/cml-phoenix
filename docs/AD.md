# ISE and Active Directory

Two servers sit side by side on the apps subnet and between them answer the
lab's identity questions. ISE decides who and what gets on the network.
Active Directory is where the people are, and it also runs the two services
ISE leans on: DNS and a certificate authority. This document says what the
directory is, what runs on it, who is in it, and how ISE uses it. The
commands, in build order with what each prints, are `docs/ISE-AD-BUILD.md`.

Today both are built and destroyed per session (ADR 0008, ADR 0010). The
decision of 2026-09-18 is to build them once and deallocate them between
sessions: `docs/specs/2026-09-18-persistent-ise-dc-and-script-consolidation-design.md`,
not yet built.

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
| Patching | Off. It has no route to Windows Update |
| Built by | `terraform/ad`, a root of its own with local state (ADR 0010) |

The image is not an `azure-edition` one on purpose: those are hotpatch
images, which Azure accepts only with platform-managed patching. Windows
stays in its activation grace period.

## How the directory is constructed

`scripts/24-ad-up.sh` runs `terraform apply`. Terraform creates the VM and
hands it three PowerShell scripts, one after another, as Azure run
commands. Each script skips what already exists, and `24-ad-up.sh` clears
any failed run command before it applies again, so a rerun after a failure
does only what is left. The 2026-09-18 build proved that by resuming at
the CA stage after a fix.

1. `scripts/ad/10-promote-forest.ps1` installs AD DS and DNS and calls
   `Install-ADDSForest` for `corp.rooez.com`, NetBIOS `CORP`, with a
   restore mode password Terraform generated and stores nowhere else. It
   also sets the SAM policy value ISE's join depends on, ahead of the
   promotion reboot that puts it into effect (the ISE section has why).
   The reboot is scheduled fifteen seconds out so the run command can
   report success first.
2. `scripts/ad/20-install-ca.ps1` sets the DNS forwarder, installs
   certificate services, and creates the CA. It cannot run as SYSTEM: an
   Enterprise CA writes into the forest's configuration partition, which
   takes Enterprise Admins, and SYSTEM on a DC is only the machine account.
3. `scripts/ad/30-create-identities.ps1` reads `config/ad-identities.csv`,
   creates the groups and users, creates `svc-ise`, and adds ISE's DNS
   records.

Stages 2 and 3 run as `CORP\labadmin` through
`scripts/ad/run-as-admin.ps1`, because Azure's run-as option looks the
user up as a local account and a domain controller has none. The wrapper
runs as SYSTEM, waits up to twenty five minutes for `Get-ADDomain` to
answer (a domain logon before that is how the first build died), then
runs the inner script from `C:\lab\bin` as a one-shot scheduled task
under `CORP\labadmin`, which gets the full logon token an Enterprise CA
install needs. The inner script's arguments, passwords included, reach
the task through a file only administrators can read, deleted afterward.

The forest call and the CA's values come from the operator's AWS Quick
Start forks with the AWS wrapping taken off. Every script writes a
transcript under `C:\lab\log`, named after itself. Look there first.

## What runs on it

### Active Directory Domain Services

One forest, one domain, one domain controller. `dc1` holds all five
operations master roles and is a global catalog, as the first controller
of a new forest is. No organizational units beyond the defaults, no group
policy of our own, no second controller. Users live in the default `Users`
container and joined machines land in `Computers`.

### DNS

`dc1` is the authoritative DNS server for `corp.rooez.com`, in the zone
promotion created. It holds the service records a client follows to find
the domain, which is what ISE does when it joins.

| Record | Value | Why |
|---|---|---|
| `dc1.corp.rooez.com` | 10.20.2.10 | Registered by the controller itself |
| `ise1.corp.rooez.com` | 10.20.2.20 | Added by the identities script, with a PTR |
| `2.20.10.in-addr.arpa` | reverse zone | So ISE's address resolves back to its name |

Everything else goes to one forwarder, 168.63.129.16, Azure's resolver,
reachable from any VM without an internet route. So the DC answers public
names (ISE needs Security Cloud Control and Entra) with no way out itself.

The domain is `corp.rooez.com` and not `rooez.com` on purpose:
`lab.rooez.com`, the Cloudflare front door to CML, lives in the public
zone, and a child zone does not shadow it where the apex would. Nothing
at the virtual network level points at this server; the VNet keeps Azure
DNS. A machine uses the DC for DNS only when told to: ISE through its
deployment form, a lab endpoint through its own settings.

### Active Directory Certificate Services

One tier: an Enterprise Root CA on the domain controller itself. A real
PKI keeps the root offline; a lab has nothing for that to protect.

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

One setting exists for ISE's sake: domain controllers may enroll from the
built-in `WebServer` template, so ISE's certificate request can be signed
by a command sent to the DC. One setting is absent on purpose. `EDITF_ATTRIBSUBJECTALTNAME2` lets
whoever submits a request attach subject alternative names to it. ISE
writes its SANs inside the request, `WebServer` takes the subject from the
request, and the CA copies them as they are. The flag is a known way to
escalate privileges through a CA, and Server 2025's `certutil` no longer
accepts its name. As an Enterprise CA, its root certificate is published
into the directory, and any machine that joins the domain trusts it.

### Time

`dc1` holds the PDC emulator role, so it is the domain's time source; it
takes its own from the Azure host (`w32tm` reports the `VM IC Time
Synchronization Provider`). ISE uses `time.google.com`, set at deployment.
Kerberos tolerates five minutes of difference; both are well inside it.

## Who is in the directory

The people come from `config/ad-identities.csv`, tracked, so the directory
is the same every time it is built.

| Account | Display name | Group |
|---|---|---|
| `mario` | Mario Mario | `Mushroom-Kingdom` |
| `luigi` | Luigi Mario | `Mushroom-Kingdom` |
| `peach` | Princess Peach | `Mushroom-Kingdom` |
| `yoshi` | Yoshi | `Mushroom-Kingdom` |
| `bowser` | Bowser Koopa | `Koopa-Troop` |

`Mushroom-Kingdom` stands for employees and `Koopa-Troop` for
contractors, so an authorization rule can tell two kinds of people apart.
Both are global security groups. Every user in the file shares one
password, never expiring, and signs in as `name@corp.rooez.com`. To add
someone, add a row and run `scripts/24-ad-up.sh` again.

Two accounts are not in the file:

- `CORP\labadmin` begins as the VM's local administrator; promotion turns
  it into the domain's built-in Administrator, in Domain Admins and
  Enterprise Admins.
- `svc-ise` is the account ISE joins with: an ordinary user with two
  grants on the `Computers` container. Create computer objects, because
  ISE creates its own when it joins. Write property on those objects,
  because ISE records its operating system, version, and encryption types
  there and an object's creator may not write those three; the join works
  without this grant, but its log then fills with denied writes that look
  like a cause and are not. The script makes the account, not the CSV, so
  no row in that file is secretly special.

### Passwords

Terraform generates four and none of them is ever typed.

| Password | Length | Where it goes |
|---|---|---|
| `labadmin` | 12, letters and digits, easy to type at an RDP prompt | `AD_ADMIN_PASSWORD` in `ad.env` |
| Lab users, shared | 24 with symbols | `AD_LAB_USER_PASSWORD` in `ad.env` |
| `svc-ise` | 24 with symbols | `AD_SVC_ISE_PASSWORD` in `ad.env` |
| Directory Services Restore Mode | 24 with symbols | Nowhere. Nothing outside the VM needs it |

`config/mcp-env/ad.env` is mode 0600, gitignored, and no value is ever
printed. The passwords also sit in this root's local Terraform state,
protected only by `.gitignore` and the Mac's disk (ADR 0011); accepted.

## ISE

ISE 3.5 runs from Cisco's Azure Marketplace image as `ise1` at 10.20.2.20,
on a 90 day evaluation. The deploy is by hand in the portal, because that
image fails through Azure's API (ADR 0008); the form is
`docs/ISE-AD-BUILD.md`, Part 2. After the form and one first login,
`scripts/25-ise-up.sh --post-deploy` attaches the network security group,
tags the VM, OS disk, NIC and public IP, waits for ISE to answer, and
creates the network device `c8000v-edge` with the rule `trustsec-poc`
(`scripts/lib/ise_config.py`). `cat9kv-sw1` and its rule, the join, and
the groups are still by hand; the spec moves them into the script.

### What the directory changes for ISE

With the directory beside it, ISE does what it does in production:

| | What it means | State |
|---|---|---|
| Find the domain | ISE's name server is 10.20.2.10 and its domain `corp.rooez.com`, so it is `ise1.corp.rooez.com`, the name the DC holds a record for | Done. Proven from the portal form on 2026-09-18, no CLI repoint |
| Join it | As `svc-ise`. ISE appears as a computer object in `Computers` | Done. Joined on the first call on a clean build, 2026-09-18 |
| Authorize by group | `Mushroom-Kingdom` and `Koopa-Troop` become conditions in rules, which is how a person gets a Security Group Tag in TrustSec Phase 2 | Both groups selected on the join point, 2026-09-18. No rule uses them yet |
| Authenticate against it | A PEAP login for `mario` is checked against the directory instead of ISE's internal store | Done 2026-09-17 on that day's ISE: `test aaa` from `sw1`, right and wrong password, the DC's event 4776 showing AD answered both; and PEAP with MSCHAPv2 from `emp-pc` |
| Carry a certificate the lab trusts | ISE's EAP and admin certificates, signed by `corp-rooez-CA`, replace the self-signed one supplicants are told not to check | Not done |

Authentication needs no policy change: ISE's Default policy set looks
users up in `All_User_ID_Stores`, which includes every join point.

### The rule: the directory first, and one domain

ISE depends on DNS, and the lab's names resolve in one place. So ISE's
domain is the directory's, `corp.rooez.com`, its name server is the
domain controller, and the domain controller is built and checked before
ISE is deployed. That is the operator's decision of 2026-09-17: it is why
`24-ad-up.sh` is numbered ahead of `25-ise-up.sh` and ends by printing the
two values the portal form takes, and why `25-ise-up.sh` warns when it
finds no directory.

An ISE deployed before the DC can be repointed from its command line:
three commands, three restarts, 30 to 40 minutes, a new self-signed
certificate (`docs/ISE-AD-BUILD.md`, Part 2, "The exception").

### The join and Windows Server 2025

A Server 2025 domain controller refuses the older SAM RPC password change
methods when called remotely. ISE uses one of them,
`SamrUnicodeChangePasswordUser2`, while joining, and the join ends in
"Access is denied", error code 5, after a log in which every step
succeeded. Cisco's Field Notice FN74321 (bug CSCwr77017) lists ISE 3.1
through 3.4 P1; the DC's own log showed 3.5.0.527 does the same.

Cisco's workaround is the DC policy "Configure SAM change password RPC
methods policy" set to allow all methods, the registry value
`SamrChangeUserPasswordApiPolicy` = 3. The DC reads it at startup, which
neither the notice nor the policy text says: set on the running DC of
2026-09-17 it did nothing until a restart. `10-promote-forest.ps1` sets it
before the promotion reboot; on 2026-09-18 a DC built that way took the
join on the first call.

This lowers a default: the DC again accepts the more weakly encrypted
methods Server 2022 accepted. It is accepted for a DC with no public
address, reachable only from `snet-apps` and the lab range, holding
generated passwords, until Cisco ships a fix for 3.5 (ADR 0010, amendment
of 2026-09-17). The diagnosis for a DC built before the fix is in
`docs/ISE-AD-BUILD.md`, Part 3, "When it goes wrong".

## Network

There is no port policy between the two servers, by the operator's choice:
a join, Kerberos, LDAP, RPC's dynamic ports, and certificate enrollment
make a list too long to be worth keeping in a lab.

| Group | On | Admits |
|---|---|---|
| `dc-nsg` | `dc1` | The whole apps subnet on every port; RDP from the CML host |
| `ise-nsg` | `ise1` | RADIUS from the lab range; 443 and 22 from the CML host |

Azure's default rules already allow any traffic inside a virtual network,
so `ise-nsg` lets the DC reach ISE on every port without saying so, and
`dc-nsg`'s first rule states out loud what the defaults permit anyway, so
that a deny added later cannot cut ISE off by accident. Neither server
admits anything from the internet, and the DC has no public address.

Lab nodes inside CML reach both servers at their own addresses, routed,
no NAT (ADR 0003). On a NIC in `snet-apps` Azure counts the lab range as
part of the virtual network, because that subnet carries the route for it,
so the default rules cover lab nodes too. That is what lets a
domain-joined Windows endpoint in a lab find its controller.

From the Mac, everything goes through the CML host. `config/tunnels.conf`
holds the forwards and `scripts/50-tunnels.sh up` opens them:

    ise 8443 10.20.2.20 443      then https://localhost:8443
    dc  3389 10.20.2.10 3389     then an RDP client at localhost:3389, as CORP\labadmin

## When the build itself is refused

Everything else is in `docs/ISE-AD-BUILD.md`, Part 3, "When it goes wrong".

| Symptom | Cause | What to do |
|---|---|---|
| The VM is refused with a `patch_mode` error | An `azure-edition` image SKU | Keep `image_sku` on a non-hotpatch SKU |
| The VM is refused for quota | The size's family has none | `vm_size` in `terraform/ad/terraform.tfvars`. `Standard_B2ms` and `Standard_D2s_v4` had room on 2026-09-17 |
| `System error thrown for RunAs user` | Someone set `run_as_user` on a run command; it cannot log a domain account on to a DC | Remove it. The wrapper is the way to run as `CORP\labadmin` |
