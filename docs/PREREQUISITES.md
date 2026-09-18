# What you need to provide before the first build

The short list of things only you can do: buy the license, download the
software, sign in, get the Azure quota approved, and accept the ISE
Marketplace terms. `docs/BUILD-FROM-SCRATCH.md` phase 0 gives the order to
do them in; this document gives the detail.

## 1. Cisco license and software

### 1.1 The CML license

This lab runs the `CML_Enterprise` flavor: a `CML - Base` license and a
pool of `CML - Nodes` in a Smart Account. Unlike the Personal flavors,
Enterprise carries no nodes of its own. The controller asks the pool for a
count at registration, which is the `license_nodes` setting, and gives them
back when it deregisters at teardown. Set it to 20.

cloud-cml also accepts `CML_Personal` (20 nodes), `CML_Personal40` (40
nodes), and `CML_Education`, sold through the Cisco Learning Network Store.
Those need `license_nodes` left at 0.

Node counts that matter, per running lab:

| Scenario | Nodes, roughly |
|---|---|
| `cilium-evpn-blank`, 2 spines, 4 leaves, hosts | 11 |
| `ips-ha`, FTD HA pair, Nexus, edge, hosts | 11 |
| `trustsec-phase1`, the C8000v edge and its connector | 2 |
| TrustSec Phase 2 as designed, switches, endpoints, FTD | about 10 |

20 nodes covers any one scenario. 40 covers two running at once. With the
Enterprise pool that is a number in a file rather than a purchase.

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
The kit was built against CML 2.10, the only version offered in September
2026. cml-mcp needs 2.9 or newer.

Download these:

| File | What it is | Size |
|---|---|---|
| `cml2_2.10.0-13_amd64-17.pkg` | The CML package. Not the `.iso` or `.ova` installer with the same name. | about 1 GB |
| `refplat-20260409-fcs.iso` | The full base reference platform set. Not the `-free` subset. | 15 to 40 GB |
| `refplat-<date>-supplemental.iso` | The supplemental set: SD-WAN, Cat9800, FMCv and FTDv, Meraki vMX. Its date need not match the base ISO's. | tens of GB |
| `checksum.txt` | Verify the files against it before doing anything else. | tiny |

`config/refplat.txt`, the one image list the upload, preflight, and the
build read, names thirteen images. Eight are on the base ISO. The four
SD-WAN images and `ftdv` are on the supplemental ISO, which is why it is
in the table. The upload script mounts one ISO at a time and checks every
name against it, so the two sets are uploaded in two runs; phase 1 of
`docs/BUILD-FROM-SCRATCH.md` shows the commands. If you do not want the
supplemental images, that phase also says how to build with the base list
alone, which nobody has done yet. The `-ise`, `-proprietary`, and
`-wireless` ISOs are not used. Add-on ISOs can sit in `software/` beside
the base one: the upload script ignores the add-on suffixes and mounts the
base ISO unless `REFPLAT_ISO` points at another.

One caveat on the version. The fork tracks cloud-cml v2.9.0, which
predates 2.10. The installer is a Debian package on the same Ubuntu 24.04
base, and the pairing has worked on every build so far.

Use a reference platform ISO from 2026 or later. The June 2025 one did not
carry the SD-WAN controller images at all.

### 1.4 Where to put the files

Put the files, plus the `.signature` and `.README` that come with each
ISO, in the repo's `software/` folder:

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
`.pkg` plus only the node definitions and images the list names into the
`cml` blob container, and unmounts. Nothing is written back to the folder.

If the repo sits under a sync client such as OneDrive (ADR 0011), a large
ISO will sync. If the client later turns it into an on-demand placeholder,
right-click it in Finder and choose "Always Keep on This Device" before
running the upload script.

Once the files are there, put the exact `.pkg` filename into
`config/cml.tfvars` as `software_package`; the example file already carries
`cml2_2.10.0-13_amd64-17.pkg`. The ISO is found by name pattern, so it
needs no setting. Then check that the image names in `config/refplat.txt`
match the folders on the ISO; the upload script refuses to run if any of
them do not.

Only the listed images get uploaded. The full ISO would not fit through
the four hour SAS window, and you would be paying to store images nothing
uses.

ISE is not a refplat image. It comes from the Azure Marketplace, section
2.2, so there is no ISE download.

## 2. Azure

### 2.1 Raise the vCPU quota

Three VM families need quota in the region (East US 2 in the tfvars
examples). Ask for all three before anything else, because approval can
take a while, and ask for the family and the regional total together:

| VM | Size | Family | vCPUs |
|---|---|---|---|
| CML host | `Standard_E16ds_v6` to start | Standard Edsv6 Family | 16, or 32 for `E32ds_v6` |
| ISE | `Standard_D8s_v4`, the smallest size ISE 3.5 supports | Standard DSv4 Family | 8 |
| Domain controller | `Standard_B2ms` | Standard BS Family | 2 |

