# Status

Dated handoff, newest entry first. Read this before doing anything else in
a new session.

## 2026-09-04

### Where things stand

Quota is solved and the default VM size moved from `Standard_E16ds_v5` to
`Standard_E16ds_v6`. The Edsv5 family could not be raised above zero by the
automatic approver; Edsv6 was approved at 64 and the regional total at 118
in eastus2. The v6 sizes attach disks over NVMe, so the fork's persistence
hook now looks for the LUN 0 disk on the NVMe link first and the SCSI link
second. ADR 0005. Nothing applied in Azure changed.

### Done

- Fork: `05-persist.sh` finds the data disk on either link; the Terraform
  comment updated. Submodule pointer bumped.
- Default size, prerequisites, spec, ADR 0005, and a lessons entry.
- Quota approved: Edsv6 64, regional 118.

### Still gating the first build

License and Smart License token, the two Cisco downloads into `software/`,
`ARM_SUBSCRIPTION_ID` in the shell profile, public IP in the tfvars file.
Then the persistent apply, which is a human decision because the disk bills
from creation.

### Watch out for

- The NVMe by-lun link has never been seen on a real boot from this repo.
  If the persistence log says no data disk appeared on either path, set
  `DATA_DEV` to `/dev/nvme0n2` in the fork's cloud-config and rebuild.
- The v6 local temp disk is raw and unmounted. Nothing should care.

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
