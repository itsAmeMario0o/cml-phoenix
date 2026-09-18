# 0008: Deploy ISE from Cisco's Azure solution template

Status: accepted, 2026-09-12

## Context

The first attempt at an ISE VM used a hand-rolled `userData` payload against
the raw `cisco-ise-virtual` VM image. It failed to boot into a usable ISE.
Two mistakes caused it:

- The payload set `ntpserver`, but Cisco's Azure image reads
  `primaryntpserver`. The unrecognized key was silently ignored, so ISE came
  up with no NTP source.
- The payload injected `ipv4address`, `ipv4netmask`, and `ipv4gateway` keys.
  These are not part of Cisco's Azure `userData` set at all; Azure VMs take
  their network configuration from the platform, not from cloud-init-style
  static IP keys. The extra keys did nothing useful and masked the real
  problem during troubleshooting.

Cisco publishes a Marketplace solution template for ISE on Azure
(`software/ise-solution-template/template.json`, plus its parameters file).
It builds the same three resources by hand: a public IP, a NIC, and the VM,
wired to the `cisco-ise_3_5` plan and image SKU `3.5.527`, and it emits the
`userData` string from the correct key set. Deploying through it removes the
guesswork about which keys ISE's first-boot script expects.

## Decision

Deploy ISE with `az deployment group create` against a copy of Cisco's
template, tracked at `config/ise/template.json`, rather than continuing to
hand-roll the VM and its `userData`. The only change from Cisco's template is
tagging: the `publicIPAddresses`, `networkInterfaces`, and `virtualMachines`
resources each carry `project: cml-azure-lab` and `role: ise` so the
disposable ISE resources are identifiable and easy to query or clean up
alongside the rest of the lab. Everything else in the template, including
every parameter, variable, and the `plan` and `imageReference` blocks, is
left as Cisco shipped it.

The template provisions its own public IP for ISE, on the `publicIpSku`
parameter, which defaults to `Standard`. ADR 0003 gives the CML host the only
public IP in the lab and treats a lab node having none as a consequence
worth stating. This is a conscious override of that consequence for ISE
specifically. ISE needs outbound reachability to Cisco Security Cloud
Control and to Microsoft Entra ID for its cloud integrations, and neither
service can be reached through the routed lab transit network from ADR 0003,
which only carries lab traffic between CML nodes and the C8000v edge.

The override is outbound only. Inbound access is closed by default: Azure
does not open ports on a Standard public IP unless an NSG rule allows it, and
this template's NSG parameter stays scoped to the addresses the persistent
Terraform root actually manages, never a broad or open range. Administration
of ISE, meaning the admin GUI and SSH, continues to go through the CML host
jump on port 1122, the same as every other lab node under ADR 0003. The
operator never connects to ISE's public IP directly, so a changing operator
address requires no firewall update.

## Consequences

- ISE has a public IP, unlike every other lab node. It is outbound-only in
  practice: no inbound NSG rule opens it to the operator's IP or to
  0.0.0.0/0.
- Deploying by template means the tracked JSON, not a script, is the source
  of truth for ISE's resource shape. Cisco's own parameter names and
  defaults carry into the deploy scripts written in a later task.
- If Cisco revises the template's plan or image version, this file must be
  re-copied and re-tagged by hand; nothing here auto-updates from the
  Marketplace listing.
- Cisco's template attaches the ISE network security group to the
  `snet-apps` subnet, not to the NIC: the NIC's inline `subnet.properties`
  block is what sets the association, so every deploy writes to the subnet.
  The template does not touch the route table, but because it writes to the
  subnet at all, the `rt-apps` association (the lab-summary-to-CML route
  from ADR 0003) needs to be re-checked after the first real deploy: confirm
  `rt-apps` is still associated with `snet-apps`, and that
  `terraform -chdir=terraform/persistent plan` shows no changes. If the
  association is gone, either re-apply the persistent root to put it back,
  or move the NSG from the subnet to the NIC in `config/ise/template.json`.
