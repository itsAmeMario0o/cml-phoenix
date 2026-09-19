# Status

A handoff. "Current state" is rewritten at the end of every session and
says where the build stands now; "Log" below it is the dated record,
newest first. Read the first section before doing anything else in a new
session, and the log when you need the story behind a line in it.
Entries older than 2026-09-17 are in `docs/STATUS-ARCHIVE.md`.

## Current state, 2026-09-18

Running in Azure: CML 2.10, built today from nothing; `dc1`; and `ise1`
on a 600 GB Premium disk, to be redeployed once (step 1 below).
`lab.rooez.com` is up. Three labs are imported and stopped: the cat9kv
probe, the TrustSec Phase 1 proof, and the Cilium EVPN fabric. The
persistent plan is clean.

Proven today on a clean build, the five items yesterday's state listed as
never run plus ADR 0012's forward: `06-transit.sh` ran from cloud-init and
`bridge1` is up; `lab-transit-in` and `lab-transit-out` came from the
fork; the SAM policy was set before the promotion reboot; the second
`svc-ise` grant is present; an ISE deployed with the DC's address in the
portal form joined the domain on the first call; and the `cml` SSH
forward works against the controller's loopback, with cml-mcp answering
through it. What was proven before today (the routed path, MAB, EAP-MD5,
PEAP, pyATS) is in the log.

Done by hand this session: the connector rescan
(`PUT /api/v0/system/external_connectors`), the cloudflared reinstall,
the three lab imports, and the domain join with its two groups. Not done
yet: `sw1`'s network device on the new ISE, `70-users.sh`, and no lab has
been started.

TrustSec Phase 2 started on 2026-09-18 and Act 1 is most of the way
done, on the running lab. `labs/trustsec-phase2.yaml` is tracked and
proven for Act 1 (`sw1`, `emp-pc`, `iot-dev`, `kali` running; ASAv, FTDv,
`srv` present and stopped; ASAv 9.24.1 added to the refplat, blob and the
controller). `sw1` polls over SNMPv3 from ISE, sends v2c traps, and relays
DHCP to ISE; `emp-pc` and `iot-dev` carry Dell and HP MAC prefixes in
their day-0; ISE profiled them `Workstation` and `HP-Device` with no
RADIUS anywhere, and its 3.5 endpoint SNMP scan swept the endpoint VLAN
over the API. `docs/ISE-INVENTORY-PARITY.md` holds the customer's
ForeScout sample, the operator's mapping, and the lab's result per row.
Found and fixed on the way: the transit network's route mode rejected
endpoints beyond the /24 (fork `b92b6a2`, ADR 0003 amended). Still by
hand on ISE: the profiler probes (GUI), the feed update (the offline apply
did not take; the online tab is next), the NMAP scan (a GUI action). Not
yet: a reverse DNS zone for 10.100.10.0/24, v3 traps, Act 2.

Next steps for Phase 2, in order (Act 1 first, then Act 2):

1. Your two GUI steps on ISE: the feed update (Online tab: enable, Test,
   Update Now; the profile count should leave 676) and one NMAP scan
   (Context Visibility, select `emp-pc`, Actions, Scan), which fills rows
   4 to 6 of `docs/ISE-INVENTORY-PARITY.md`.
2. A reverse DNS zone for 10.100.10.0/24 on the DC, fed by the switch's
   DHCP (row 3), through the run-as-admin wrapper.
3. v3 traps from `sw1` (`snmp-server host ... version 3 priv ise-poll`),
   and whether ISE's trap probe takes them.
