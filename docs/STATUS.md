# Status

Dated handoff, newest entry first. Read this before doing anything else in
a new session.

## 2026-09-11, afternoon

Rebuilt in the afternoon: preflight 55 OK, 13 resources, API ready
about a minute after the build printed its URL, smoke test 10 OK on
the first run this time, connector installed over SSH with four
connections, front door answering. The persistence hook kept all
twelve images, Kali and FTDv included, and both custom definitions
were still registered. Both labs reimported with `60-import-lab.sh`
and the IPS lab is starting, firewalls last.

Registration solved by the operator: the cdFMC registration key is
live only briefly after SCC generates it. Delete the manager on the
console, generate the key, add the manager within a minute, and both
firewalls registered (LESSONS-LEARNED). Both FTDv nodes are Completed
in cdFMC. Next in cdFMC: HA pair on GigabitEthernet0/0, inline set
from 0/1 and 0/2 on the pair, allow-all access control policy with an
intrusion policy, deploy. Then Kali gets DHCP and the IPS lab is live.

Evening check of everything but the firewalls: all eleven nodes
BOOTED; the edge holds its three addresses and loopback and its DHCP
pool has a lease at 10.10.0.100, which means a request crossed VLAN
10 to VLAN 20 through an inline set, so the pair is forwarding. The
Nexus and the four hosts could not be checked from the console this
time: cml-mcp's proxy is blocked by the stale host key in the Mac's
`~/.ssh/known_hosts` (LESSONS-LEARNED), an expect runner through the
console server handled the IOS XE prompt but not the NX-OS and Linux
ones, and the Mac ran out of memory mid-sweep. Their configuration is
day-0 and was verified after the first import. The lab was renamed
in the UI to "Attack Lab - Inline IPS, FTD HA pair"; the console
server paths use that title.

Two fixes on the operator's side before the next console session:
`ssh-keygen -R 20.114.184.195`, and remove line 17 of
`config/mcp-env/labs.env`, a pasted `configure manager add` line that
breaks every script that sources the file.

The rebuild wiped the CML users, as every rebuild does. The lab user
mruiznet@gmail.com no longer exists and its lab rights could not be
re-granted. Either recreate it in the UI, or add a row to
`config/mcp-env/users.csv` and run `70-users.sh`; the script's
username rule does not allow an @, so a plain username with the email
in the email column is the fit.

## 2026-09-11, early morning

Torn down at 03:33 UTC. Both labs exported to blob under
`exports/20260911T033320Z` (the first attempt refused a 2.10-shaped
export; fixed, LESSONS-LEARNED), license NOT_REGISTERED, 13 resources
destroyed, data disk unattached with twelve images on it: the ten
from the refplat lists plus FTDv 10.0.0 and Kali 2026.2. The next
build reimports the two labs with `60-import-lab.sh`; the Kali node
definition and image are on the disk, and their blob copies under
`custom/` are the fallback. No VM exists.

The FTDv cluster lab ran for an hour and was retired. The vPC pair,
HSRP, eBGP to the edge, and ECMP toward the firewalls all came up from
the reference configs, and the inside host's LACP bond bundled once
the virtio members were given a link speed (LESSONS-LEARNED). The
firewalls never registered: Threat Defense rejected the day-0
password for lacking a special character and then blocked all
configuration. The deeper problem was design: a Threat Defense
Virtual cluster cannot run inline sets, and the operator wants an IPS
lab. The cluster lab was wiped and deleted from the controller; its
files stay under `labs/ftdv-cluster*` as a retired design.

Replacement: `labs/ips-ha.yaml`, spec
`docs/superpowers/specs/2026-09-11-ips-ha-lab-design.md`. An FTD HA
pair with inline sets between VLAN 10 and 20 on one Nexus, a cat8000v
edge as gateway and DHCP, Kali and an Ubuntu server inside, two
servers outside, cdFMC management. Kali 2026.2 came from the official
QEMU image: downloaded on the CML host, unpacked there with 7z from
apt, registered through the dropfolder and the definitions API under
`config/node-definitions/kali.yaml`, and copied to blob under
`custom/` for future rebuilds (15 GB, fourteen seconds inside Azure).