- A subnet-level NSG applies to everything on `snet-apps`, not only ISE's
  NIC. That is harmless in Phase 1, where ISE is the only node on the
  subnet. It stops being harmless once a Phase 2 FTD lands on the same
  subnet: it will inherit ISE's rules, and the Phase 2 spec has to account
  for that.

## Options considered

1. Keep hand-rolling `userData` against the raw VM image and fix the two
   wrong keys. Rejected. It reproduces the same class of mistake if Cisco's
   `userData` schema changes again, since nothing here checks it against the
   real image.
2. Deploy Cisco's solution template unmodified, then tag ISE resources with
   `az resource tag` after the fact. Rejected. It is an extra imperative step
   every deploy, and a tag update is dropped by a later `az deployment group
   create` unless the imperative step is repeated.
3. Deploy from a tracked, tagged copy of Cisco's template. Chosen. One file
   holds the exact resource shape Cisco tested, the tags survive every
   deploy, and the diff against the source template stays small enough to
   review at a glance.

## Amendment, 2026-09-13: the automated deploy is retired

The core decision stands: deploy Cisco's solution template, not the raw VM
image. What does not work is deploying that template with
`az deployment group create`. On the first real run the ISE VM reached a
terminal `OSProvisioningTimedOut` state: the ISE appliance image does not
complete Azure's OS-provisioning handshake, so ARM fails the VM as
non-recoverable even though the portal's Marketplace flow deploys the same
image and lets ISE boot. This matches long-standing, cross-project
experience that ISE deploys by hand through the portal and fails through
provisioning tools.

So the deploy step moves to the portal. The reliable procedure, with our
environment's exact fields, is `docs/ISE-AD-BUILD.md`, Part 2. The
`az deployment group create` path in `scripts/25-ise-up.sh` is retired for
the create; the NSG, tagging, readiness, policy, and teardown tooling still
apply after the portal deploy. The failed run left the persistent root
clean: `rt-apps` stayed associated with `snet-apps` and the persistent plan
showed no changes, so the subnet-write risk noted above did not bite this
time, though the check stays a deploy-time gate.

Two directions follow, both deferred and tracked on the roadmap: make the
`cisco.ise` Ansible collection the default ISE configuration layer, and adopt
the ISE Eternal Evaluation (ISEEE) patterns to make a per-session ISE
practical without a fresh portal deploy every time.

## Amendment, 2026-09-18: the form carries the DC's DNS, and ISE is kept between sessions

The decision stands. Two things the portal deploy of 2026-09-18 settled.

The form is enough to tie ISE to the directory. An ISE deployed with DNS
domain name `corp.rooez.com` and Primary Name Server `10.20.2.10`, the
two values `scripts/24-ad-up.sh` prints, came up as `ise1.corp.rooez.com`
resolving through the DC, joined the domain on the first call, and needed
no CLI repoint. The repoint is now the exception path for an ISE deployed
before the DC (`docs/ISE-AD-BUILD.md`, Part 2).

ISE is no longer destroyed per session. The operator decided on
2026-09-18 to build it once and deallocate it between sessions, so the
portal form is filled in once per evaluation instead of once per session.
Deallocated compute is not billed; the disk is, by tier, so the next
deploy takes Volume Size `300` on `Standard SSD` instead of 600 GB
Premium. Cisco allows 300 to 2400 GB on Premium SSD, Standard SSD or HDD,
and `Standard_D8s_v4` stays, as the smallest instance ISE 3.5 supports.
Idle disk cost falls from about $123 to $38 a month, East US 2 list. A
managed disk cannot shrink, so the current ISE is redeployed once. The
exit is the 90 day evaluation: when it expires, ISE is destroyed and
deployed again from the form. The scripts that start and deallocate, and
the join folded into `25-ise-up.sh`, are
`docs/specs/2026-09-18-persistent-ise-dc-and-script-consolidation-design.md`,
not yet built.