4. Act 2, step 5: RADIUS and TrustSec on `sw1`'s device entry, MAB for
   `iot-dev` and `kali`, PEAP as `mario` from `emp-pc` (the supplicant
   config's password is `CHANGE_ME` until set from `ad.env`).
5. Act 2, steps 6 and 7: SGACL on the switch, then ASAv enforcing by tag.
   FTDv (step 8) waits for the operator's cdFMC onboarding.
6. In parallel, the persistence spec's step 1: redeploy ISE onto 300 GB
   Standard SSD, since the current ISE idles on a 600 GB Premium disk.
7. Splunk as a CML container (roadmap 23). Cisco's
   `refplat-20260701-splunk.iso` (Splunk Enterprise 10.4.1, Docker node, 4
   GB, one interface) is in `software/` with its signature;
   `SPLUNK_ADMIN_PASSWORD` is in `labs.env`. Next lab: register it the way
   ASAv was (blob, then the controller's upload API), add it to the Phase 2
   topology on the transit at a 10.100.0.x address with the password as a
   placeholder in the `environment` day-0 file, point ISE's remote logging
   and `sw1`'s `logging host` at it, and tunnel 8000 for the web UI. The
   node definition's boot completes on "Ansible playbook complete".
8. Windows 11 as a CML endpoint waits on the Enterprise evaluation ISO
   from the operator (Microsoft sign-in); the build is headless on the CML
   host with an autounattend that joins `corp.rooez.com`.

Teardown on 2026-09-19 (UTC): CML destroyed with the labs exported; ISE
and the DC deallocated, not destroyed, per the persistence spec, so the
join, probes and identities survive to the next session. Their start is
`az vm start -g rg-cml-lab -n dc1` then `-n ise1` until the scripts learn
it.

Next steps, in order:

1. The spec approved today,
   `docs/specs/2026-09-18-persistent-ise-dc-and-script-consolidation-design.md`.
   ISE and the DC persist between sessions by deallocation, the ten hand
   touches fold into `20-up.sh`, `24-ad-up.sh`, and `25-ise-up.sh`, no
   orchestrator, no state file. Its order of work, one PR each: redeploy
   ISE onto 300 GB Standard SSD (portal, once; deallocate the current one
   first, delete it after the new one is joined); `45-ise-down.sh` and
   `46-ad-down.sh` deallocate by default; the start branch in
   `24-ad-up.sh` and `25-ise-up.sh`; `ise_config.py` learns the join, the
   groups, and NADs from data; `20-up.sh` gains the rescan, cloudflared,
   the reimport, users, and the ready wait; then the docs and the ADR
   0008 amendment.
2. Rotate the two CML passwords. Declined today ("skip for now"), owed
   since the 2026-09-17 leak. Operator's apply:
   `terraform -chdir=terraform/persistent apply -replace=random_password.app_admin -replace=random_password.sys_admin`.
3. Open and smaller, for whoever picks them up: an ISE certificate from
   `corp-rooez-CA`; the Phase 2 implementation plan (spec:
   `docs/specs/2026-09-17-trustsec-phase2-design.md`); the Cloudflare
   tunnel token rotation owed since 2026-09-11; the rest of
   `docs/ARCHITECTURE-REVIEW.md`, "What to do, in order".

Runbooks: `docs/BUILD-FROM-SCRATCH.md` for the order,
`docs/ISE-AD-BUILD.md` for the directory (Part 1), the ISE deploy (Part
2), and the join (Part 3), `docs/ACCESS.md` for cloudflared. Today's
failures and their fixes are in `docs/LESSONS-LEARNED.md`.

## Log

### 2026-09-18, the proving run: five items proven, ISE joined first try

`20-up.sh` built CML 2.10 from nothing, 14 resources in about 22 minutes.
The first `50-tunnels.sh up` right after it lost two of three tunnels to
`kex_exchange_identification: Connection reset`, sshd throttling the
simultaneous connections, and the first `90-smoke-test.sh` failed two
checks seconds after the build, API not ready and license UNREACHABLE. A
retry a minute later passed 13 of 13 (LESSONS-LEARNED). On the clean
build: `06-transit.sh` ran from cloud-init and `bridge1` is up, both
`lab-transit-in` and `lab-transit-out` are on the NSG from the fork, the
`cml` forward of ADR 0012 works against the controller's loopback and
cml-mcp answers through it, and the persistent plan is clean. The
connector rescan was still by hand,
`PUT /api/v0/system/external_connectors`.

`24-ad-up.sh` promoted the forest with SAM policy 3 set before the
reboot, verified, then failed at the CA step: `certutil -crl` right after
`Restart-Service certsvc` returned `RPC_S_SERVER_UNAVAILABLE`. The old
script had discarded that exit code; PR #21's `Invoke-Native` surfaced it.
PR #27 waits for `certutil -ping` first; with it merged, the rerun
resumed at the CA step and passed its three checks. The second `svc-ise`
grant is present (CREATE CHILD and WRITE PROPERTY), all six identities
exist, the `ise1` A record resolves, and the CA answers.

The operator deployed ISE through the portal with DNS domain
`corp.rooez.com` and name server 10.20.2.10; the login page was up 33
minutes after Create. `25-ise-up.sh --post-deploy` failed once with
`ise_config: ... HTTP 401`, because the first GUI login had not yet set
the password to `ISE_ADMIN_PASSWORD`; after the login it passed: NSG,
tags, network device `c8000v-edge`, rule `trustsec-poc`. The domain join
returned 204 on the first call, `getGroupsByDomain` listed the groups,
`addGroups` returned 204, and `mario` is in `Mushroom-Kingdom` and
`bowser` in `Koopa-Troop`. No DC restart. That is all five "never run in
a clean build" items from yesterday's state, plus ADR 0012's forward.

cloudflared was reinstalled by hand (sudo password from the persistent
output, the token over stdin), 4 registrations, `lab.rooez.com` up. Three
labs were re-imported by hand and left stopped: the cat9kv probe and the
TrustSec Phase 1 proof from `exports/20260917T214927Z`, and the Cilium
EVPN fabric from `exports/20260917T025148Z`, missed for two builds because
nobody looked in the older export folder (LESSONS-LEARNED). `sw1`'s NAD is
not on the new ISE yet, `70-users.sh` has not run, and no lab has started.

Merged today: #26 (lessons, README order), #27 (the CA wait), #28 (the
spec for a persistent ISE and DC, the hand steps folded into the
scripts), and #29 (scaffolding: `docs/specs`, `docs/plans`,
`docs/archive`; `config/ise/README.md` gone). The spec decides that ISE
and the DC persist between sessions by deallocation, that the next ISE
deploy uses 300 GB Standard SSD, that the ten hand touches fold into
`20-up.sh`, `24-ad-up.sh`, and `25-ise-up.sh`, and that there is no
orchestrator and no state file. The CML password rotation was declined
today ("skip for now") and stays owed.

