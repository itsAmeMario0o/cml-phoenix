# CML on Azure: on-demand lab notes

Working notes from the design conversation, 2026-09-01 to 2026-09-02.
Repo under study: `Projects/cloud-cml` (clone of CiscoDevNet/cloud-cml, tag v2.9.0 plus two commits).
Companion MCP server: https://github.com/xorrkaz/cml-mcp

## 1. Goal

An on-demand Cisco Modeling Labs instance in Azure that can be built and destroyed
between sessions, with lab state and Claude Code working files surviving the rebuild.

Target workloads:

- Nexus 9000v spine-leaf
- Catalyst SD-WAN (Manager, Controller, Validator, C8000v edges)
- ISE plus FTD plus TrustSec (TrustSec is the first use case, not the only one)
- One or two Ubuntu VMs alongside

Sizing floor is 16 vCPU / 64 GB RAM. Many scenarios need 128 to 192 GB.

### Placement rule (critical)

Anything that needs per-device identity, CoA, or inline tagging goes inside CML.
Anything that talks to the lab purely over IP can live in the VNet behind the
summary route.

## 2. What cloud-cml is

Cisco DevNet Terraform tooling that provisions one VM, bootstraps Ubuntu 24.04 with
cloud-init, installs the CML package, pulls reference platform images from your own
storage, and registers the Smart License. Supports AWS and Azure, never both at once.
Current `main` targets CML 2.8 and newer. Pin tag `v2.7.2` for CML 2.7.

### State of the clone as of 2026-09-01

- `prepare.sh` was run for AWS. `modules/deploy/azure.tf` points at the dummy module.
  Re-run `prepare.sh` and choose Azure before anything works.
- `config.yml` has `target: aws`. Must become `target: azure`.
- No CLAUDE.md, no `.claude/`, no pre-commit, no CI, no Makefile.

### Azure module facts (`modules/deploy/azure/main.tf`)

- Reads existing resource group, storage account, and SSH key as data sources.
- Creates NSG, four rules, public IP, VNet 10.0.0.0/16 (hard-coded), subnet
  10.0.2.0/24 (hard-coded), NIC, and one `azurerm_linux_virtual_machine`.
- VM size comes from `azure.size`, default `Standard_D4d_v4`.
- OS disk is `common.disk_size` (64 GB default) on `Standard_LRS`. No data disk.
- Images and the `.pkg` are copied by azcopy using a read-plus-list SAS token that
  expires one hour after plan time. Large image sets can hit that window.
- VM name equals `common.controller_hostname`, so one instance per resource group.
- No spot support, no cluster support, no IP forwarding, no accelerated networking.
  These exist only in the AWS module. `azure.size_compute` is a dead key.
- Public IP is created with the VM, so it changes on every rebuild.

### Provisioning hooks

- `app.customize` list in `config.yml`. Scripts named `NN-name.sh` placed in
  `modules/deploy/data/` and listed there are copied to `/provision/` and run after
  CML installs, in sorted order, failures swallowed. Logs in `/var/log/provision/`.
- `cfg_extra_vars` variable appends arbitrary `CFG_*` values to `/provision/vars.sh`.
- `cloud-config.txt` is the cloud-init template. `disk_setup` and `mounts` can be
  added here to prepare a data disk before CML installs.

### Provisioning behaviour worth knowing

- `cml.sh` deletes the bridge setup and stubs out `virl2-bridge-setup.py`.
  `virl2-base-config.yml` sets `skip_primary_bridge: true`. Bridge mode is off by design.
- The `ubuntu` account is locked after install. Log in as `sysadmin`.
- Smart License must be deregistered before destroy or the entitlement is stranded.
  `terraform output` prints the `del.sh` command.
- In-place upgrade is unsupported. Rebuild and migrate.

## 3. Persistence

Upstream has no persistence. Everything on the OS disk dies at `terraform destroy`:
labs and the CML database under `/var/local/virl2`, node disk images, refplat under
`/var/lib/libvirt/images`, certificates, `/provision`, and the sysadmin home.
The only round trip is a manual copy of Let's Encrypt certs to blob storage.

Planned approach:

- Persistent Terraform root (never destroyed) owning resource group, storage account,
  container, SSH key, static public IP, and a Premium managed data disk.
- Data disk mounted at `/data` via cloud-init, formatted only when blank.
- Symlink the libvirt images directory onto `/data` so refplat copies once.
- Sysadmin home or a Claude Code working directory on `/data`.
- Do not persist `/var/local/virl2` itself. The package installer writes into it.
  Instead export all labs to YAML on `down`, reimport on boot, via cml-mcp or
  `virl2_client`.
