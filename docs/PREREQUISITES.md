# What you need to provide before the first CML build

Written 2026-09-02, updated 2026-09-04. Everything on this list is
something only you can do: buy, download, log in, or approve. None of it
blocked building the repo, and section 5 says what exists already. The
quota is done. The downloads are the slow part now.

## 1. Cisco license and software

### 1.1 Buy a CML license

cloud-cml accepts `CML_Personal` (20 nodes), `CML_Personal40` (40 nodes),
`CML_Education`, or `CML_Enterprise`. Buy Personal or Personal Plus from the
Cisco Learning Network Store:

https://learningnetworkstore.cisco.com/cisco-modeling-labs-personal

Node counts that matter for the planned scenarios, per running lab:

| Scenario | Nodes, roughly |
|---|---|
| Nexus 9000v spine-leaf, 2 spines, 4 leaves, 2 hosts | 8 |
| Catalyst SD-WAN, 3 controllers, 2 edges, 2 hosts | 7 |
| TrustSec fabric, C8000v edge, 3 switches, 3 endpoints | 7 |

Personal (20) covers any one scenario. Personal Plus (40) covers two running
at once. The license ties to your CCO account, which is also what unlocks the
software downloads in 1.3.

### 1.2 Generate a Smart License token

1. Sign in at https://software.cisco.com and open Smart Software Manager.
2. Inventory, General tab, New Token.
3. Set the expiry to the maximum, 365 days. Leave "Allow export-controlled
   functionality" unchecked.
4. Copy the token. It goes into `config/cml.tfvars` as `smartlicense_token`.
   That file is gitignored. Never paste it anywhere else in the repo.

The flavor you bought goes into `config/cml.tfvars` as `license_flavor`.

### 1.3 Download the software

From https://software.cisco.com/download/home, product "Cisco Modeling Labs".
On 2026-09-04 the only version offered was 2.10, so that is what we use.
cml-mcp needs 2.9 or newer.

Download these three:

| File | What it is | Size |
|---|---|---|
| `cml2_2.10.0-13_amd64-17.pkg` | The CML package. Not the `.iso` or `.ova` installer with the same name. | about 1 GB |
| `refplat-20260409-fcs.iso` | The full base reference platform set. Not the `-free` subset. | 15 to 40 GB |
| `checksum.txt` | Verify both files against it before doing anything else. | tiny |

Skip the `-ise`, `-supplemental`, `-proprietary`, and `-wireless` ISOs for
now. The supplemental one holds the SD-WAN controllers and FirePower, and
the first build does not use them. It also would match the upload script's
`refplat-*.iso` pattern and make it refuse to run with two candidates. Get
it when the SD-WAN scenario has its own spec.

One caveat on the version. The fork tracks cloud-cml v2.9.0, and upstream
has published nothing for 2.10 as of today; its main branch is two
documentation commits past v2.9.0. The installer is a Debian package on
the same Ubuntu 24.04 base, so the pairing should work, but the first build
is the first test of it.

There is an older refplat from June 2025 in `~/Downloads`. Do not use it.
It did not carry the SD-WAN controller images at all.

### 1.4 Where to put the files

Put both files, plus the `.signature` and `.README` that come with the ISO,
in the repo's `software/` folder:

```
cml-azure-lab/software/
```

Everything in the project stays inside the project. That folder holds only a
self-ignoring `.gitignore` and a `README.md` under version control. Every
other file in it is ignored, and the root `.gitignore` also blocks `*.iso`,
`*.pkg`, and `*.qcow2` everywhere as a second guard. Verify with
`git status` after copying: the files must not appear.

The scripts read the location from `CML_SOFTWARE_DIR`, default
`<repo root>/software`.

The ISO is never extracted. The upload script mounts it read-only, copies the
`.pkg` plus only the node definitions and images the scenarios need into the
`cml` blob container, and unmounts. Nothing is written back to the folder.

Because the repo sits under OneDrive, a large ISO will sync. If OneDrive
later turns it into an on-demand placeholder, right-click it in Finder and
choose "Always Keep on This Device" before running the upload script.

Once the files are there, put the exact `.pkg` filename into
`config/cml.tfvars` as `software_package`. Today that is
`cml2_2.10.0-13_amd64-17.pkg`, and the example file already carries it. The
ISO is found by name pattern, so it needs no setting. Then check that the
image names in `config/refplat.txt` match the folders on the new ISO; the
upload script refuses to run if any of them do not.

Only the images the scenarios need get uploaded. The full ISO would not fit
through the four hour SAS window the spec allows, and you would be paying to
store images nothing uses.

ISE is not a refplat image and stays outside CML per the spec, so no ISE
download is needed for sub-project 1.

