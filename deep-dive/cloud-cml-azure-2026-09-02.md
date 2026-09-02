# Deep Dive: cloud-cml Azure deployment path

**Generated**: 2026-09-02
**Phase**: Design study before adapting cloud-cml into an on-demand Azure lab
**Files**:
- `main.tf` (root)
- `modules/deploy/main.tf`
- `modules/deploy/azure-on.t-f` and `prepare.sh`
- `modules/deploy/azure/main.tf`
- `modules/deploy/data/cloud-config.txt`
- `modules/deploy/data/cml.sh`
- `modules/deploy/data/copyfile.sh`
- `modules/deploy/data/vars.sh`
- `modules/deploy/data/virl2-base-config.yml`
- `modules/deploy/data/del.sh`

This code was written by Cisco, not by an AI, but the point of the exercise is the
same: understand what it does and why before changing it. Design decisions from the
companion notes (`docs/design-notes.md`) are called out where they touch
specific lines.

---

## Overview

### What This Code Does

Takes one YAML file (`config.yml`), turns it into a single Ubuntu VM in Azure, and
hands that VM a self-contained provisioning bundle through cloud-init. The bundle
installs Cisco Modeling Labs from a package in your own blob container, copies the
reference platform images from the same container, registers a Smart License, and
runs any custom scripts you listed. Terraform then waits until the CML API answers.

### Why This Approach Was Chosen

Three forces shaped the design:

1. **One config, two clouds.** The same `config.yml` drives AWS and Azure. So every
   cloud-specific detail is pushed to the edge: a per-cloud Terraform module and a
   `case $CFG_TARGET` switch in shell.
2. **No image baking.** Instead of maintaining a golden VM image, the tooling starts
   from stock Ubuntu and does everything at first boot. Slower per build, but there is
   nothing to keep current except the `.pkg` in storage.
3. **Terraform cannot conditionally declare a provider.** That single constraint
   explains the odd `.t-f` symlink dance in `prepare.sh`.

### Context

Use this when you want CML for hours or days, not months. Everything is designed
for build-use-destroy. That is also why persistence is absent: the authors assumed a
disposable instance, which matches the on-demand goal but not the "keep my labs"
goal. The notes file covers the gap.

---

## Code Walkthrough

### File 1: `main.tf` (root)

**Purpose**: Load the config, swap secrets in, wire the deploy module, and bind the
CML Terraform provider to the VM that does not exist yet.

**Line-by-line**

```hcl
# Lines 8-16: YAML becomes HCL. The "secret" key is stripped and replaced with
# whatever the secrets module resolved (dummy, Vault, or Conjur).
raw_cfg = yamldecode(file(var.cfg_file))
cfg = merge(
  { for k, v in local.raw_cfg : k => v if k != "secret" },
  { secrets = module.secrets.secrets }
)
```

Why: the rest of the code only ever reads `cfg.secrets.app.secret`. It never knows
or cares where the value came from. That is a clean seam for your Key Vault later.

```hcl
# Lines 17-19: cfg_extra_vars is either a path to a file or literal text.
extras = var.cfg_extra_vars == null ? "" : (
  fileexists(var.cfg_extra_vars) ? file(var.cfg_extra_vars) : var.cfg_extra_vars
)
```

Why: lets you inject extra `CFG_*` shell variables without editing the module.
Your `05-persist.sh` will read values from here.

```hcl
# Lines 37-43: the cml2 provider is configured from a module OUTPUT.
provider "cml2" {
  address        = "https://${module.deploy.public_ip}"
  dynamic_config = true
}
```

Why this is unusual: providers are normally configured from static values.
`dynamic_config = true` tells the cml2 provider to tolerate an address that is
unknown at plan time. Without it, `terraform plan` would fail before the VM exists.

```hcl
# Lines 45-50: a "readiness" module that just polls the API for up to 20 minutes.
module "ready" { depends_on = [module.deploy.public_ip] }
```

Why: `terraform apply` returning does not mean CML is usable. Cloud-init is still
running. This module turns "VM exists" into "CML answers".

### File 2: `modules/deploy/main.tf`

