# Deploying ISE from the Azure Marketplace, by hand

This is the way to bring up ISE for the lab. An earlier automated path
(`az deployment group create` against an exported template) was retired: the
ISE appliance image never completes Azure's OS-provisioning handshake, so
ARM marked the VM `OSProvisioningTimedOut` and reached a terminal,
non-recoverable state, even though the portal's Marketplace flow deploys the
same image and lets ISE boot (ADR 0008 amendment, 2026-09-13). Deploy ISE
through the portal with the values below, then let the kit take over for
config, verification, and teardown.

Everything here uses our environment: resource group `rg-cml-lab`, region
East US 2, VNet `vnet-cml-lab`, subnet `snet-apps`. The values are chosen to
match what the routed path and the lab topology already assume, so ISE lands
where the rest of the kit expects it.

## Before you start

- Sign in to the Azure portal as the same account the CLI uses, and make
  sure the active subscription is the lab subscription.
- The Marketplace terms for the ISE 3.5 image are already accepted on the
  subscription, so no terms step is needed.
- Have the lab SSH public key handy. Print it with `cat keys/cml-lab.pub`.
  Using this key keeps ISE consistent with the CML host jump.
- The CML host should be running if you want to verify ISE afterward, since
  ISE is reached through the CML jump, never directly.

## The one that bit us: size and quota

Do not accept the wizard default of `Standard_F16s_v2`. That size is 16
cores of the FSv2 family, and the subscription's FSv2 quota is 10, so
validation fails with `QuotaExceeded`. Use `Standard_D8s_v4` (8 cores, DSv4
family, which has room). It is a supported ISE 3.5 evaluation size.

## The wizard, tab by tab

Open the tile **Cisco Identity Services Engine (ISE)** and choose the plan
**Cisco Identity Services Engine (ISE) BYOL 3.5**, then **Create**.

### Basics

| Field | Value | Why |
|---|---|---|
| Subscription | the lab subscription | |
| Resource group | `rg-cml-lab` | our persistent group |
| Region | **East US 2** | must match the VNet, not East US |
| Host Name | `ise1` | under 19 chars, no underscore |
| Time Zone | `Etc/UTC` | |
| VM Size | **`Standard_D8s_v4`** | fits DSv4 quota, avoids the F16s_v2 quota fail |
| Disk Storage Type | Premium SSD | |
| Disk Encryption Key | leave blank | not needed for the lab |
| Volume Size | `600` | 600 GB is the supported minimum for a real profile |

### Network Settings

| Field | Value | Why |
|---|---|---|
| Virtual Network | `vnet-cml-lab` | our lab VNet |
| Subnet | `snet-apps` | where ISE belongs (10.20.2.0/24) |
| Network Security Group | leave as "Select existing" / none for now | see the NSG note below |
| SSH public key source | **Use existing public key** | reproducible; matches the jump key |
| SSH Key (key data) | paste the output of `cat keys/cml-lab.pub` | the lab key |
| Key pair name | any name, for example `cml-lab` | just a label |
| Private IP Address | **`10.20.2.20`** | static; the routed path and lab config assume it |
| Public IP Address | new, `ise1-ip`, Standard SKU, Static | outbound for Security Cloud Control and Entra; Standard is inbound-closed by default |
| DNS domain name | `rooez.com` | |
| Primary Name Server | `8.8.8.8` | reachable once the public IP gives outbound |
| Primary NTP Server | `time.google.com` | NTP is critical for ISE, keep this correct |

Leave the secondary and tertiary DNS and NTP fields blank.

### Services

| Field | Value | Why |
|---|---|---|
| ERS | `yes` | the config tooling uses the ERS API |
| PXGrid | `yes` | needed later for SGT bindings to the FTD |

### User Details

| Field | Value | Why |
|---|---|---|
| Password for `iseadmin` | your choice, within the policy below | the ISE GUI and CLI admin password |

ISE password policy: 6 to 25 characters, at least one uppercase, one
lowercase, and one number, must not contain `iseadmin` or `cisco`, and the
only special characters allowed are `@ ~ * ! , + = _ - .`. A password that
breaks this stops ISE from finishing first boot.

### Review + submit

Submit. The portal may still show provisioning warnings related to the same
OS-provisioning handshake, but unlike the CLI it does not hard-fail, and ISE
continues to boot. First boot takes 30 to 45 minutes.

## The NSG note

The wizard's network security group handling is limited, so leave it unset
here. The Standard public IP is inbound-closed by default, so nothing is
exposed while it boots. Everything after the wizard, the NSG and its
attachment, tagging, the readiness wait, and the policy apply, is one
command:

```bash
scripts/25-ise-up.sh --post-deploy
```

It creates `ise-nsg` with the scoped rules the lab needs (RADIUS from the
lab summary, admin 443/22 from the CML host, never `0.0.0.0/0`), attaches it
to the NIC the wizard created, tags the VM and its OS disk `role=ise` so
teardown by tag catches both, waits for ISE to answer through the CML jump
(30-45 minutes), and applies the minimal TrustSec Phase 1 policy. Run
`scripts/25-ise-up.sh --post-deploy --dry-run` first to see the plan; it
reads its settings from `config/mcp-env/ise.env` (`config/ise.env.example`
to start from).

## After it boots

1. `scripts/25-ise-up.sh --post-deploy` (above) confirms ISE answers through
   the CML jump as its own readiness check; it never reaches ISE directly.
2. Confirm the deploy did not disturb the routed path:
   `terraform -chdir=terraform/persistent plan` should show no changes, which
   proves the `rt-apps` route table is still associated with `snet-apps`.

## Tearing it down

`scripts/45-ise-down.sh` deletes everything tagged `role=ise`: `ise1`,
`ise1nic`, `ise1-ip`, `ise-nsg`, and `ise1osdisk`.