Built the same night. `labs/ips-ha.yaml` imported with all eleven
nodes; n9k1, edge, the three Ubuntu hosts, Kali, and both FTDv are
up. VLAN 10 and 20 verified on the switch, the edge answers on all
three addresses and reaches both outside servers, no DHCP lease yet
because VLAN 10 is isolated until an inline set exists. Both
firewalls accepted the day-0 password this time and show the cdFMC
manager with registration Pending. Kali needed a serial console
edited into its base image (LESSONS-LEARNED); it now logs in on the
console, nmap 7.99 present, and VNC is available through the video
device in its node definition.

Registration is the open problem. The tenant host refuses 8305 from
everywhere while 443 answers with the tenant's certificate; every
device-side variant was tried and is written up in LESSONS-LEARNED.
Both firewalls currently carry a plain `DONTRESOLVE` manager entry at
the operator's request, Registration Pending. The two device records
in Security Cloud Control are in the onboarding state with the
generated keys, which are in `config/mcp-env/labs.env`; both lines
also passed through the chat transcript, so regenerate them if the
records are recreated. Next step is on the tenant side: find out
which host and port the Online device BOWSER uses, or ask SCC support
why 8305 is refused. Then delete and re-add the manager on both
consoles from the env file.

Everything else in the lab is up and correct. The inline set does
not exist until cdFMC has the pair, so VLAN 10 is still isolated and
Kali has no address; that is by design.

Was blocked on the operator: `FTD_ADMIN_PASSWORD` in
`config/mcp-env/labs.env`, upper, lower, digit, special character, no
sequences. The import refuses to render without it. Then: import,
start the switches, Nexus, and edge, then hosts, then the two FTDv,
console password change if day-0 still trips, registration, and the
HA pair plus inline set in cdFMC.

## 2026-09-10

Built in the evening and online: preflight 53 OK, 13 resources in about
five minutes, smoke test 10 OK on the second run. The first run landed
in the host's post-install reboot and failed five checks; that is now a
lesson. The tunnel connector went in over a single SSH session, with
the sysadmin password and the token fed on stdin from the persistent
root and the env file, so neither touched the chat. Four registered
connections, and the name redirects to the Access login. That one
command is most of roadmap item 6. The blank Cilium EVPN lab imported
on the first try through `60-import-lab.sh`: eleven nodes, 22 links,
image names resolved, kind-host at 4 vCPU and 8 GB. It sits stopped.

The six switches were started by hand and booted. The lab user
mruiznet@gmail.com holds lab_edit and lab_exec on the lab, set through
the API because the cml-mcp tool for it is broken (LESSONS-LEARNED).
`labs/cilium-evpn-fabric/` holds the reference fabric configuration,
one NX-OS file per switch, generated from one address plan: eBGP
underlay and overlay, leaves 65000, spines 65010, anycast RP, VRFs red
and blue with anycast gateways. Pushed to all six through cml-mcp's
`send_cli_command` once the pyATS extra was installed (LESSONS-LEARNED)
and saved. Verified: every spine holds four underlay and four overlay
sessions, every leaf two of each, all Established; each leaf sees the
other three VTEPs and all four VNIs are up. The kind host and the two
endpoints are still not started.

Next lab decided: a vPC pair of Nexus 9300v with routed uplinks to a
cat8000v and two FTDv nodes dual-homed to both Nexus, clustered under
cloud-delivered management from the user's Security Cloud Control
tenant, so no FMCv. Cisco documents FTDv clustering on KVM for cdFMC:
individual data interfaces only, a dedicated VXLAN cluster control
link, same version on every node. FTDv 10.0.0 from the supplemental
ISO is in blob (1.6 GB, uploaded with `REFPLAT_ISO`) and on
`config/refplat.txt` as the eleventh image. It lands on the data disk
at the next rebuild. About 18 vCPU and 48 GB for the whole lab. Spec
and topology are not written.