- Lab YAML, device configs, ADRs, and notes live in the repo on OneDrive.
  The VM stays disposable.

## 4. Sizing and cost

Intel v5 D and E families support nested virtualization. Use the `ds` variants so
Premium disks attach. Non-s Edv5 sizes cannot use Premium storage.

| Size              | vCPU | RAM    | Use                                     |
|-------------------|------|--------|-----------------------------------------|
| Standard_D16ds_v5 | 16   | 64 GB  | Stated floor                            |
| Standard_E16ds_v5 | 16   | 128 GB | Nexus spine-leaf                        |
| Standard_E20ds_v5 | 20   | 160 GB | SD-WAN full stack plus branches         |
| Standard_E32ds_v5 | 32   | 256 GB | ISE + FTD + TrustSec with Ubuntu VMs    |

Rough pay-as-you-go, US East: E16ds_v5 about $1.15/hr on-demand, about $0.24/hr spot.
E32ds_v5 about double.

Before first apply:

- Raise the Edsv5 family vCPU quota in the region. PAYG starts low and increases
  can take a support case.
- Raise `common.disk_size` well past 64 GB. SD-WAN Manager and ISE images are large.
- ISE is not a refplat image. Bring your own qcow2 if it ever runs inside CML.
  FTDv, FMCv, C8000v, SD-WAN controllers, Nexus 9000v, Ubuntu are refplat.

## 5. Style references and what to borrow

### tacacs-tuesday (closest match: Azure, Cisco, MCP)

- CLAUDE.md with explicit scope, STOP list for apply/destroy/state, a Never list,
  and a skill routing table.
- `.claude/settings.json` allowlists only read-only Terraform and Azure verbs.
- Secrets from `random_password`, read back via `terraform output -raw`.
  Subscription ID only in the shell as `ARM_SUBSCRIPTION_ID`.
- Scripts numbered `NN-verb-noun.sh`.
- MCP credentials in gitignored `config/mcp-env/`, self-ignoring directory.
- ADR 0004: teardown by default, which forces full day-0 automation.
- Has an ISE 3.4 module and a C8000v module for Azure. Reuse them.

### ravpn-workshop

- `scripts/preflight.sh` checks quota, marketplace terms, toolchain, fmt, validate.
- `scripts/smoke-test.sh` walks the verification checklist after apply.
- LESSONS-LEARNED entries as Symptom / Cause / Fix.
- Custom gitleaks rules for Cisco keys. Add one for the Smart License token.
- Has an FTDv module for Azure. Reuse it.

### money-honey

- Two-root Terraform: a bootstrap root with local state creates durable things,
  the main root uses remote state in blob. This is the persistence pattern.
- Azure Files volumes as the way data survives rebuilds.
- Runbooks in a fixed five-part shape. STATUS.md for session handoff.

## 6. Code to add

Treat cloud-cml as an upstream remote and patch lightly.

1. Persistent Terraform root: RG, storage account, container, SSH key, static
   public IP, Premium data disk.
2. Azure module patches: attach the data disk, reference the static public IP,
   optional spot with eviction policy and max bid, OS disk to `Premium_LRS`,
   longer SAS expiry, `enable_ip_forwarding = true`, accelerated networking,
   parameterized VNet CIDR, NSG rule for lab transit.
3. `05-persist.sh` customize script plus cloud-init `disk_setup` and `mounts`.
4. `up` and `down` scripts that export and import labs, and deregister the license
   before destroy.
5. Repo scaffolding: CLAUDE.md, `.claude/settings.json`, `docs/decisions/`, `labs/`
   with one YAML topology per scenario, `config/mcp-env/cml.env`, pre-commit,
   `scripts/` for preflight, up, export-labs, down, smoke-test.

## 7. cml-mcp

- Requires CML 2.9 or newer. Runs locally: `uvx cml-mcp[pyats]`.
- Env: `CML_URL`, `CML_USERNAME`, `CML_PASSWORD`, `CML_VERIFY_SSL=false`.
- 51 tools across labs, nodes, links, annotations, packet capture, users, system.
- Restrict `allowed_ipv4_subnets_cml2` in `config.yml` to your own address.
- The static public IP keeps the MCP config stable across rebuilds.

## 8. External connectivity: NAT, bridge, routed

### The two built-in modes

- NAT mode: `virbr0`, 192.168.255.0/24, DHCP. Only lab-initiated connections.
- Bridge mode: `bridge0` on the host uplink, full layer 2. cloud-cml disables it.
  The AWS doc: one address per instance and "it's mandatory that no L2 frames leak
  into the outside network as this could disable access to the management IP."

### Why layer 2 cannot work in Azure