Preflight checks the first (`az vm list-skus` gives it the family name, so
the exact family label is whatever Azure reports for the size). Nothing
checks the other two, so a zero quota shows up as a failed deploy. The
portal path: Quotas, Compute, the region, tick the family, New Quota
Request. On the author's subscription the automatic approver refused every
v5 family outright, and refused Edsv6 once at 32 before 64 went through; a
`B2as_v2` for the DC had no quota at all, which is why it is `B2ms` (ADR
0010). Spot instances draw from the same family quota, so the request is
needed either way. ISE's disk needs no quota; the portal form takes Volume
Size 300 and Disk Storage Type Standard SSD, Cisco's supported minimum and
a third of the idle disk cost of the defaults.

### 2.2 Accept the ISE Marketplace terms

ISE deploys by hand from the Azure Marketplace (ADR 0008; the form is in
`docs/ISE-AD-BUILD.md`, Part 2). The subscription has to accept the
image's terms once. Preflight checks this after
`config/mcp-env/ise.env` exists and prints the exact
`az vm image terms accept` command when the answer is no.

### 2.3 Shell environment

`az login`, select the subscription, then add to your shell profile:

```sh
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
```

The scripts refuse to run without it, and the subscription ID is never
committed.

### 2.4 Values for `config/cml.tfvars`

Copy `config/cml.tfvars.example` to `config/cml.tfvars` and fill in:

| Key | What to put |
|---|---|
| `smartlicense_token` | From 1.2 |
| `license_flavor` | `CML_Enterprise`, see 1.1 |
| `license_nodes` | `20`. Only read for Enterprise. |
| `allowed_ipv4_subnets_mgmt` | Your public IP as `/32`. Get it with `curl -4 ifconfig.me` with any VPN off. On a VPN, add its exit block too; see LESSONS-LEARNED, "SSH to the host times out". SSH and Cockpit. |
| `allowed_ipv4_subnets_cml2` | Same `/32`. The CML UI and API, which is what cml-mcp uses. |
| `vm_size` | `Standard_E16ds_v6` to start. Any size with nested virtualization works; v6 and v7 attach disks over NVMe and the fork handles both. ADR 0005. |
| `spot_enabled` | `false` for the first build. Turn on once the persist path is proven. |

The persistent root's `terraform.tfvars` takes `owner` (your name or
email) and `expires` (a date, used only as a tag), and `24-ad-up.sh` reads
the same file. The other gitignored files, `ise.env`, `labs.env`,
`users.csv`, and `tunnels.conf`, are listed with what they need in
`docs/BUILD-FROM-SCRATCH.md` phase 0.

### 2.5 A DNS name, optional

Nothing in this repo needs one. The scripts, cml-mcp, and the smoke test
all use the public IP, which is static and lives in the persistent root,
so it survives every rebuild. If you want a name, there are two shapes.
A plain A record at your DNS provider pointing at the public IP, DNS
only, no proxy: simple, but the self-signed certificate warning stays and
a proxied record does not work because the NSG only admits your own
addresses. Or a zero trust front door with a real certificate and a login
before CML's own, at no cost. `docs/ACCESS.md` walks through the second
one with Cloudflare as the worked example.

## 3. GitHub

The CML VM is built by a fork of cloud-cml, pinned as the submodule
`vendor/cloud-cml` on branch `azure-lab` (ADR 0001). `git submodule update
--init` after cloning is all a new operator needs. You only need a GitHub
account of your own if you intend to change the fork.

## 4. Tools on the Mac

Preflight looks for `terraform`, `az`, `azcopy`, `jq`, `uv` and `uvx`,
`python3`, `shellcheck`, `pre-commit`, `gitleaks`, and `ssh-keygen`. The
upload script mounts the ISO with `hdiutil`, so the operator side is a Mac.
Versions the kit was built with: terraform 1.5.7, az 2.89, azcopy 10.32.8,
shellcheck 0.11.0, gitleaks 8.30.1. Every root pins
`required_version = ">= 1.5"` and avoids newer syntax, so do not upgrade
Terraform without a reason. `uv` is what runs cml-mcp (`scripts/mcp-cml.sh`
launches it with `uvx`).

For the pyATS verification layer (ADR 0009), build the venv as
`verify/README.md` describes. It is optional; preflight only warns when it
is absent.

## 5. Checklist

- [ ] License in the Smart Account: Enterprise, base plus a node pool
- [ ] Smart License token generated, in `config/cml.tfvars` (gitignored)
- [ ] CML package and both refplat ISOs in `software/`, checksums verified
- [ ] Quota approved: Edsv6, DSv4, and BS families in the region
- [ ] ISE Marketplace terms accepted on the subscription
- [ ] `ARM_SUBSCRIPTION_ID` exported in the shell profile
- [ ] Public IP known for the two allowed-subnet lists
- [ ] Submodule initialized
- [ ] Tools installed; the pyATS venv if you want phase 7