**Purpose**: Build one `options` object that every cloud module receives.

```hcl
# Lines 11-23: script files are read into STRINGS here and passed down.
options = {
  cfg      = var.cfg
  cml      = file("${path.module}/data/cml.sh")
  copyfile = file("${path.module}/data/copyfile.sh")
  rand_id  = random_id.id.hex
}
```

Why: the Azure and AWS modules both need the same scripts inside their cloud-init
payloads. Reading them once here avoids duplicating paths in each module. The
`random_id` gives resource names a suffix so two deployments in one resource group
would not collide. Note the VM itself does not use it (see File 4, line 206).

### File 3: `modules/deploy/azure-on.t-f` and `prepare.sh`

**Purpose**: Turn the Azure provider on or off by swapping a symlink.

```hcl
# azure-on.t-f lines 7-15: required_providers is a static block.
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = ">=3.82.0" }
  }
}
# Lines 26-30: the module is instantiated only when target == azure.
module "azure" {
  source = "./azure"
  count  = var.cfg.target == "azure" ? 1 : 0
}
```

Why the symlink: `count` can suppress a module, but it cannot suppress a
`provider` or `required_providers` block. If both clouds were declared, Terraform
would demand credentials for both. So `prepare.sh` links `azure.tf` to either
`azure-on.t-f` or `azure-off.t-f`. The `.t-f` extension keeps Terraform from
loading the inactive file. Crude, but it works.

**Your clone today**: `azure.tf -> azure-off.t-f`. Re-run `prepare.sh` before anything.

Alternatives: one root module per cloud (cleaner, more duplication), or Terraform
workspaces with provider aliases (does not solve the static declaration problem).

### File 4: `modules/deploy/azure/main.tf`

**Purpose**: Everything Azure. Thirteen resources, five data sources.

**Late binding of the SAS token (lines 7-26)**

```hcl
vars = templatefile("${path.module}/../data/vars.sh", {
  cfg = merge(var.options.cfg, { sas_token = data.azurerm_storage_account_sas.cml.sas })
})
```

Why the comment says "late binding required": the SAS token is generated inside
this module, so the shell variables file has to be rendered here, not one level up.
The same merge is repeated for `virl2-base-config.yml`.

**Bring-your-own foundation (lines 49-58, 267-270)**

```hcl
data "azurerm_resource_group" "cml"   { name = var.options.cfg.azure.resource_group }
data "azurerm_storage_account" "cml"  { name = var.options.cfg.azure.storage_account }
data "azurerm_ssh_public_key" "cml"   { name = var.options.cfg.common.key_name }
```

Why: these are `data`, not `resource`. The module reads them and never destroys
them. This is the seam the notes file builds on: a separate persistent Terraform
root creates these plus a data disk and static IP, and this module keeps reading.

**Least-privilege SAS (lines 60-93)**

```hcl
start  = timestamp()
expiry = timeadd(timestamp(), "1h")
permissions { read = true  list = true  write = false ... }
```

What: a Shared Access Signature is a signed URL query string that grants scoped,
time-boxed access to storage without handing out the account key.

Why read plus list only: the VM only needs to download. Why one hour: a short
window limits damage if the token leaks (it lands in `/provision/vars.sh` in
plaintext, mode 0600). Trade-off: every image copy must finish inside that hour,
measured from plan time. A large SD-WAN or FTDv image set can miss it. Raising this
to a few hours is one of the planned patches.

Note `timestamp()` makes the plan non-idempotent: every plan generates a new token
and shows a diff. Accepted cost.

**Network security (lines 95-163)**

Four inbound rules, priority ascending, all `destination_address_prefix = "*"`:

| Rule | Priority | Ports | Source list |
|---|---|---|---|
| `cml_std` | 100 | 80, 443, 1122 | `allowed_ipv4_subnets_cml2` |
| `cml_admin` | 150 | 22, 9090 | `allowed_ipv4_subnets_mgmt` |
| `cml_patty_tcp` | 200 | 2000-2999 | `allowed_ipv4_subnets_cml2` |
| `cml_patty_udp` | 300 | 2000-2999 | `allowed_ipv4_subnets_cml2` |