Later the same evening: `scripts/70-users.sh` (ADR 0007) creates CML
users and groups from `config/mcp-env/users.csv` with a generated
password each, written to a private sheet, and a `class` subcommand
prints rows for a class. Proven against the fake API only; no user has
been created on the live controller yet. The admin password from
`cml.env` was exposed by an editor selection in this session, so the
persistent `random_password` for it should be tainted before the next
build.

Before the build, the session went to a new lab. A peer's repo,
cml-cilium-evpn-lab, describes an NX-OS EVPN fabric with a kind cluster
running Cilium Enterprise, built through Nexus Dashboard. It fits this
host: 84 GB of RAM and 18 vCPU for nine licensed nodes, with Nexus
Dashboard dropped in favour of plain NX-OS configuration. The first
deliverable is `labs/cilium-evpn-blank.yaml`, where the switches boot
with only hostname, admin user, mgmt0 address, and the loader-prompt
workaround. The management network moved from the System Bridge to the
NAT connector so the kind host has internet. The built edition, with
the full fabric in day-0 config, is tabled (roadmap item 9).

Passwords in a tracked topology were the design question. ADR 0006:
placeholders in the file, `scripts/60-import-lab.sh` renders them from
`config/mcp-env/labs.env` and posts the lab to the API. Tested against
the fake API; not yet run against a real controller.

### Pick up here

1. cdFMC registration, on the tenant side first (see above). Then on
   each firewall console: `configure manager delete`, then
   `configure manager add <host> <key> <NAT ID> <display name>` with
   that device's values from the env file.
2. In cdFMC once both are Online: HA pair on GigabitEthernet0/0,
   inline set from 0/1 and 0/2 on the pair, allow-all access control
   policy with an intrusion policy, deploy. Then Kali gets DHCP from
   the edge and `nmap 203.0.113.101` crosses the active unit.
3. Push the twenty-odd unpushed commits.

The original order for cycling the box follows; the Cilium lab is
stopped, not wiped, and the FTDv image is already on the disk. When it is
time to cycle the box for the FTDv image, this is the order:

1. `ASSUME_YES=1 scripts/40-down.sh`. Exports labs to blob, releases
   the license, destroys the VM. The switch running configs die with
   it; the reference files in `labs/` are the source.
2. `scripts/00-preflight.sh`, then `ASSUME_YES=1 scripts/20-up.sh`.
   The hook fetches only `ftdv-10-0-0` and keeps the other ten.
3. Wait for `ready: true`, since the host reboots once after the
   install, then `scripts/90-smoke-test.sh`.
4. The tunnel connector: step 4 of `docs/ACCESS.md`, or the one-line
   SSH form from this entry, with the token and the sysadmin password
   on stdin.
5. `scripts/60-import-lab.sh labs/cilium-evpn-blank.yaml`, start the
   six switches, push `labs/cilium-evpn-fabric/` through cml-mcp,
   about three minutes. Start the NAT node too; it was never started
   on 2026-09-10, so the kind host had no internet.
6. Set `CDFMC_HOST` and the per-node `CDFMC_REG_KEY_FTD1`,
   `CDFMC_NAT_ID_FTD1`, `CDFMC_REG_KEY_FTD2`, `CDFMC_NAT_ID_FTD2` in
   `config/mcp-env/labs.env` from two Security Cloud Control
   onboardings with the CLI registration key method, then
   `scripts/60-import-lab.sh labs/ftdv-cluster.yaml`. Start n9k1,
   n9k2, edge, push `labs/ftdv-cluster-fabric/`, then the hosts, then
   the two FTDv nodes last. Only one of the two labs runs at a time.
7. First real run of `scripts/70-users.sh --dry-run`, then without,
   from a `config/mcp-env/users.csv` started from the example. Add the
   printed emails to the Access policy.
8. Still standing: refresh the tunnel token, taint the admin
   `random_password`, narrow the Access policy to the peer's exact
   address, test a node console through the tunnel.