Running in Azure: CML, `dc1`, and `ise1` on 600 GB Premium, to be
redeployed once per the spec.

### 2026-09-17, end of day: everything torn down, nothing running

The operator called a stop. No VM is left in `rg-cml-lab`: the directory
went with `scripts/46-ad-down.sh` (13 resources), CML with
`scripts/40-down.sh`, and the operator deleted the ISE VM by hand, which
left its disk, NIC, NSG, and public address. `scripts/45-ise-down.sh`
removed three of them and missed the disk, because Azure reports a disk's
resource group in upper case and the script compared it (LESSONS-LEARNED).
The lookup is fixed and the disk is gone. What is left in the resource
group is the persistent set and nothing else: the data disk, the SSH key,
`pip-cml-lab`, `rt-apps`, the VNet, and the storage account.

The CML teardown needed a hand. The export (`exports/20260917T214927Z`,
also in blob) and the license release passed, then the destroy failed
because the rendered `config/cml.yml` still named `06-transit-bridge.sh`;
the line was corrected and the destroy step rerun, 13 resources destroyed
(LESSONS-LEARNED). Before the export, `sw1`'s running configuration was
extracted into the "cat9kv probe" lab, so its working AAA, RADIUS, 802.1X,
and MAB lines are in that export. That lab was a hand-built test lab and is
not the TrustSec lab. The TrustSec lab is the Phase 2 design, which has a
spec, no implementation plan, and no topology; the export is an input to it.

Also new today: `docs/ARCHITECTURE-REVIEW.md`, a self-audit by four
read-only reviewers. Read its "What to do, in order" list before the next
build. The first item is rotating the two CML passwords, which never
happened (the correction is in the 2026-09-17 early entry below).

New today: `docs/BUILD-FROM-SCRATCH.md`, the whole build in order for
someone starting from a clone and an empty subscription, linking to the
detailed documents. Writing it turned up things no document said before: on
another subscription `terraform/persistent/backend.tf` needs the bootstrap
root's storage account name, the image upload has to follow the persistent
apply, and `config/refplat.txt` mixes images from two ISOs. It also
questioned this file's 2026-09-17 early entry about password rotation.
Checked since: it was wrong, and that entry now says so.

Code that has not yet run in a clean build, all of it expected to work: the
fork's `06-transit.sh` from cloud-init and its `lab-transit-out` rule, the
SAM policy in `10-promote-forest.ps1`, the second `svc-ise` grant, and an
ISE deployed with the DC's address in the portal form. The next build is
the test of all five. Order: `20-up.sh`, `24-ad-up.sh`, the ISE portal
deploy with the two values it prints, `25-ise-up.sh --post-deploy`, then
`docs/ISE-AD-BUILD.md` Part 3 by hand.

Still by hand on every new ISE until `ise_config.py` learns it: the join
point, the join, the two groups, `cat9kv-sw1`, and its authorization rule.
After that comes an ISE certificate from `corp-rooez-CA`, then the Phase 2
implementation plan. PR #18 is merged, and `CLAUDE.md` now lists
`terraform/ad`, `scripts/ad/`, and the two AD scripts.

### 2026-09-17, late night: ISE joined to the domain, mario authenticates against AD