Why two source lists: GUI users and admins are different populations. Why 1122 and
9090: 1122 is the CML console server, 9090 is Cockpit. Why PaTTY is 2000-2999 and
not 2000-7999 like AWS: line 138, "Policy disallows 3389, 5500, 5800 and 5900".
Azure subscription policy in Cisco's tenant blocked RDP and VNC ports, so the
authors shrank the range instead of listing five sub-ranges.

**What is missing here for the routed design**: an inbound rule allowing the ISE
and FTD subnet to reach the lab prefixes on any port. Azure NSGs evaluate packets
that transit a NIC too, not just packets addressed to it.

**Network plumbing (lines 165-203)**

```hcl
allocation_method = "Static"              # line 169, public IP
address_space     = ["10.0.0.0/16"]       # line 174, hard-coded
address_prefixes  = ["10.0.2.0/24"]       # line 183, hard-coded
private_ip_address_allocation = "Dynamic" # line 194
```

Why static public IP: the cml2 provider needs a stable address during the same
apply. But the IP resource itself is created and destroyed with the module, so it
changes between builds. Moving it to the persistent root fixes that.

Why 10.0.0.0/16 matters: it is the most common default in every Azure tutorial,
so it will collide with a peered lab VNet sooner or later. Parameterize it.

What is absent on the NIC: `enable_ip_forwarding` and
`accelerated_networking_enabled`. Both default to false. The first is mandatory
for the routed design. Azure drops any packet arriving at a NIC whose destination
IP is not that NIC's, unless forwarding is enabled.

**The VM (lines 205-265)**

```hcl
name           = var.options.cfg.common.controller_hostname   # 206: not rand_id
size           = var.options.cfg.azure.size                   # 233
admin_username = "ubuntu"                                     # 239
os_disk {
  storage_account_type = "Standard_LRS"                       # 252: HDD tier
  disk_size_gb         = var.options.cfg.common.disk_size     # 253: 64 GB default
}
source_image_reference { offer = "ubuntu-24_04-lts"  sku = "minimal" }  # 257-262
custom_data = data.cloudinit_config.azure_ud.rendered         # 264
```

Why the VM name is the hostname and not random: the CML license and certificates
key off the hostname, and the authors wanted `cml-controller` to be findable.
Consequence: one instance per resource group, listed in `TODO.md`.

Why `ubuntu` as admin: Canonical images expect it, and cloud-init's final modules
fail if the initial user is removed. So `cml.sh` locks the account instead of
deleting it (File 6, line 195).

Why Standard_LRS: cheapest. Fine for the authors' 4 vCPU test box, wrong for a
Nexus spine-leaf. Premium_LRS on a "ds" size is the planned change.

Why `minimal`: smaller image, faster boot, fewer packages to patch.

The 22-line comment block at 210-231 is the authors' own sizing research pasted
into the file. It confirms nested virtualization was the selection criterion.

**cloud-init packaging (lines 272-282)**

```hcl
data "cloudinit_config" "azure_ud" {
  gzip          = true
  base64_encode = true
  part { content_type = "text/cloud-config"  content = local.cloud_config }
}
```

Why gzip: Azure's `custom_data` field has a 64 KB limit after base64. The payload
carries every script plus the refplat list, so compression matters. AWS is worse
at 16 KB, which is why the README warns about it.

### File 5: `modules/deploy/data/cloud-config.txt`

**Purpose**: The cloud-init document. Terraform renders it, Azure hands it to the
VM, cloud-init executes it on first boot.

```yaml
# Lines 12-56: write_files drops every script into /provision/ with explicit modes.
write_files:
  - path: /provision/cml.sh
    permissions: "0700"
    content: |
      ${indent(6, cml)}
```

Why `indent(6, ...)`: YAML block scalars need consistent indentation, and the
script text is multi-line. The comment in the Terraform module warns "ensure
there's no tabs in the template file" for the same reason. One tab breaks the
whole document silently.

```yaml
# Line 16: the refplat list becomes a JSON file for jq to read later.
content: '${jsonencode(cfg.refplat)}'
```