Late in the evening the Cilium lab was stopped, not wiped, so the
fabric's saved configs survive a start. FTDv 10.0.0 went onto the data
disk in place: dropfolder plus the definitions API (LESSONS-LEARNED),
no rebuild. Steps 1 and 2 of the order above are therefore optional
for the FTDv lab; they remain the right thing when the box is cycled
anyway. Blocked on the operator: five cdFMC values in
`config/mcp-env/labs.env` from two device onboardings in Security
Cloud Control, one key per device.

The FTDv cluster lab is prepared and untested: spec, topology,
reference configs, and the renderer now fills any `__NAME__` from the
env file, not just the password. The tenant checks are the operator's:
FTDv entitlements and acceptance of version 10.0.0. FTD enforces
password complexity, so the lab password must carry upper case, lower
case, and a digit.

## 2026-09-08

Built again in the morning for use: preflight 53 OK, build in under five
minutes, smoke test 10 OK, connector reinstalled by hand. Torn down the
same evening with the license released; no VM exists. A peer's CML
account was verified against the API; the block was the Access policy,
which now also admits cisco.com addresses domain-wide. Narrow that to
the one address when the test is done. Roadmap item 6 records the user
CSV decision; ACCESS.md gained an "Adding a person" section.

## 2026-09-07

### Where things stand

Torn down at the end of the session with the license released. The next
`20-up.sh` brings back a controller with ten images on the data disk: the original
five, Nexus 9300v, and the Catalyst SD-WAN Manager, Validator, Controller,
and edge. The image copy patch is proven. The rebuild found 16 files,
kept them, and fetched only the five new images; the post phase counted
30 and the smoke test reads 10 OK. The host key fix passed its first
real rebuild: SSH went in through `keys/known_hosts` with no complaint.
CML lists all twelve node definitions through cml-mcp. The tunnel
connector is reinstalled and the name answers.

The SD-WAN images came from the supplemental ISO. The upload script
checks names against one mounted ISO at a time, so they went up with
`REFPLAT_ISO` pointing at that ISO and `REFPLAT_FILE` holding only their
four lines. `config/refplat.txt` carries all ten for the build and says so
in a comment.

### Done today

- Preflight, SD-WAN upload of 5 GB, preflight again at 53 OK, build,
  smoke test, connector. Steps 1 to 5 of the seven-step close-out.
- Fork `fdf539c` proven on a real host. Lesson closed with the log line.
- Roadmap: Nexus and SD-WAN moved to Done; the image library item now
  says images can come from more than one ISO.
- Browser login through the front door confirmed again on the rebuilt
  host. The login page shows the Zero Trust team domain, which every
  Access application in the account shares; it is not another tunnel.

### Pick up here

1. Refresh the tunnel token in the Cloudflare dashboard, since the old
   one passed through a Claude session. Put the new one in
   `config/mcp-env/cloudflare-tunnel.env` and rerun step 4 of
   `docs/ACCESS.md` on the host.
2. A node console through the tunnel: one iosv lab, start it, open the
   console at `lab.rooez.com`. Login was confirmed on 2026-09-07; a
   console specifically was not.
3. Task 21, ticked against what the last three days already covered.
4. Then design work. The Terminal UI spec is the natural next piece;
   three later roadmap items assume it.

If a bigger box is wanted, `vm_size` in `config/cml.tfvars` is the only
change: E20ds_v6 is 20 vCPU and 160 GB, E32ds_v6 is 32 and 256, both
inside the approved family quota of 64. Takes effect at the next cycle.

### Watch out for

- The SD-WAN Manager's data volume is thin but lives on the 200 GB OS
  disk with every node overlay. A Manager left running for days is the
  first thing that fills it.
- The tunnel connector still needs the manual reinstall after every
  build until roadmap item 6 exists.

## 2026-09-05, end of day

### Where things stand