## 2. Azure

### 2.1 Raise the vCPU quota

Done 2026-09-04. `Standard Edsv6 Family vCPUs` in `eastus2` is 64 and
`Total Regional vCPUs` is 118. The floor size `Standard_E16ds_v6` needs 16,
`E32ds_v6` needs 32.

For the record, in case it has to be repeated on another subscription: the
portal's Quotas page, Compute, region East US 2, tick the family, New Quota
Request. The automatic approver refused every v5 family outright on this
subscription, at 64 and again at 32, and refused Edsv6 once at 32 before the
increase to 64 went through. Ask for the family and the regional total
together. Spot instances draw from the same family quota, so the request is
needed either way.

### 2.2 Shell environment

Add to your shell profile:

```sh
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
```

The scripts refuse to run without it, and the subscription ID is never
committed. `az login` is already valid on this Mac.

### 2.3 Values for `config/cml.tfvars`

Copy `config/cml.tfvars.example` to `config/cml.tfvars` and fill in:

| Key | What to put |
|---|---|
| `smartlicense_token` | From 1.2 |
| `license_flavor` | From 1.1: `CML_Personal`, `CML_Personal40`, `CML_Education`, or `CML_Enterprise` |
| `allowed_ipv4_subnets_mgmt` | Your public IP as `/32`. Get it with `curl -4 ifconfig.me`. SSH and Cockpit. |
| `allowed_ipv4_subnets_cml2` | Same `/32`. The CML UI and API, which is what cml-mcp uses. |
| `vm_size` | `Standard_E16ds_v6` to start. Any size with nested virtualization works; v6 and v7 attach disks over NVMe and the fork handles both. ADR 0005. |
| `spot_enabled` | `false` for the first build. Turn on once the persist path is proven. |

Also for the persistent root's `terraform.tfvars`: `owner` (your name or
email) and `expires` (a date, used only as a tag).

## 3. GitHub

Done 2026-09-02. Fork at https://github.com/itsAmeMario0o/cloud-cml with
branch `azure-lab` created from tag `v2.9.0`, commit `b32edd5`.

## 4. Tools on the Mac

Installed 2026-09-02: azcopy 10.32.8, shellcheck 0.11.0, gitleaks 8.30.1.
Already present: terraform 1.5.7, az 2.89, jq, uv, pre-commit, gh, python3.
Terraform 1.5.7 is old enough that every root pins `required_version =
">= 1.5"` and avoids newer syntax, so do not upgrade it without a reason.

## 5. What has been built, and what still gates the first build

The repo is built. This is what is true today:

- `terraform/bootstrap` is applied in Azure: resource group
  `rg-cml-lab-tfstate`, storage account `st792kcotfstate`. It costs cents.
- `terraform/persistent` is validated and planned, 19 to add, but not
  applied. It is held until the images are on the Mac, because the 512 GB
  Premium data disk bills about 75 USD a month from the moment it is
  created.
- The fork branch `azure-lab` carries patches 0 to 10 plus three fix
  commits, pinned as the submodule. The last one teaches the persistence
  hook to find the data disk on NVMe sizes, which the default v6 size is.
  `validate` passes against the rendered config template with placeholder
  values.
- All seven scripts (00, 10, 20, 30, 40, 50, 90), `CLAUDE.md`,
  `.claude/settings.json`, pre-commit, gitleaks rules, four ADRs,
  `STATUS.md`, `LESSONS-LEARNED.md`, and the `tests/run.sh` gate all exist
  and pass.
- An upload script for the `.pkg` and the selected refplat images, tested
  against an empty folder.
- `00-preflight.sh` runs today and fails on the missing token, images, and
  quota. That is what it is for. Watching it go green one line at a time is
  the checklist.
- No CML VM has ever been built from this repo.

What still gates the first build: sections 1 and 2 above, in full. Until
then, the persistent apply, the CML build itself, `20-up.sh` past the
persistent root, the smoke test, export, down, and cml-mcp stay out of
reach. Those are spec success steps 2 through 7.

## 6. Checklist

- [ ] License bought, flavor known
- [ ] Smart License token generated, pasted into `config/cml.tfvars`
- [ ] `cml2_2.10.0-13_amd64-17.pkg`, `refplat-20260409-fcs.iso`, and
      `checksum.txt` in `software/`, checksums verified. Downloading as of
      2026-09-04.
- [x] Quota approved: Edsv6 family 64 and regional 118 in eastus2
- [ ] `ARM_SUBSCRIPTION_ID` exported in shell profile
- [ ] Public IP known for the two allowed-subnet lists
- [x] Fork created, branch `azure-lab` at v2.9.0
- [x] azcopy, shellcheck, gitleaks installed