Why JSON and not YAML: `cml.sh` uses `jq`, which is in the `packages:` list at
line 8. Bash has no YAML parser.

```yaml
# Lines 57-63: the customize hook.
%{ for script in cfg.app.customize }
  - path: /provision/${script}
    content: |
      ${indent(6, file("${path}/../data/${script}"))}
%{ endfor }
```

Why the list "must have at least ONE element": an empty `write_files` entry is
invalid YAML in this shape, so `99-dummy.sh` exists purely to keep the loop
non-empty. This is where `05-persist.sh` will be added.

```yaml
# Lines 65-70: run, then reboot only on success.
runcmd:
  - /provision/cml.sh && touch /run/reboot || echo "CML provisioning failed.  Not rebooting"
power_state:
  mode: reboot
  condition: test -f /run/reboot
```

Why the sentinel file: `power_state` runs after `runcmd` and cannot see its exit
code. The file is the only channel between them. A failed provision leaves the VM
up so you can SSH in and read `/var/log/cloud-init-output.log`.

For the data disk: cloud-init's `disk_setup`, `fs_setup`, and `mounts` modules run
before `runcmd`, so a disk mounted here is ready when `cml.sh` starts. That is why
the notes file puts the mount in this template rather than in a customize script.

### File 6: `modules/deploy/data/cml.sh`

**Purpose**: The whole install, in four phases.

**Phase 0, pre-setup (lines 15-29, 250-261)**

```bash
case $CFG_TARGET in
    aws)   setup_pre_aws ;;    # installs AWS CLI v2
    azure) setup_pre_azure ;;  # downloads azcopy into /usr/local/bin
esac
```

Why azcopy and not `az`: azcopy is a single static binary with no Python
dependency and handles recursive blob copies well. The `az` CLI would add a minute
of install time.

**Phase 1, base_setup (lines 48-178)**

```bash
# Lines 59-73: copy only the node definitions and images listed in config.yml
copyfile refplat/$NDEF/$item.yaml $VLLI/$NDEF/
copyfile refplat/$IDEF/"$item"/ $VLLI/$IDEF "$item" --recursive
# Lines 77-79: fallback, copy everything if nothing matched
```

Why selective copy: refplat is tens of gigabytes. Copying only what the lab needs
keeps the build inside the SAS window. This is exactly the step a persistent data
disk makes redundant after the first run.

```bash
# Lines 88-107: feature detection by package version, not by CML release name.
version=$(ls /tmp/cml2_*_amd64.deb | awk -F_ '{print $2}')
if dpkg --compare-versions "$version" ge 2.7.0; then dpkg --add-architecture i386; fi
if dpkg --compare-versions "$version" ge 2.9.0; then <add Docker apt repo>; fi
```

Why: 2.7 introduced IOL images, which are 32-bit binaries. 2.9 introduced Docker
based nodes. Testing the version once keeps one script working across releases.

```bash
# Lines 118-146: headless initial setup.
sed -i '/^Standard/ s/^/#/' /lib/systemd/system/virl2-initial-setup.service
touch /etc/.virl2_unconfigured
systemctl enable --now virl2-initial-setup.service
# poll for the sentinel to disappear, 5 tries x 5 s
```

Why: CML's first-boot wizard expects a TTY. A cloud VM has none, so the unit file
is patched to drop its `StandardInput` lines, and the answers come from
`/etc/virl2-base-config.yml` with `interactive: false`. The `.virl2_unconfigured`
file is another sentinel: the wizard deletes it when finished.

```bash
# Lines 154-161: kill bridge mode for good.
(HOME=/var/local/virl2 /usr/local/bin/virl2-bridge-setup.py --delete)
sed -i /usr/local/bin/virl2-bridge-setup.py -e '2iexit()'
```

Why: inserting `exit()` at line 2 of the Python script makes it a no-op forever,
even after upgrades re-run it. This is the code behind "no bridge support in the
cloud". It does not prevent you from adding your own empty bridge in Cockpit for
the routed design; it only stops CML from bridging the primary NIC.