No CML VM exists. The second teardown of the day finished at 23:30 UTC
with the license released and thirteen resources destroyed. Only the
persistent root is billing: the 512 GB data disk with six images on it,
the static IP, and the storage account. The tunnel shows Down in
Cloudflare until a connector runs again.

Everything that was uncommitted an hour ago is committed. The fork carries
the image copy fix at `fdf539c`, pushed to `azure-lab`, and this repo
points at it from `00c83b1` together with the test that proves the logic
on the Mac. That fix has never run on a real host. Proving it is the next
command.

### Pick up here

1. `scripts/00-preflight.sh`. The marker from tonight will have expired.
   Expect 45 OK. It also confirms the six images in blob.
2. `ASSUME_YES=1 scripts/20-up.sh`. About ten minutes. Two things to
   look for on the new host: the persistence log at
   `/var/log/provision/05-persist-pre.log` should say "5 of 6 listed
   images already there, copying: nxosv9300-10-6-2-f", and SSH should
   just work, because the up script now forgets the old host key from
   `keys/known_hosts` before it builds. If the persistence line still
   says "emptying refplat image list", the build used a stale fork
   checkout; check `git -C vendor/cloud-cml log -1` says `fdf539c`.
3. `scripts/90-smoke-test.sh`, expect 10 OK, and the image count should
   read 18 files.
4. Reinstall the tunnel connector, step 4 of `docs/ACCESS.md`, token in
   `config/mcp-env/cloudflare-tunnel.env`. Then refresh that token in the
   Cloudflare dashboard, since it passed through a Claude session, update
   the file, and run the install once more.
5. Close the lesson "The rebuild keeps the images, but a new image never
   arrives" with the real log line, and move Nexus on the roadmap to Done.
6. A node console through the tunnel: create a one-router lab, start it,
   open the console at `lab.rooez.com`. Last path never tried.
7. Task 21, the seven verification steps. Most are done by the day's
   events; tick them against the plan rather than repeating them.

VPN on or off no longer matters for any of this. Both addresses are in
tfvars and the build renders them.

### Earlier the same day

The controller was built, torn down, and rebuilt, and the smoke test was
all green on the second host, 10 OK. Teardown released the
license and the status went to `NOT_REGISTERED`, which is what the
down script gates on. The rebuild found the data disk formatted,
reused the 15 image files, and reached a ready API in under five
minutes instead of thirteen. The NSG came back from tfvars with both
address entries and the fork's plan is quiet. The persistent plan shows
no changes. That is the persistence design proven end to end.

Two things the cycle exposed, both in LESSONS-LEARNED. Host keys change
on every rebuild and the scripts now keep them in a repo-local file.
And the persistence hook skips every image when any exist, so Nexus
did not land; that fix is a fork patch and still open.

Earlier the same day, the first build. The smoke test was
all green, 10 OK. `scripts/20-up.sh` took about 20 minutes and created 13
resources. CML 2.10.0 build 13 sits at the persistent public IP, the API
answers, cml-mcp lists labs, and the MCP env file is written. The 2.10
package installed under the 2.9.0 fork without complaint. The persistence
hook found the data disk on the NVMe by-lun link, formatted it, mounted
`/data`, and copied all 15 image files. The license registered and reports
`COMPLETED`, the first time that string has been seen for real. Both open
risks from the 2026-09-04 handoff are closed.

Getting SSH to work took most of the afternoon. The Mac was on Cisco
Secure Client, which shows Azure three different source addresses
depending on the port. See LESSONS-LEARNED, "SSH to the host times out".
The two NSG rules were patched by CLI to admit `151.186.182.0/24` and the
home /32. `config/cml.tfvars` and the rendered `cml.yml` carry the same
lists, so the next build renders them into the VM. Until then the fork's
plan shows the VM as "must be replaced", and applying it would be a
20 minute rebuild by accident.

You use the lab from the VPN on purpose, so it can pair with VPN-only
resources later. Off the VPN, the home /32 is already allowed, so both
paths work.

### Done today

