# Status

Dated handoff. Newest entry first. Read this before doing anything.

## 2026-09-02

### Where things stand

Repo skeleton, both durable Terraform roots, the fork with ten patches plus
one fix commit, and all seven operator scripts exist and pass
`tests/run.sh` and pre-commit. Bootstrap has been applied in Azure
(resource group `rg-cml-lab-tfstate`, storage account `st792kcotfstate`).
Persistent has been validated and planned, 19 to add, but not applied. No
CML VM has ever been built from this repo.

### Done

- CLAUDE.md, settings allowlist, pre-commit, gitleaks with custom rules
- `terraform/bootstrap` applied, `terraform/persistent` validated and
  planned (19 to add, not applied)
- Fork `itsAmeMario0o/cloud-cml` branch `azure-lab`, patches 0 to 10 plus
  one fix commit, pinned as the submodule
- Scripts 00, 10, 20, 30, 40, 50, 90 with dry-run tests
- `tests/run.sh` gate
- ADRs 0001 to 0004

### Deferred on purpose

- Persistent apply: waits for images and quota, because the disk bills from creation
- The first real CML build and the seven verification steps (plan Task 21)
- Lab topologies, ISE, FTD, the host bridge and C8000v edge: later specs

### Watch out for

- Quota in eastus2 for Edsv5 was 0 on 2026-09-02. Preflight fails until the request is approved.
- `config/refplat.txt` names images from the June 2025 ISO. Update from the newer ISO before uploading.
- azurerm is pinned to 4.x in all three roots. Do not let init pick 5.x.

### Next

1. Human: license, token, downloads into `software/`, quota, `ARM_SUBSCRIPTION_ID`.
2. `scripts/00-preflight.sh` until green except blobs.
3. `scripts/20-up.sh` through the persistent apply, then `scripts/10-upload-images.sh`.
4. `scripts/00-preflight.sh` fully green, then `scripts/20-up.sh` to the CML build.
5. Plan Task 21.