```bash
# Lines 170-177: PaTTY picks the default-route interface at runtime.
GWDEV=$(ip -json route | jq -r '.[]|select(.dst=="default")|(.metric|tostring)+"\t"+.dev' | sort | head -1 | cut -f2)
```

Why: interface names differ between clouds (`eth0`, `enP1s0`), so the script asks
the routing table which interface carries the default route rather than guessing.
Worth stealing for your own scripts.

**Phase 2, cml_configure (lines 180-218)**

```bash
mv /home/ubuntu/.ssh/ /home/${CFG_SYS_USER}/          # 184-191
usermod --expiredate 1 --lock ubuntu                  # 195
until [ "true" = "$(curl -s $API/system_information | jq -r .ready)" ]; do sleep 5; done  # 210-213
HOME=/var/local/virl2 python3 /provision/license.py   # 217
```

Why move the key: the Azure SSH key was injected for `ubuntu`, but CML's system
admin is `sysadmin`. After this, `ssh sysadmin@<ip>` works and `ubuntu` does not.
Why `HOME=/var/local/virl2`: the CML Python client stores its state there.

**Phase 3, postprocess (lines 220-234)**

```bash
FILELIST=$(find /provision/ -type f | grep -E '[0-9]{2}-[[:alnum:]_]+\.sh' | grep -v '99-dummy' | sort)
( bash "$patch" || true ) 2>&1 | tee "/var/log/${patch}.log"
```

Why `|| true`: a broken customize script must not abort the provision or block
the reboot. Consequence: your script's failure is silent unless you read
`/var/log/provision/`. Make `05-persist.sh` loud.

### File 7: `modules/deploy/data/copyfile.sh`

```bash
azure)
    LOC="https://${CFG_AZURE_STORAGE_ACCOUNT}.blob.core.windows.net/${CFG_AZURE_CONTAINER_NAME}"
    azcopy copy --output-level=quiet "$LOC/$SRC$CFG_SAS_TOKEN" $DST $RECURSIVE
```

The SAS token is a query string, so it is simply appended to the blob URL. This is
the entire storage-access mechanism. No identity, no role assignment. A managed
identity with the Storage Blob Data Reader role would remove the token and the
one-hour clock, and is a reasonable future patch.

### File 8: `vars.sh` and `virl2-base-config.yml`

Both are Terraform `templatefile` inputs, not shell or YAML you can run directly.
`vars.sh` becomes the environment every script sources. `virl2-base-config.yml`
answers the first-boot wizard. Line 21, `skip_primary_bridge: true`, is the
declarative half of the bridge removal.

### File 9: `modules/deploy/data/del.sh`

```bash
TOKEN=$(... curl -s -d@- $API/authenticate | jq -r)
curl -s -X "DELETE" "$API/licensing/deregistration" -H "Authorization: Bearer $TOKEN"
```

Why this exists: Smart Licensing counts registrations server-side. Destroying the
VM without deregistering leaves a ghost entry that consumes your entitlement until
it ages out. The script talks to the local API on port 8001 (HTTP, loopback only)
so it works even if the NSG blocks you. Line 8's note matters: it uses the
originally provisioned admin password. Change it and this script breaks.

---

## Concepts Explained

### Design Patterns Used

| Pattern | Where | Why |
|---|---|---|
| Configuration as data | `main.tf:8`, `config.yml` | One YAML drives both clouds. |
| Strategy switch | `cml.sh:250`, `copyfile.sh:15` | Cloud-specific behavior isolated behind `case`. |
| Late binding | `azure/main.tf:7-26` | Values known only inside a module are merged there. |
| Feature toggle by symlink | `prepare.sh`, `*.t-f` | Works around static provider declarations. |
| Bring-your-own foundation | `azure/main.tf:49-58` | Data sources for things that must outlive the VM. |
| Sentinel file | `cloud-config.txt:66-70`, `cml.sh:120-135` | Communicate across processes that cannot share exit codes. |
| Feature detection by version | `cml.sh:88-107` | One script survives several CML releases. |
| Fail-open hooks | `cml.sh:228` | Custom scripts never block the build. |
| Bounded wait | `cml.sh:31-46`, `130-146` | Poll with a cap rather than sleep blind. |