The VNet only delivers packets to the IP and MAC pairs registered on a NIC. A lab
node with its own MAC behind a bridge never receives a frame. No promiscuous mode,
no MAC learning, on any NIC. A second NIC does not change this.

### NAT and ISE-initiated flows (parked, for reference)

Works through NAT because the NAD or client initiates:

- RADIUS and TACACS+ authentication and accounting
- SXP where the switch is the speaker
- pxGrid subscriptions
- FTD sftunnel to FMC

Breaks through NAT:

- Change of Authorization, ISE to switch on UDP 1700 or 3799. No return path.
- Per-device identity. ISE sees every NAD as the single CML host address, so
  network device objects, device SGTs, and TrustSec environment data collapse into
  one device. Not usable for a TrustSec lab.

### The routed design (chosen)

Make the CML host a layer-3 hop between a lab transit network and the VNet.

1. On the CML host, add an empty bridge in the cockpit Networking page (no member
   port, documented as a "local bridge"). Give the host an address on it, for
   example 10.100.0.1/24. Enable IPv4 forwarding. Label it under External Connectors.
2. Lab nodes attach to an External Connector on that bridge with static addresses
   and a default route to the host.
3. In Azure, `enable_ip_forwarding = true` on the CML NIC. A route table on the
   subnet where ISE and FTD live sends the lab summary, for example 10.100.0.0/16,
   to the CML private IP as a virtual appliance next hop.
4. NSG rule allowing the ISE and FTD subnet to reach the lab prefixes on any port.

Result: no NAT in the path. ISE sees each switch at its real address. CoA works.
Per-device TrustSec identity works. FTD's inside interface can route to the lab.


### Route table: Azure UDR, not the VM's local table

The route that matters is an Azure route table (user-defined route) attached to the
subnet where ISE and FTD live. It is not the Linux or ISE local routing table.
Azure's fabric forwards between VMs, even on the same subnet. A packet from ISE to
10.101.5.10 is checked against the subnet's effective routes. The lab summary is not
in the VNet address space, so without a UDR it falls to the system Internet route
and is dropped. The UDR says: 10.100.0.0/16, next hop type Virtual Appliance, next
hop the CML private IP.

Two things must both be true or the packet is dropped: the UDR on the sender's
subnet, and `enable_ip_forwarding` on the CML NIC. A static route on ISE itself
pointing at the CML IP also works, but only per VM, and FTD data-plane routes are
managed from FMC anyway. Use the UDR so every VM on the subnet inherits it.

All three VMs in one VNet is correct. Put CML on its own subnet so the UDR is
attached only to the ISE and FTD subnet. Same VNet is what matters. A second VNet
would need peering plus the same UDR.

### Lab edge router: C8000v instead of FRR

The host only knows the transit subnet directly. Prefixes deeper in the lab, such
as spine-leaf loopbacks, switch management VLANs, and endpoint VLANs, sit behind a
lab edge. Return traffic from ISE, including CoA, arrives at the CML host via the
Azure route table and is dropped if the host has no route to them.

Chosen approach: a C8000v inside the lab is the edge. It connects to the transit
External Connector at 10.100.0.2 and runs OSPF or BGP with the fabric. The host then
needs one static summary route, 10.100.0.0/16 via 10.100.0.2. Azure needs one route
table entry for the same summary via the CML host. Two routes total. Stays in the
Cisco family and keeps the host dumb. FRR on the host is not needed.

### Fallback: overlay tunnel

A C8000v inside CML builds IPsec or GRE to a C8000v in the VNet and carries the lab
prefixes through the tunnel. Works even through NAT because the lab side initiates.
Reuses the tacacs-tuesday C8000v module. Documented as fallback, not primary.

### Same vNIC or a second NIC

Same vNIC is the default. A second NIC gives nothing at layer 2. The reasons to add
one later are operational: a dedicated transit subnet with its own route table and
NSG, management and MCP access kept on NIC 0, no public IP on the transit path.
E-series sizes support up to eight NICs.

## 9. Hosting ISE and FTD outside CML

Yes to both, using the routed design. This is the preferred layout.

- ISE: Azure marketplace image, D8s_v4 or larger. Deallocate between sessions
  instead of destroy, so its configuration persists at disk cost only.
- FTD: Azure marketplace FTDv with FMC or cdFMC. Same deallocate pattern.
- CML then hosts only the switching and routing fabric and the NADs.
- Your access to ISE and FTD GUIs: NSG-restricted public IPs, Azure Bastion with
  tunnels (tacacs-tuesday pattern), or SSH port-forward through the CML host.


### TrustSec with ISE and FTD both outside CML

Correction to a misread: hosting ISE outside CML is a yes. What does not work is NAT
mode. With the routed design ISE works from the VNet.

