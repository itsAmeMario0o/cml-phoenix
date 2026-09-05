# Status

Dated handoff, newest entry first. Read this before doing anything else in
a new session.

## 2026-09-05

### Where things stand

The first CML controller from this repo is running. `scripts/20-up.sh`
finished in about 20 minutes, 13 resources, CML 2.10.0 build 13 at the
persistent public IP, API answering, MCP env file written. The 2.10
package installed under the 2.9.0 fork without complaint. The persistence
hook found the data disk on the NVMe by-lun link, formatted it, mounted
`/data`, and copied all 15 image files. Both risks from the 2026-09-04
handoff are closed.

The smoke test came back 4 OK and 6 FAIL. One failure was cml-mcp timing
out on its first-run package install and it passes on a rerun. The other
five all ran over SSH, and SSH cannot reach the host from this Mac while
the VPN is on. See LESSONS-LEARNED, "SSH to the host times out". The host
side is fine, verified through `az vm run-command`. Fixing it through
Terraform would replace the VM, so nothing has been applied.

`config/cml.tfvars` now carries both of the Mac's public addresses. The
deployed NSG rules still carry only the proxy one, so until the next
rebuild or a manual NSG patch, the web UI and API work from the VPN and
SSH does not. With the VPN off, nothing reaches the lab, because the NAT
address is not in the deployed rules at all.

### Done today

- First real build. VM `cml-controller`, E16ds_v6, in `rg-cml-lab`.
- Verified on the host: sshd on 1122, firewalld allows it, `/data` on
  `nvme0n1p1`, bind mount active, cloud-init done.
- Diagnosed the two-address VPN problem. Lessons entry, tfvars comment.
- Preflight 43 OK and persistent plan clean before the build.
- The upload script's package copy now redirects stdin. Without it the
  test suite hangs when stdin is open and idle. Lessons entry.

### Next, in order

1. Decide VPN or not for this lab, then make the NSG match. Either patch
   the two rules by CLI now, or rebuild through 40-down and 20-up so the
   new tfvars render into the VM.
2. `scripts/90-smoke-test.sh` all green, including the license status,
   which has still never been seen on a real controller.
3. Task 21, the seven verification steps. The rebuild in step 1 doubles as
   the persistence test if `/data` keeps its images.
4. A DNS name in Cloudflare for the public IP, DNS only, no proxy.

### Watch out for

- The fork's `terraform plan` shows the VM as "must be replaced" until the
  deployed allow-lists and `config/cml.yml` agree. Do not apply the fork
  root by hand to fix SSH; that is a 20 minute rebuild.
- The NAT address is a residential dynamic IP and will change.
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