### Key Technical Concepts

#### Nested virtualization

**What**: A VM that itself runs a hypervisor. CML runs KVM inside the Azure VM to
boot each lab node.

**Why here**: The whole product depends on it. Azure exposes the VMX CPU flag only
on certain families. Every v5 D and E size does. `azure/main.tf:210-231` is the
authors' research on exactly this.

**Trade-offs**: Second-level virtualization costs some CPU. Live migration of the
host VM is fine; nested guests survive it.

**Alternatives**: Bare metal (AWS `.metal` flavors, which the AWS module uses).
Azure has no equivalent at this size, so nested is the only option.

#### cloud-init

**What**: The de facto first-boot configuration system for cloud Linux images. It
reads a YAML document delivered by the cloud platform and runs modules in a fixed
order: users, packages, `write_files`, `disk_setup`, `mounts`, then `runcmd`, then
`power_state`.

**Why here**: No golden image to maintain. Everything happens at boot.

**When to use**: Any time a VM must be reproducible from stock images. Not for
ongoing configuration management; it runs once.

**Alternatives**: Packer-built images (faster boot, more to maintain; the script
even has `PACKER_BUILD` hooks at `cml.sh:271`), Ansible after boot (needs a
reachable host and a second tool).

#### Shared Access Signatures

**What**: A signed query string granting scoped, time-limited rights to Azure
Storage. The signature is computed with the account key by whoever runs
Terraform; the VM never sees the key.

**Why here**: Simplest way to let a fresh VM download without any identity setup.

**Trade-offs**: Plaintext on disk, fixed expiry, no revocation short of rotating
the account key.

**Alternatives**: System-assigned managed identity on the VM plus a role
assignment. No secret anywhere, no expiry, and azcopy supports it with
`--login-type=MSI`.

#### Azure NSG priority and transit traffic

**What**: Rules are evaluated lowest priority number first, first match wins,
with default deny-all inbound at 65500. NSGs attached to a NIC also filter
packets the VM is forwarding for other hosts.

**Why it matters for the routed design**: The four existing rules only allow the
CML service ports. ISE to lab-switch traffic arriving at the CML NIC needs its own
allow rule or it is dropped before Linux ever sees it.

#### Azure layer-3-only networking, IP forwarding, and UDRs

**What**: The VNet delivers packets only to registered IP and MAC pairs. There is
no ARP flooding, no MAC learning, no promiscuous mode. A VM may forward packets
for other addresses only if `enable_ip_forwarding` is set on its NIC. Other VMs
learn to send lab-bound traffic to it through a user-defined route on their subnet
with next-hop type Virtual Appliance.

**Why here**: This is why bridge mode is dead in the cloud (`cml.sh:156-157`) and
why the routed design needs one NIC flag plus one route table entry.

**Alternatives**: Overlay tunnels (IPsec or GRE from a lab C8000v), which work
through NAT because the lab initiates. Documented as the fallback.

#### Terraform provider configured from a module output

**What**: `provider "cml2"` at `main.tf:37` reads `module.deploy.public_ip`. Most
providers refuse unknown values at plan time. The cml2 provider's
`dynamic_config = true` defers validation to apply.

**Why here**: Lets one apply both create the VM and then configure labs on it.

**Trade-offs**: A destroy can fail if the provider cannot reach the (already gone)
VM. The readiness module and the `del.sh` output exist to soften that.

---

## Learning Resources

### Official Documentation