FTD is also a yes, and it is the easier of the two. FTD learns SGTs three ways:

- pxGrid: FMC subscribes to ISE for session and SGT-to-IP mappings. TCP, FMC initiates.
- SXP: FMC or FTD as listener or speaker, TCP 64999. Layer 3.
- Inline tagging: Cisco Metadata header in the Ethernet frame (Ethertype 0x8909).
  Layer 2, not IP. The Azure VNet does not carry it, so it is off the table for any
  hop that crosses the VNet. This is the only thing lost by hosting FTD externally,
  and an FTDv on Azure would not do it anyway.

So an external FTD enforces on SGT-to-IP mappings from ISE, which is the normal
pattern for a data-centre or cloud firewall. Inline tagging can still be shown
switch-to-switch inside CML between images that support it.

Placement summary for the TrustSec use case:

| Component            | Where        | Why                                            |
|----------------------|--------------|------------------------------------------------|
| ISE                  | Azure VM     | Heavy, marketplace image, persists on deallocate |
| FTD and FMC          | Azure VMs    | Same, and SGT via pxGrid or SXP is layer 3       |
| Switches, NADs       | Inside CML   | Need per-device identity, CoA, inline tagging   |
| C8000v lab edge      | Inside CML   | Routes the lab to the transit connector          |
| Endpoints            | Inside CML   | Ubuntu or Alpine nodes on access switches        |


### Reaching ISE and FTD: SSH port forward through the CML host

The CML host already has a public IP and an NSG-restricted SSH port, so it doubles
as the jump host at no cost.

- `ssh -L 8443:<ise-private-ip>:443 sysadmin@<cml-public-ip>` then browse
  `https://localhost:8443`. Same for FMC on 443 and ISE ERS/pxGrid on 9060.
- `-D 1080` gives a SOCKS proxy for the whole VNet from a browser profile.
- `-R` reverses it: a service on the laptop becomes reachable from the VNet and,
  via the routed design, from lab nodes. Useful for a local syslog, TFTP, or
  webhook receiver during a demo.
- Local MCP servers work through it. cml-mcp does not even need the tunnel, since
  the CML API is already on the public IP. An ISE or FMC MCP server on the laptop
  gets pointed at `localhost:<forwarded-port>` with `-L`. This is the
  tacacs-tuesday `30-tunnels.sh` pattern, detached with pid files.

### Backing up ISE and FTD to Azure storage

Goal: survive version upgrades and minimize disk cost while parked.

ISE:

- Native config and operational backups go to a repository. Supported types are
  DISK, FTP, SFTP, NFS, CDROM, HTTP, HTTPS, TFTP. No native blob type.
- Cleanest fit: SFTP repository pointed at Azure Blob's built-in SFTP endpoint
  (storage account with hierarchical namespace, a local SFTP user). Schedule the
  backup in ISE. Alternative: NFS 4.1 on Azure Files premium.
- New version: deploy the new marketplace image, same hostname and IP, restore the
  config backup, re-register Smart Licensing, re-import certificates if needed.
  Cross-version restore is the supported cloud upgrade path. Check the release
  notes for the allowed source versions.

FTD and FMC:

- FTD's configuration lives in FMC. A fresh FTDv is re-registered and policy is
  re-deployed. The persistence problem is really FMC persistence.
- FMC backups go to remote storage via NFS, SMB, or SSH. Azure Files SMB or Blob
  SFTP both fit.
- cdFMC (Security Cloud Control) removes the problem entirely because the manager
  is cloud hosted. ravpn-workshop already uses cdFMC. Prefer it.

Parking cost tiers, cheapest last:

| Tier                       | Cost while parked          | Time to resume | Handles new version |
|----------------------------|----------------------------|----------------|---------------------|
| Deallocate VM              | Disk only                  | Minutes        | No                  |
| Snapshot disk, delete disk | Snapshot only, incremental | Tens of minutes| No                  |
| Destroy, restore from blob | Backup blob only           | About an hour  | Yes                 |

Trick: while a VM is deallocated you can change the OS disk SKU. Drop ISE's disk
to Standard HDD when parked and back to Premium before starting. ISE ships on a
300 GB disk, which bills as the 512 GB tier.

Decision: build the destroy-and-restore path first, since the version upgrade goal
needs it anyway. Use deallocate for day-to-day sessions.

## 10. Open questions

- Which TrustSec-capable images to use inside CML. Verify inline SGT support per
  image before building the demo.
- Whether to run Claude Code on the Mac against cml-mcp only, or also on the VM.

## 11. Related files

- `deep-dive/cloud-cml-azure-2026-09-02.md`: AntiVibe walkthrough of the Azure module, cloud-init template, and provisioning scripts with line references.
