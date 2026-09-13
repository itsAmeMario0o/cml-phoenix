# ISE deployment by the Azure solution template

> **Superseded, 2026-09-13.** The automated `az deployment group create` deploy
> this spec describes was retired: ISE terminally fails Azure OS provisioning
> on that path. ISE is now deployed by hand through the portal. See the ADR
> 0008 amendment (`docs/decisions/0008-ise-by-azure-solution-template.md`) and
> the walkthrough (`docs/ISE-MARKETPLACE-DEPLOY.md`). This document is kept as
> the design record of the automated approach, which roadmap item 19 (ISEEE
> ephemeral ISE) may revisit.

Status: draft, 2026-09-12.

This spec replaces the way TrustSec Phase 1 deploys ISE. Phase 1 built a raw
VM-image deploy (`az vm create` with hand-rolled user-data). That path proved
unreliable to boot, and the cause is now understood. This spec adopts Cisco's
Azure Marketplace solution template instead, automated with
`az deployment group create`, and removes the VM-image path. Everything else
in Phase 1 (the routed transit, the proof topology, the policy-as-code) stays.

## Context

The operator hit repeated boot failures deploying ISE from the raw VM image.
Reading Cisco's own solution template (captured from the Marketplace as an
automation export, in `software/ise-solution-template/`) shows why: ISE on
Azure reads a fixed set of first-boot user-data keys, and the hand-rolled
renderer got two of them wrong. It used `ntpserver` where ISE 3.4 and later
expect `primaryntpserver`, and it injected `ipv4address`, `ipv4netmask`, and
`ipv4gateway`, which are not part of Cisco's Azure key set at all. ISE takes
its address from the NIC, not from user-data. Either mistake can stop ISE
services from coming up.

The captured template is a plain Azure Resource Manager solution template. It
declares a public IP, a NIC, and a `Microsoft.Compute/virtualMachines`
resource, and it deploys into the resource group and existing VNet and subnet
the operator selects. There is no managed-application wrapper and no separate
managed resource group. This matters: it deploys into `rg-cml-lab` on the
existing `snet-apps` subnet, so the disposable, tear-down-by-tag model the kit
already uses still applies. The image is pinned to
`cisco:cisco-ise-virtual:cisco-ise_3_5:3.5.527`, plan `cisco-ise_3_5`, whose
Marketplace terms are already accepted on the subscription.

## Goal and scope

In scope:

- A tracked, customized copy of the solution template under `config/ise/`,
  with the kit's tags added so its resources are disposable by tag.
- A rewritten `scripts/25-ise-up.sh` that renders deployment parameters from
  `config/mcp-env/ise.env`, ensures a scoped network security group, runs
  `az deployment group create`, waits for ISE to answer, and applies policy.
- A `scripts/45-ise-down.sh` that deletes every `role=ise` resource.
- The scoped NSG: RADIUS from the lab, admin from the CML host only.
- Reachability that does not depend on the operator's changing public IP.
- Correcting the policy client's API addressing so the authorization rule
  applies against real ISE 3.5, not only the test's fake server.

Out of scope, unchanged from Phase 1:

- The host transit bridge and the routed path (ADR 0003).
- The proof topology `labs/trustsec-phase1.yaml`.
- The transit-bridge smoke checks.

Removed:

- `scripts/lib/ise-userdata.sh` and the VM-image `create_vm` and `create_nsg`
  logic. The template builds `userData` from parameters, so the renderer is
  dead weight.

## Architecture

### The customized template

`config/ise/template.json` is the captured template with one change: the VM,
the NIC, and the public IP each carry `project=cml-azure-lab` and `role=ise`
tags. The template holds no secrets, so it is tracked. Its parameters are the
deployment contract: `hostName`, `SSHKeyPairName` (the public key material),
`managementNetwork`, `managementSubnet`, `managementNSG`, `managementPrivateIP`,
the `publicIp*` set, `instanceType`, `storageType`, `volumeSize`, the DNS and
NTP servers, `timeZone`, `ERS`, `PXGrid`, `adminUsername`, and the
`systemPassword` securestring.

Pinning the template in the repo, rather than deploying the Marketplace offer
by reference each time, keeps the deploy reproducible and reviewable. When
Cisco ships a new template, the change is a visible diff.

### Parameters and secrets

`scripts/25-ise-up.sh` renders a parameters file to the scratchpad at mode
`0600` from `config/mcp-env/ise.env`. Non-secret values (hostname, size,
private IP, DNS, NTP, domain, time zone, public IP name) come straight from
the env file. `SSHKeyPairName` is filled from `keys/cml-lab.pub` so every
rebuild trusts the kit's existing key rather than a fresh generated one. The
`systemPassword` and the RADIUS secret come from the gitignored env file and
are written only into the `0600` parameters file, never onto a command line,
in line with ADR 0004. `az deployment group create --parameters @<file>`
reads the file.

`managementPrivateIP` is set to `10.20.2.20`, the address the routed path and
the lab topology already assume. The template allocates the NIC statically
when this is set.

### The network security group