- [cloud-init module reference](https://cloudinit.readthedocs.io/en/latest/reference/modules.html): order of `write_files`, `disk_setup`, `mounts`, `runcmd`, `power_state`.
- [azurerm_linux_virtual_machine](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_virtual_machine): every argument used at lines 205-265, including `custom_data` limits.
- [azurerm_network_interface](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_interface): `enable_ip_forwarding` and `accelerated_networking_enabled`.
- [Azure user-defined routes](https://learn.microsoft.com/en-us/azure/virtual-network/virtual-networks-udr-overview): how Virtual Appliance next hops work.
- [Grant limited access with SAS](https://learn.microsoft.com/en-us/azure/storage/common/storage-sas-overview): what the token at lines 60-93 actually is.
- [Nested virtualization in Azure](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization): linked from line 211 of the module.
- [CML External Connectors](https://developer.cisco.com/docs/modeling-labs/external-connectors/) and [Adding L2 Bridge External Connectors](https://developer.cisco.com/docs/modeling-labs/adding-l2-bridge-external-connectors/): the "local bridge" the routed design uses.
- [Terraform cml2 provider](https://registry.terraform.io/providers/CiscoDevNet/cml2/latest/docs): `dynamic_config` and the `cml2_system` data source the readiness module polls.
- [Terraform templatefile](https://developer.hashicorp.com/terraform/language/functions/templatefile): the `%{ for }` and `${indent()}` syntax in `cloud-config.txt`.

### Tutorials and Articles

- [cloud-cml README](https://github.com/CiscoDevNet/cloud-cml): the user-data size limits and customize-script contract.
- [cloud-cml Azure.md](https://github.com/CiscoDevNet/cloud-cml/blob/main/documentation/Azure.md): the manual storage layout this code expects.
- [azcopy with managed identity](https://learn.microsoft.com/en-us/azure/storage/common/storage-use-azcopy-authorize-azure-active-directory): the path to removing the SAS token.

### Related Concepts (For Deeper Study)

- Azure ephemeral OS disks: a cheaper OS disk for a VM you rebuild anyway.
- Azure Spot VMs and eviction policies: the AWS module has spot, Azure does not yet.
- Ubuntu netplan with the NetworkManager renderer: what `interface_fix.py` patches.
- Smart Licensing registration lifecycle: why `del.sh` must run before destroy.

---

## Related Code in This Project

| File | Relationship |
|---|---|
| `modules/deploy/aws/main.tf` | Sibling module. Has spot instances, cluster computes, and dedicated hosts that Azure lacks. Good reference for adding spot to Azure. |
| `modules/secrets/*` | Produces `cfg.secrets`. Swap `dummy` for Vault or Key Vault without touching deploy. |
| `modules/readyness/main.tf` | Polls `cml2_system` for 20 minutes after apply. |
| `modules/deploy/data/interface_fix.py` | Rewrites netplan and the base config so CML binds the right interface. |
| `modules/deploy/data/license.py` | Registers the Smart License through the CML Python client. |
| `modules/deploy/data/03-letsencrypt.sh` | The only existing "persistence" round trip: certs copied to and from blob by hostname. |
| `config.yml` | The single input. `target`, `azure.size`, `common.disk_size`, `app.customize`. |
| `../cml-azure-lab-notes.md` | Design decisions that reference the lines above. |

---

## Next Steps

1. **Try it yourself**: run `./prepare.sh`, choose Azure, set `target: azure`, then
   `terraform plan`. Count the resources. You should see thirteen from this module
   plus `random_id` and the readiness data source. Read the plan for the NIC and
   confirm `enable_ip_forwarding = false`.
2. **Deeper dive**: on a live VM, read `/provision/vars.sh` and
   `/var/log/cloud-init-output.log`. Match each log line to a phase in `cml.sh`.
   Then look at `/etc/netplan/50-cloud-init.yaml` to see what `interface_fix.py`
   left behind.
3. **Common pitfalls**:
   - Image copy exceeding the one-hour SAS window. Symptom: azcopy 403 mid-build.
   - A tab character in any customize script. Symptom: cloud-init rejects the whole
     document and nothing under `/provision` exists.
   - Running `terraform destroy` before `del.sh`. Symptom: next build fails
     licensing with "no available entitlements".
   - Changing the admin password in the GUI. Symptom: `del.sh` returns 401.
   - Forgetting that `ubuntu` is locked. Log in as `sysadmin`.
   - Two applies in one resource group. Symptom: VM name conflict on line 206.

---

*This deep dive was generated by AntiVibe - the anti-vibecoding learning framework.*
*Learn what AI writes, not just accept it.*