- First real build. VM `cml-controller`, E16ds_v6, in `rg-cml-lab`.
- Diagnosed the three-path VPN problem and patched both NSG rules.
- Smoke test fix: count images in the listable subdirectories, because
  `/data/images` itself is 0711.
- Remote library: deregister treats `COMPLETED` as still licensed. Test
  added with a fake controller that reports it.
- Upload script: the package copy redirects stdin. Without that the test
  suite hangs from any runner that keeps stdin open.
- Three lessons entries and the tfvars example comment.
- cml-mcp tested from the shell against the live controller: statistics,
  node definitions, definition detail. 51 tools. The Claude Code wiring
  in `.mcp.json` needs a session restart to pick up the env file.
- `docs/ROADMAP.md` created. Terminal UI, credential wizard, lab
  calculator, free certificate, lab repositories, Nexus, AWS port.
- Web UI checked by hand: logged in at the IP, five image definitions
  present.
- `docs/ACCESS.md`: the Cloudflare Tunnel procedure, by hand for now.
  The connector is the Debian package under systemd rather than a
  container, because CML runs Docker for its own container nodes. Linked
  from the prerequisites, the README, and the roadmap.
- The front door works end to end. cloudflared 2026.8.3 went onto the
  controller from the Mac over SSH with the token from the gitignored env
  file, and registered four connections. In Cloudflare: a published route
  to local 443, and an Access application `lab` with policy `Owner`, own
  domain plus one exact address. Checked from the shell, the name resolves
  to Cloudflare with a Let's Encrypt cert and a 302 to the Access login.
  Checked in a browser, the one-time code arrives by mail and the CML
  login page shows a clean padlock.
- The A record `lab.rooez.com` made earlier had to go first. It had been
  proxied all along, which is why the name never worked directly.
- Nexus 9300v 10.6.2 uploaded to blob, 2.8 GB, sixth line in
  `config/refplat.txt`. The upload script now ignores the add-on ISOs
  beside the base one, so the supplemental ISO can stay in `software/`.
- Fork patch for the image copy, 21 lines in the persistence hook plus
  one test case. Tested on the Mac, shellcheck clean, awaiting the commit.
- First teardown and rebuild, VPN on for the teardown and off for the
  rebuild. Both worked. Host key handling fixed in the scripts with
  tests. The tunnel connector was reinstalled on the new host by hand.

### Watch out for

- The NSG dies with the VM and comes back from tfvars. Proven today.
- The exit pool inside `151.186.182.0/24` rotates per connection. Never
  narrow that entry to a /32.
- The home address is a residential dynamic IP and will change.
- The Mac ran out of memory twice today and killed background Terraform
  runs. Quit Office and the browser before a build.

## 2026-09-04

### Where things stand

The Cisco downloads are in progress: `cml2_2.10.0-13_amd64-17.pkg` and
`refplat-20260409-fcs.iso`, into `software/`. Cisco only offers 2.10 now.
The fork tracks cloud-cml v2.9.0 and upstream has nothing for 2.10 yet, so
the first build is also the first test of that pairing.

Earlier today the quota problem went away by changing the target. The
Edsv5 family could not be raised above zero by the automatic approver, at
64 or at 32. The default size is now `Standard_E16ds_v6`, same 16 vCPU and
128 GB on a 2024 CPU, and its family was approved at 64 with the regional
total at 118. Because v6 attaches disks over NVMe, the fork's persistence
hook now looks for the LUN 0 disk on the NVMe link first and the SCSI link
second. ADR 0005. Nothing applied in Azure changed. Fork at `71697be`, repo
at `0134c7e` for that work.

### Done today

- Quota: Edsv6 64, regional 118, eastus2.
- Fork: the persistence hook finds the data disk on either link. Two new
  assertions in `tests/test_persist.sh`. Submodule pointer bumped.
- Default size, example package name, prerequisites, spec, README, refplat
  comment, ADR 0005, and a lessons entry all say v6 and 2.10.

### Next, in order

1. Done. Both files are in `software/` and git ignores them. Still owed:
   `checksum.txt` from the download page, to compare against the SHA-256
   values recorded in the 2026-09-04 session.