ISE is joined to `corp.rooez.com` as `svc-ise`, and a directory user
authenticates from a lab switch. On `sw1` (NAD 10.100.0.3, RADIUS group
`ISE-GROUP`), `test aaa group radius mario <password> new-code` gave "User
successfully authenticated" with the password in `AD_LAB_USER_PASSWORD` and
"User rejected" with a wrong one. The DC's Security log shows AD gave both
answers: event 4776, `mario@corp.rooez.com`, Source Workstation `\\ISE1`,
error code `0x0` and then `0xC000006A`. No ISE policy change was needed; the
Default policy set's `All_User_ID_Stores` includes `All_AD_Join_Points` as
ISE ships.

The join had been blocked by Cisco Field Notice FN74321, and that is now
proven, on an ISE version the notice does not list (3.5.0.527). With the
logging-only value `AuditLegacyPasswordRpcMethods` = 1 on the DC, SAM logged
event 16985 twice during a join, from 10.20.2.20 as `ISE1$`:
`SamrSetInformationUser`, then `SamrUnicodeChangePasswordUser2`, which
Server 2025 blocks. Summary event 16984 had been in the System log at the
time of each failed join all along (19:58:34 and 21:13:54 UTC). The operator
approved Cisco's workaround, `SamrChangeUserPasswordApiPolicy` = 3. Set on
the running DC it changed nothing. After `az vm restart` of `dc1` (boot
21:22 UTC) the same join call returned 204, so the value is read at startup,
which neither the notice nor the policy text says. The build is getting the
value in `scripts/ad/10-promote-forest.ps1`, before the promotion reboot, so
a new DC comes up with it in effect. The verbose audit value goes back to 0.
The risk and its bounds are ADR 0010's new amendment: weaker password change
methods accepted again, on a DC with no public address that ends with the
session, until Cisco fixes 3.5. For the customer story, a Server 2025 domain
needs this setting or a fixed ISE patch.

The session's permission classifier refused to let the assistant set the
SAM value even after the operator said to apply it, because it lowers a DC
security default, so the operator ran the one `az` command. A future session
that tries it by hand will meet the same refusal; with the value in the
build script it stops mattering.

After the join, over ERS: `getGroupsByDomain` returned 53 groups,
`addGroups` selected `Mushroom-Kingdom` and `Koopa-Troop` (a plain PUT to
the join point is a 405), and `getUserGroups` put `mario` in
`Mushroom-Kingdom` and `bowser` in `Koopa-Troop`. The `ise` tunnel had
dropped during ISE's restarts and needed `scripts/50-tunnels.sh up`. All of
it is in `docs/ISE-AD-BUILD.md`, Part 3, and LESSONS-LEARNED.

None of the ISE side is code. It lives on the running ISE and has to be
redone on the next one until `ise_config.py` learns it.

PEAP followed the same hour. `emp-pc`'s supplicant was switched from the
internal user to `mario` with his directory password: EAP-MSCHAPv2
succeeded, `sw1` shows Gi1/0/2 authorized by dot1x as `mario`, and the DC
logged event 4776 for him from `ISE1` in the same second. `emp-pc` now logs
in as `mario`, not `trustsec-verify`.

Next: an ISE certificate signed by `corp-rooez-CA`. Authorization by group, the two groups to SGTs, is Phase 2.

Running in Azure: CML, ISE, and the DC. PR #18 is open.

### 2026-09-17, night: ISE repointed at the DC, join point made, join blocked

> Superseded on the join by the entry above: the cause was FN74321, the
> workaround plus a DC restart fixed it, and ISE is joined. The repoint and
> the delegation finding below still hold.

ISE now uses the directory for DNS. The ISE deployed that morning had
8.8.8.8 and the domain `rooez.com`, and it was repointed from its CLI:
`ip name-server 10.20.2.10`, `no ip name-server 8.8.8.8` (the first command
appends, so the public resolver stayed in front until removed), and
`ip domain-name corp.rooez.com`. Each asks to restart ISE's services and
has to be answered `yes`; `no` cancels the change itself. Three restarts,
30 to 40 minutes. Verified on ISE: the running config has the one name
server and the new domain name, `ping dc1` resolves to
`dc1.corp.rooez.com (10.20.2.10)` and gets replies, and `show ntp` shows ISE
synchronized with the DC's clock within seconds of it. ISE is
`ise1.corp.rooez.com` now, with a new self-signed certificate. ISE's own
`nslookup` fails on this image while resolution works, so `ping` is the
check (LESSONS-LEARNED).

