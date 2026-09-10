# Status

Dated handoff, newest entry first. Read this before doing anything else in
a new session.

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
and blue with anycast gateways. Not yet applied to a switch.

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

1. If the VM was torn down: preflight, `ASSUME_YES=1 scripts/20-up.sh`,
   wait for ready, smoke test, then the connector from `docs/ACCESS.md`.
2. `config/mcp-env/labs.env` exists with a real password. After a
   teardown the lab is gone with the VM, so rerun
   `scripts/60-import-lab.sh labs/cilium-evpn-blank.yaml`.
3. Start spines, then leaves, then hosts. Confirm the switches reach a
   login prompt and the kind host has Docker and kind installed.
   Neither has been tried yet.
4. First real run of `scripts/70-users.sh --dry-run`, then without,
   from a `config/mcp-env/users.csv` started from the example. Add the
   printed emails to the Access policy.
4. The earlier items still stand: refresh the tunnel token, narrow the
   Access policy to the peer's exact address, test a node console
   through the tunnel.

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