2. Done. Four of five image names had moved; `config/refplat.txt` now
   matches the April 2026 ISO.
3. Done. `config/cml.tfvars` exists with the Enterprise flavor, 20 nodes,
   the token, and the public IP in both lists. Still owed:
   `ARM_SUBSCRIPTION_ID` in the shell profile. Preflight was run with it
   supplied inline.
4. Done. Preflight on 2026-09-04 evening: 31 OK, 1 WARN (blob checks
   skipped, persistent root not applied), 0 FAIL.
5. Done 2026-09-04 evening. `terraform/persistent` is applied: 19
   resources, `rg-cml-lab`, storage account `stcmllabwqspyl`, and a plan
   shows no changes. The apply failed once on the storage account with a
   409 and needed one import; see LESSONS-LEARNED. The 512 GB disk bills
   from now.
6. Done. The package and the five images are in the `cml` container, 16
   blobs and 2.8 GB. The first upload run silently stopped after one image
   because azcopy ate the loop's stdin; fixed and tested, see
   LESSONS-LEARNED. Preflight: 43 OK, 0 WARN, 0 FAIL.
7. `scripts/20-up.sh` to a running CML. A human says go. Then plan
   Task 21, the seven verification steps.

### Watch out for

- The NVMe by-lun link has never been seen on a real boot from this repo.
  If the persistence log says no data disk appeared on either path, set
  `DATA_DEV` to `/dev/nvme0n2` in the fork's cloud-config and rebuild.
- The v6 local temp disk is raw and unmounted. Nothing should care.
- If the 2.10 package fails to install under the 2.9.0 fork, the fix is
  an upstream merge on the fork, which needs a human per CLAUDE.md.

## 2026-09-02

### Where things stand

The repo is built and every local gate is green. Both durable Terraform
roots exist, the fork carries its ten patches plus one fix, and all seven
operator scripts have dry-run tests. In Azure, only the bootstrap root has
been applied: resource group `rg-cml-lab-tfstate` and storage account
`st792kcotfstate`, which cost cents. The persistent root has been validated
and planned at 19 resources but not applied, because its 512 GB Premium
disk starts billing the moment it exists. No CML VM has ever been built
from this repo.

### Done

- CLAUDE.md, the settings allowlist, pre-commit, and gitleaks with custom
  rules for Smart License tokens and Azure storage keys
- `terraform/bootstrap` applied; `terraform/persistent` validated and
  planned
- The fork `itsAmeMario0o/cloud-cml` on branch `azure-lab`, patches 0 to
  10 plus one fix commit, pinned as the submodule
- Scripts 00, 10, 20, 30, 40, 50, and 90, each with a dry-run test
- The `tests/run.sh` gate
- ADRs 0001 to 0004

### Deferred on purpose

The persistent apply waits for the images and the quota, because the disk
bills from creation and nothing can use it until then. The first real CML
build and the seven verification steps are plan Task 21. Lab topologies,
ISE, FTD, the host bridge, and the C8000v edge belong to later specs.

### Watch out for

- Edsv5 quota in eastus2 was zero on 2026-09-02. Preflight fails until the
  request is approved.
- `config/refplat.txt` names images from the June 2025 ISO. Check them
  against the newer ISO before uploading.
- azurerm is pinned to 4.x in all three roots. Do not let `init -upgrade`
  pull 5.x.
- The smoke test's expected license status string has never been seen on a
  real controller. It accepts two values for now. See LESSONS-LEARNED.

### Next

1. You: license, token, downloads into `software/`, quota, and
   `ARM_SUBSCRIPTION_ID` in your shell profile.
2. `scripts/00-preflight.sh` until everything but the blob checks is green.
3. `scripts/20-up.sh` through the persistent apply, then
   `scripts/10-upload-images.sh`.
4. `scripts/00-preflight.sh` fully green, then `scripts/20-up.sh` all the
   way to a running CML.
5. Plan Task 21, the seven verification steps.