The Active Directory join point `corp.rooez.com` exists, created over ERS
through the `ise` tunnel as `iseadmin`. The join as `svc-ise` fails. The API
only says HTTP 500, "nodes not able to join/remove"; the reason is in ISE's
`ise-psc.log` and nowhere else. The first reading of that log blamed the
delegation: `svc-ise` could create its computer object but was denied
`operatingSystem`, `operatingSystemVersion`, and
`msDS-SupportedEncryptionTypes`. Write property on computer objects under
`CN=Computers` was granted live on the DC, and the same `dsacls` line is
being added to `scripts/ad/30-create-identities.ps1`. After it every
attribute is written and `ISE1` on the DC shows its OS and version. The join
still ends on the same line, "Access is denied", error code 5, so those
denials were never fatal.

The suspected cause is Cisco Field Notice FN74321 with regression bug
CSCwr77017: a Windows Server 2025 DC refuses the legacy SAM RPC password
change methods that ISE uses in a join. The notice lists ISE 3.1 through
3.4 P1 and does not mention 3.5; ours is 3.5.0.527, so it is not proven
here. Cisco's workaround is a DC policy ("Configure SAM change password RPC
methods policy", allow all; registry `SamrChangeUserPasswordApiPolicy` = 3).
It has not been applied. It lowers a security default on a domain
controller and is the operator's decision. Until then nothing after the
join (groups, identity source sequence, `test aaa` from `sw1`, PEAP from
`emp-pc` as `mario`, a CA-signed ISE certificate) can start.

New: `docs/ISE-AD-BUILD.md`, the step by step runbook for the Windows
server, ISE's DNS, and the join, with `docs/AD.md` kept as the conceptual
document. Ten lessons added to LESSONS-LEARNED from this work.

Running in Azure: CML, ISE, and the DC, all three. PR #18 is open.

### 2026-09-17, evening: 802.1X proven, Phase 2 spec drafted, direction recorded

802.1X works in this lab. An IOSvL2 node added to the probe lab as a
supplicant (`dot1x pae supplicant`, EAP-MD5, the `trustsec-verify`
identity) on `sw1` Gi1/0/2 authorized: switch side `dot1x Authc Success`,
ISE side passed, method dot1x, EAP-MD5, Internal Users, PermitAccess,
79 ms. A capture on the CML link showed EAPOL on the wire, so CML's
fabric carries it; the usual virtual-lab failure does not apply. The
Catalyst 9000v is the device under test throughout, as the authenticator;
the IOSvL2 only plays the endpoint. An hour went to a CML trap, not to
802.1X: a link created through the API leaves the running node's
interface `STOPPED`, passing nothing while every guest shows it up
(LESSONS-LEARNED). Later the same evening the IOSvL2 node was dropped at
the operator's request and replaced by `emp-pc`, an Ubuntu node with
`wpa_supplicant`: PEAP with MSCHAPv2 authorized on the same port, ISE
recording protocol PEAP (EAP-MSCHAPv2), 126 ms. Its first attempt was
refused because the port still held the old endpoint's session in
single-host mode and the violation err-disabled it (LESSONS-LEARNED).
Also that evening: the Python rewrite (roadmap 21) was tabled by the
operator in favor of functional labs; ASAv 9.24.1 is on the base ISO and
supports SGT rules, inline tagging, and SXP with a local CLI, a lighter
enforcement point than FTDv if wanted; and the operator wants the Active
Directory instance built, whose 09-13 draft spec needs reconciling with
this week (ISE is reached by the CML jump, not its public IP, and is
already deployed with a public resolver).

The Phase 2 design is drafted for review (PR #17,
`docs/specs/2026-09-17-trustsec-phase2-design.md`), in two
acts after the operator's five-step slide: Act 1 is the SNMP-only
inventory job against the switches, RADIUS untouched; Act 2 adds tags,
SGACLs on the switch, and FTD enforcing by inline tag. Routed access is
the default, the customer fabric being VXLAN EVPN on IOS XE, with
switched access as a day-0 variant. Six unknowns remain as gates with
fallbacks. Operator direction recorded as roadmap items 21 (standardize
on Python under a real test framework) and 22 (ISE as policy as code
from the proven API calls); both need their own specs.

Running: CML, ISE, the Phase 1 lab, and the probe lab with `sw1`, `ep1`
(MAB session), and `supp1` (dot1x session). Still owed by the operator
for the spec: the ForeScout sample in the repo, the device class
`iot-dev` should imitate, and the customer's SNMP version.

### 2026-09-17, afternoon: first pyATS Phase 1 run, first MAB session, CoA proven

