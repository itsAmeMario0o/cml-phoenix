# Status

Dated handoff, newest entry first. Read this before doing anything else in
a new session.

## 2026-09-05

### Where things stand

The controller has now been built, torn down, and rebuilt, and the smoke
test is all green on the second host, 10 OK. Teardown released the
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
- First teardown and rebuild, VPN on for the teardown and off for the
  rebuild. Both worked. Host key handling fixed in the scripts with
  tests. The tunnel connector was reinstalled on the new host by hand.

### Next, in order

1. Fork patch: the persistence hook copies only the images missing from
   the data disk. Then a down and up cycle to land Nexus. Needs a human
   for the vendor edit and the submodule bump.
2. A node console through the tunnel, the one path never tried.
3. Spec the post-build script, roadmap item 6, so the connector comes
   back without hands.
4. Task 21, the seven verification steps. Several are now done by
   accident of today; tick them off against the plan.
5. Refresh the tunnel token in Cloudflare and rerun the install.

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
