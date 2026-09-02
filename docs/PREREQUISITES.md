# What you need to provide before the first CML build

Written 2026-09-02. Everything in this list is something only you can do:
buy, download, log in, or approve. Nothing here blocks building the repo.
See section 5 for what gets built without any of it.

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

Tell me which flavor you bought. It goes into `config/cml.yml.tftpl` under
`license.flavor`.

### 1.3 Download the software

From https://software.cisco.com/download/home, product "Cisco Modeling Labs",
version 2.9.x. cml-mcp needs 2.9 or newer, so do not pick 2.8.

Download exactly these two items:

| File | What it is | Size |
|---|---|---|
| `cml2_2.9.x_amd64-N.pkg` | The "update package". Not the OVA, not the ISO installer. | about 1 GB |
| `refplat-YYYYMMDD-fcs.iso` | Reference platform images, latest release | 15 to 40 GB |

An older refplat from June 2025 sits in `~/Downloads/refplat-20250616-fcs-iso/`.
Decision on 2026-09-02: do not use it, get the current one so the SD-WAN and
Nexus images are recent.

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

Tell me the exact `.pkg` filename and the ISO filename once they are there.

The refplat ISO gets mounted on the Mac and only the images the scenarios need
get uploaded. The full ISO is too large for the four hour SAS window in the
spec. The upload script in this repo handles the selection.

ISE is not a refplat image and stays outside CML per the spec, so no ISE
download is needed for sub-project 1.

## 2. Azure

### 2.1 Raise the vCPU quota

Current quota in `eastus2` is zero for every v5 family and 24 total regional
cores. The floor size `Standard_E16ds_v5` needs 16, `E32ds_v5` needs 32.

1. Azure portal, search "Quotas", Compute, filter region `East US 2`.
2. Request `Standard EDSv5 Family vCPUs`: 32 minimum, 64 if you want the
   E32ds_v5 option for the TrustSec scenario.
3. Request `Total Regional vCPUs` to the same number or higher.
4. Pay-as-you-go subscriptions often get an automatic approval for small
   numbers and a support case for larger ones. Start the request today. It can
   take one to three business days.

Spot instances draw from the same family quota, so this is needed either way.

### 2.2 Shell environment

Add to your shell profile:

```sh
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
```

The scripts refuse to run without it, and the subscription ID is never
committed. `az login` is already valid on this Mac.

### 2.3 Values for `config/cml.tfvars`

I will generate `config/cml.tfvars.example`. You copy it to
`config/cml.tfvars` and fill in:

| Key | What to put |
|---|---|
| `smartlicense_token` | From 1.2 |
| `allowed_ipv4_subnets_mgmt` | Your public IP as `/32`. Get it with `curl -4 ifconfig.me`. SSH and Cockpit. |
| `allowed_ipv4_subnets_cml2` | Same `/32`. The CML UI and API, which is what cml-mcp uses. |
| `vm_size` | `Standard_E16ds_v5` to start |
| `spot_enabled` | `false` for the first build. Turn on once the persist path is proven. |

Also for the persistent root's `terraform.tfvars`: `owner` (your name or
email) and `expires` (a date, used only as a tag).

## 3. GitHub

The spec pins cloud-cml as a submodule from a fork. No fork exists yet.
Say "create the fork" and I will run it with `gh` under `itsAmeMario0o`,
branch `azure-lab` from tag `v2.9.0`. Or fork it yourself in the browser and
tell me when it exists.

## 4. Tools on the Mac

Missing today: `azcopy`, `shellcheck`, `gitleaks`. Install with:

```sh
brew install azcopy shellcheck gitleaks
```

Already present: terraform 1.5.7, az 2.89, jq, uv, pre-commit, gh, python3.
Terraform 1.5.7 is old enough that I will pin `required_version = ">= 1.5"`
rather than assume newer syntax.

## 5. What gets built without any of the above

All of it except the CML VM itself:

- `terraform/bootstrap` and `terraform/persistent`: written, `fmt`,
  `validate`, and `plan` all pass. Bootstrap can be applied now, it costs
  cents. Persistent is held until images exist, because the 512 GB Premium
  data disk bills about 75 USD a month from the moment it is created.
- The fork branch with all ten patches: `validate` passes against the
  rendered config template with placeholder values.
- All six scripts, `CLAUDE.md`, `.claude/settings.json`, pre-commit, gitleaks
  rules, four ADRs, `STATUS.md`, `LESSONS-LEARNED.md`.
- An upload script for the `.pkg` and the selected refplat images, tested
  against an empty folder.
- `00-preflight.sh` runs today and fails on the missing token, images, and
  quota. That is the intended behaviour and a real test of the script.

What cannot happen until sections 1 and 2 are done: `20-up.sh` past the
persistent root, the smoke test, export, down, and cml-mcp. Those are spec
success steps 2 through 7.

## 6. Checklist

- [ ] License bought, flavor known
- [ ] Smart License token generated, pasted into `config/cml.tfvars`
- [ ] Latest `.pkg` and refplat ISO placed in `software/`, exact filenames shared
- [ ] Quota request submitted for EDSv5 and regional cores in eastus2
- [ ] `ARM_SUBSCRIPTION_ID` exported in shell profile
- [ ] Public IP known for the two allowed-subnet lists
- [ ] Fork created, or permission given to create it
- [ ] `brew install azcopy shellcheck gitleaks` done, or permission given