A `/24`-scoped NSG is required, because lab RADIUS reaches ISE from
`10.100.0.0/16`, which is outside the Azure VNet address space (it is routed
in behind the CML host) and so is not covered by the default allow-from-VNet
rule. The up script ensures the NSG exists, tags it `role=ise`, and passes its
name to the template. Rules:

- Allow UDP 1812 and 1813 (RADIUS) from `10.100.0.0/16`.
- Allow TCP 443 and 22 (admin and CLI) from the CML host address only,
  `10.20.1.10/32`, since all operator access arrives through the CML jump.
- Deny the rest. The Standard public IP is inbound-closed by default, so no
  internet inbound rule is needed, and none is added. Never `0.0.0.0/0`.

Change of Authorization is ISE-initiated outbound to the switch on UDP 1700,
and Azure NSGs are stateful, so no inbound CoA rule is required.

### Reachability

Three paths, none tied to the operator's public IP:

- Lab switches reach ISE at the private `10.20.2.20` over the routed transit.
  This is the RADIUS and per-device-identity path from ADR 0003.
- The operator and the policy automation reach ISE through the CML host jump,
  an SSH local port-forward from the CML host (`10.20.1.10`) to
  `10.20.2.20`. The operator reaches the CML host by its existing front door,
  so a changing operator IP never matters. This is the same jump Phase 1
  built for the readiness wait and the policy apply.
- ISE reaches out through its Standard public IP for Security Cloud Control,
  Entra, DNS, and NTP. The public IP is outbound only; inbound stays closed.

This consciously overrides the ADR 0003 consequence that ISE has no public
IP. The override is narrow: the public IP carries outbound integration
traffic, not inbound administration, and inbound stays closed by default plus
the scoped NSG. A new ADR records this.

### Disposable lifecycle

- `scripts/25-ise-up.sh [--dry-run]`: load `ise.env`, resolve the persistent
  outputs, ensure the NSG, render the `0600` parameters file, run
  `az deployment group create -g rg-cml-lab --template-file
  config/ise/template.json --parameters @<file>`, then poll ISE readiness
  through the CML jump, then apply policy. Prompt before the deploy unless
  `ASSUME_YES=1`. A dry run prints the plan and touches no Azure resource.
- `scripts/45-ise-down.sh [--dry-run]`: find every `role=ise` resource in
  `rg-cml-lab` and delete it (VM, NIC, public IP, disk, NSG). It never touches
  bootstrap, persistent, or the CML VM, none of which carry the tag. This is
  the Phase 1 teardown, unchanged in shape.

### Policy as code

`scripts/lib/ise_config.py` stays. It runs after ISE answers and registers the
lab edge as a network device and one authorization rule. Two changes:

- Its authorization-rule and policy-set calls move from the ERS API to the
  ISE OpenAPI (`/api/v1/policy/network-access/...`), which is where real ISE
  3.5 serves them, with the plain-array response shape. Network-device
  registration stays on ERS, which is correct there. The fake test server is
  updated to match the real endpoint families, so the test stops hiding the
  gap.
- It reaches ISE through the CML jump, the same forward the up script uses.

## Secrets

- `systemPassword` (the `iseadmin` password) and `RADIUS_SECRET`: in the
  gitignored `config/mcp-env/ise.env`, written only into the `0600`
  parameters file, never a command line, never a tracked file. ADR 0004.
- The ISE admin password must satisfy the ISE policy: 6 to 25 characters, at
  least one upper, one lower, and one number, no `iseadmin` or `cisco`, and
  only the special characters `@~*!,+=_-.`.

## Verification

1. `scripts/25-ise-up.sh --dry-run` prints the planned deployment with the
   right template, static private IP, NSG, tags, and no secret in the output.
2. A real `scripts/25-ise-up.sh` deploys ISE, and `az` shows a running VM
   tagged `role=ise` on `snet-apps` at `10.20.2.20` with a Standard public IP.
3. ISE answers on its admin API through the CML jump within the readiness
   window, proving first boot succeeded, which the VM-image path could not.
4. The policy step registers the edge as a network device and one
   authorization rule against real ISE 3.5, not only the fake server.
5. From the edge, `ping 10.20.2.20` succeeds and a `test aaa` returns an
   Access-Accept, with the ISE live log showing the source `10.100.0.2`.
6. `scripts/45-ise-down.sh` removes every `role=ise` resource and
   `terraform -chdir=terraform/persistent plan` still shows no changes.

## Risks and fallback

- First automated deploy is also the first boot test. If ISE still fails to
  boot, the template's own `userData` output and the ISE serial console are
  the evidence, not a hand-rolled renderer to second-guess. The captured
  template is Cisco's supported path, which is the point of the switch.
- The ISE OpenAPI policy shape is verified from Cisco 3.5 documentation but
  not yet against a live node. The first real deploy confirms it; if a call
  is wrong, it is a contained fix in the policy client and its fake server.
- The public IP adds a small always-on cost while ISE runs. ISE is
  disposable, so the cost is only for the session, and the teardown removes
  the public IP with everything else.

## Open questions

- Whether the scoped NSG should also allow pxGrid ports from the future FTD,
  deferred to Phase 2 when the FTD exists.
- Whether a future Azure Bastion is worth adding for browser access to lab
  VMs without the jump. Recorded on the roadmap, not built here.