`scripts/80-verify-lab.sh trustsec-phase1` ran against a live lab for the
first time. RadiusServerReachable and RadiusAccessAccept pass: the C8000v
edge authenticated a real ISE internal user over the routed path.
CoAReceived fails at 0 on the edge, and that is accurate, not a bug: ISE
only sends a CoA for a live session, sessions are keyed by endpoint MAC,
and a router with no endpoints never has one. Three latent bugs fixed on
the way (PR #16): the pyATS console hop checked the operator's own
`known_hosts` and broke after every rebuild (now pinned to
`keys/known_hosts` by `gen_testbed.py`), IOS XE nodes were logged in to as
`cisco` instead of `admin`, and the CoA check used a command this image
rejects; the counters are under `show aaa clients` as `CoA: requests: N`.
The run needs a throwaway ISE identity: `trustsec-verify`, created over
ERS, credentials in gitignored `labs.env` as `TRUSTSEC_TEST_*`. ISE is
redeployed each session, so it has to be recreated each time until
`ise_config.py` learns to do it.

CoA was then proven where it can be, on the switch. On `sw1` in the
cat9kv probe lab, `authentication port-control auto` plus `mab` on
Gi1/0/1 authorized `ep1` (`5254.008b.adb0`) on the first frame: switch
side `Status: Authorized, mab Authc Success`, ISE side passed, method
mab, NAS 10.100.0.3, profile PermitAccess, 80 ms. That needed one more
ISE authorization rule, `trustsec-poc-sw1` (NAS-IP 10.100.0.3 to
PermitAccess), made with the existing `ensure_authorization_rule`; the
only rule before it matched the edge's address. With a real session to
act on, `GET /admin/API/mnt/CoA/Reauth/ise1/<mac>/1` returned
`results: true`, and the switch showed `CoA: requests: 1, Ack responses:
1`, 4 ms. Everything ADR 0003 set out to make possible now works: a
switch seen by ISE at its own address, no NAT, RADIUS both ways, and CoA
back to the right device. ISE's monitoring API is the useful window for
this work: `/admin/API/mnt/AuthStatus/MACAddress/<mac>/<secs>/<n>/All`
for the pass or failure reason, `/Session/ActiveList` for sessions.

The MAB port config and the `sw1` rule exist only on the running switch
and the running ISE. They are the seed of Phase 2's day-0 and policy,
not something to codify as they stand. Next: the Phase 2 spec, with FTDv
and Kali in the topology, SGTs in place of PermitAccess, and the CoA
check moved from the edge scenario to the switch.

### 2026-09-17, later: rebuilt, RADIUS answered, the routed path is proven

Rebuilt CML and ISE from nothing and closed the open problem. A lab
switch now gets a RADIUS reply from ISE: `sw1` sent an Access-Request at
11:45:51.507 UTC and received an Access-Reject (made-up user, the right
answer) 400 ms later. Switch, `bridge1`, host forwarding, Azure, ISE, and
the UDR return path are all proven for the first time.

The cause was Azure, not the host or ISE. The `VirtualNetwork` tag
expands per NIC from that NIC's effective routes, and only `snet-apps`
carries the UDR for 10.100.0.0/16. On the CML NIC a forwarded packet with
a lab source matched no default outbound allow and was dropped silently.
Proven with a RADIUS-filtered capture on ISE's own interface (zero
packets while the switch sent) and `list-effective-nsg`'s `tagMap` for
both NICs. Fix: `lab-transit-out` on the CML NSG, lab summary to the apps
subnet, now in the fork's `azure/main.tf` (`1ade9ae`). The operator added
the rule by hand to the running NSG, since the session's classifier
refuses NSG changes; it is not in that root's state, which is harmless
because teardown deletes the NSG.

Four more latent bugs surfaced on the way, all fixed with tests where
code was involved (PR #14): `06-transit-bridge.sh` was shipped to
`/provision` and silently skipped on its first cloud-init build, because
upstream `postprocess` only runs `[0-9]{2}-[[:alnum:]_]+\.sh` and the
second hyphen fails it, so the script is `06-transit.sh` now and ran by
hand from `/provision` this time; `25-ise-up.sh` read curl's doubled
`000000` as "ISE answered" at 0 seconds, then a front-end `502` as ready
at 28 minutes, so readiness now needs a status below 500; the expect
helpers checked the console server against the operator's own
`known_hosts` and died after the rebuild, so they use `keys/known_hosts`.
ISE's CLI is reachable with `keys/cml-lab` through the jump
(`ise1/iseadmin#`), and its capture syntax on 3.5 is `tech dumptcp
interface GigabitEthernet0 console filter "..." time-limit 1`.

Running now: CML (smoke test 12/12, cloudflared reinstalled,
`lab.rooez.com` back), ISE 3.5 at 10.20.2.20 with `ise-nsg`, all five
resources tagged, policy applied, `c8000v-edge` and `cat9kv-sw1` as
NADs, and two labs up: TrustSec Phase 1 and the untracked cat9kv probe
(`sw1` at 10.100.0.3, `ep1` on Gi1/0/1). Users recreated. Next: the pyATS
`trustsec-phase1` run, then the first MAB session on `ep1`'s port, then
the Phase 2 spec with FTDv and Kali.

### 2026-09-17, Catalyst 9000v live, transit bridge built, RADIUS one hop short

Both Catalyst 9000v flavors are on the controller without a rebuild:
uploaded to blob from the base ISO, then registered on the running host
through the dropfolder and the `POST /images/upload` API (PR #10,
LESSONS-LEARNED). A scratch lab "cat9kv probe" runs one `cat9000v-uadp`
as `sw1` at 10.100.0.3 with an alpine on an access port, and the CLI
probe accepted everything the design needs: switchport access mode,
MAB, dot1x authenticator, `access-session`, CTS enforcement globally
and per VLAN and interface, static SGT maps, `cts manual` inline
tagging with `propagate sgt`, SXP, device-sensor, DHCP snooping,
device tracking. `network-advantage` and `dna-advantage` are licensed.
`cat9kv-sw1` is a network device in ISE. The Cisco doc for the node
lists only basic L2, OSPF, SVIs, and VLANs as tested, so the functional
proof (a real MAB session, SGACL hits) is still owed.

The bigger finding: the routed path to ISE had never been built on the
host. The 2026-09-13 entry below said so ("the fork customize script
never landed") and the session had read past it. No lab node could reach ISE and
the Phase 1 pyATS run had never executed. It exists now, after three
rounds on the live host: a netplan bridge named `br-transit` (the
controller's connector scan ignores any name that is not `bridgeN`,
`virbrN`, `vlanN`, or `localN`), then `bridge1` (firewalld on the CML
host rejected every forwarded packet with "administratively
prohibited"), then the shape that works, a libvirt routed network named
`transit` on `bridge1` with the /16 route to the edge in its XML, which
brings its own firewalld zone and policies. That is what
`06-transit-bridge.sh` in the fork does now, listed under
`app.customize`, with `tests/test_transit.sh` covering its dry-run
paths (PR #11, submodule bumped twice). The operator ran it by hand on
the live host each time, since the auto-mode classifier refuses remote
`sudo`; both labs' connector nodes point at `bridge1` and are up.

Proven with tcpdump on the host: the switch's RADIUS request arrives on
`bridge1` and leaves `eth0` toward ISE. Network Watcher confirms ISE's
route back is the UDR and its NSG allows the request in and the reply
out. Yet no reply ever returns. The untested hop is the CML NIC's
outbound NSG evaluation of a forwarded packet with a non-VNet source
(Azure's `test-ip-flow` refuses to model it), and the alternative is
ISE receiving and not answering. The next session starts from ISE's
side: RADIUS Live Logs through the `ise` tunnel, or `tech dumptcp` on
its CLI once the SSH key the Marketplace deploy was given is known
(SSH there is key-only; the try with `keys/cml-lab` was interrupted).
Full state, the exact next steps, and the Phase 2 topology with FTDv
and Kali added are in the Phase 2 note,
`docs/specs/2026-09-16-trustsec-phase2-cat9kv-profiling-plan.md`.

Two things to carry forward. The rendered `config/cml.yml` secrets,
sysadmin's sudo password among them, appeared unmasked in this
session's tool output and an editor selection; rotate at the next
build. (This entry first also said a ping from the lab range to ISE can
never succeed for want of an ICMP rule on `ise-nsg`. Wrong, and corrected
on 2026-09-17 evening: the pings failed for the same reason RADIUS did,
and work now. LESSONS-LEARNED has it.)

Torn down at 02:51 UTC after both PRs merged: all three labs exported
to blob under `exports/20260917T025148Z` (the cat9kv probe lab among
them, so its YAML survives even though it was never tracked), license
deregistered, 13 resources destroyed, persistent plan clean. This entry
first said the teardown also destroyed the root's `random_password` secrets
and that the next `20-up.sh` would rotate the admin and sysadmin passwords
that leaked into this session. That was wrong, and nothing rotated: both
passwords are defined in `terraform/persistent/main.tf` and read from its
outputs on every build. They need
`terraform -chdir=terraform/persistent apply -replace=random_password.app_admin -replace=random_password.sys_admin`
before the next build, which is the operator's apply
(`docs/ARCHITECTURE-REVIEW.md`, security). The next build ships
`06-transit-bridge.sh` through cloud-init for the first time; check
`/var/log/provision/06-transit-bridge.log` and the connector list
(`Bridge 1` on `bridge1`) before reimporting the labs, then the pyATS
`trustsec-phase1` run is the first thing to try. ISE came down right
after, all five resources: `45-ise-down.sh` needed two fixes first,
recorded in the same PR. az 2.89 refuses `--tag` with
`--resource-group`, so the tag query now filters by resource group in
JMESPath; and the portal deploy leaves the NIC (`ise1nic`) and public IP
(`ise1-ip`) untagged, so `25-ise-up.sh` tags them now and both were
tagged by hand this time so the teardown caught them. Next session
starts with nothing running in Azure but the persistent root; ISE is a
fresh portal deploy plus `25-ise-up.sh --post-deploy` again.

PRs #10 and #11 merged at session end: #10 (Catalyst 9000v in the reference platform)
and #11 (the transit bridge, the `bridge1` rename in the Phase 1 lab,
smoke test, and verify script, these lessons and this entry).

Superseded later the same day by "2026-09-17, later: rebuilt, RADIUS
answered, the routed path is proven" above:
steps 1 to 5 were carried out, step 6's question is answered (the CML
NIC's outbound NSG, fixed as `lab-transit-out` in the fork), and the
script and its log are `06-transit.sh` and `06-transit.log` now. Kept
for the record of what was planned.

Next session, in this order (reviewed by `/code-review` before merge;
it caught the wrong Terraform root, the missing rescan, and three
omitted steps):

1. `scripts/00-preflight.sh`, then `scripts/20-up.sh`. Nothing is running
   in Azure but the persistent root, and the data disk already holds
   every image, both Cat9000v flavors included.
2. On the new host, before anything else: `/var/log/provision/06-transit-bridge.log`
   must contain `[06-transit-bridge] bridge1 holds 10.100.0.1/24` and
   `[06-transit-bridge] 10.100.0.0/16 routes via 10.100.0.2` and no
   `FAIL:` line (`postprocess` swallows the exit code, so the log is the
   only signal). This is the fork script's first run through cloud-init;
   it has only ever run by hand. Then `PUT /api/v0/system/external_connectors`
   to rescan, because `postprocess` runs after the controller's own
   startup scan and the script does not rescan for itself; only after
   that should `GET` list `Bridge 1` on device `bridge1`. Making the
   script issue that rescan (the way `04-customize.sh` talks to the API
   from postprocess) is a small fork change worth doing first.
3. `scripts/70-users.sh` (accounts and lab grants live on the disposable
   VM) and the cloudflared reinstall in `docs/ACCESS.md`, both needed
   after every rebuild.
4. `scripts/90-smoke-test.sh` (it checks `bridge1` now), then reimport
   `labs/trustsec-phase1.yaml` with `60-import-lab.sh`, and the cat9kv
   probe lab, which step 6 depends on (it is where `sw1` and `ep1` live;
   the Phase 1 lab has only the edge). The probe lab was never tracked;
   its only surviving copy is the blob export
   `exports/20260917T025148Z/cat9kv-probe-f13f801f-ab62-4436-a788-f04827ad6684.yaml`.
   Rerun `70-users.sh` after importing so the grants cover both labs.
5. ISE: portal deploy per `docs/ISE-AD-BUILD.md` Part 2, then
   `scripts/25-ise-up.sh --post-deploy`, which now tags the NIC and
   public IP too. Note which SSH public key the deploy is given; the ISE
   CLI is key-only and step 6 needs it. Re-add `cat9kv-sw1` (10.100.0.3)
   as a NAD, or fold it into `ise_config.py`. Then
   `scripts/80-verify-lab.sh trustsec-phase1`, the pyATS run that has
   never executed against a live lab.
6. The open question, from ISE's side first: does the switch's
   Access-Request reach ISE (RADIUS Live Logs through the `ise` tunnel,
   or `tech dumptcp 0 count 12` on its CLI). If not, the CML NIC's NSG is
   the suspect, and it lives in the fork, not the persistent root:
   `azurerm_network_security_group.cml` in
   `vendor/cloud-cml/modules/deploy/azure/main.tf`, next to the existing
   `lab_transit` inbound rule. An explicit outbound rule there for source
   10.100.0.0/16 to the apps subnet is a stop-and-ask vendor edit that
   takes effect on the next build. If ISE does see the request and stays
   silent, the Live Log drop reason says why. Only after RADIUS answers:
   the first MAB session on `ep1`, then the Phase 2 spec with FTDv and
   Kali (`docs/specs/2026-09-16-trustsec-phase2-cat9kv-profiling-plan.md`).
