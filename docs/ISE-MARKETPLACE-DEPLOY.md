# Deploying ISE from the Azure Marketplace, by hand

This is the reliable way to bring up ISE for the lab. The automated ARM path
(`az deployment group create` against the exported template) fails: the ISE
appliance image never completes Azure's OS-provisioning handshake, so ARM
marks the VM `OSProvisioningTimedOut` and reaches a terminal, non-recoverable
state, even though the portal's Marketplace flow deploys the same image and
lets ISE boot. Until that is solved, deploy ISE through the portal with the
values below, then let the kit take over for config, verification, and
teardown.

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
exposed. After ISE is up, apply the scoped rules the lab needs, sourced from
the CML host and the lab summary, never `0.0.0.0/0`:

```bash
RG=rg-cml-lab
az network nsg create -g "$RG" -n ise-nsg -l eastus2 \
  --tags project=cml-azure-lab role=ise
az network nsg rule create -g "$RG" --nsg-name ise-nsg -n allow-radius \
  --priority 100 --direction Inbound --access Allow --protocol Udp \
  --destination-port-ranges 1812 1813 --source-address-prefixes 10.100.0.0/16
az network nsg rule create -g "$RG" --nsg-name ise-nsg -n allow-admin \
  --priority 110 --direction Inbound --access Allow --protocol Tcp \
  --destination-port-ranges 443 22 --source-address-prefixes 10.20.1.10/32
az network nic update -g "$RG" -n ise1nic --network-security-group ise-nsg
```

Tag the VM and its disk so teardown by tag catches everything:

```bash
az resource tag -g "$RG" --tags project=cml-azure-lab role=ise \
  --name ise1 --resource-type Microsoft.Compute/virtualMachines
az disk update -g "$RG" -n ise1osdisk --set tags.project=cml-azure-lab tags.role=ise
```

## After it boots

1. Confirm ISE answers through the CML jump (do not reach it directly):

   ```bash
   CML=$(terraform -chdir=terraform/persistent output -raw public_ip_address)
   ssh -p 1122 -i keys/cml-lab "sysadmin@${CML}" \
     "curl -sk -o /dev/null -w '%{http_code}\n' --max-time 10 https://10.20.2.20/admin/API/mnt/Version"
   ```

   A non-`000` HTTP code means ISE is serving.

2. Apply the minimal policy with the kit's config tooling once ISE is ready.

3. Confirm the deploy did not disturb the routed path:
   `terraform -chdir=terraform/persistent plan` should show no changes, which
   proves the `rt-apps` route table is still associated with `snet-apps`.

## Tearing it down

`scripts/45-ise-down.sh` deletes everything tagged `role=ise`. If you skipped
the tagging step above, delete `ise1`, `ise1nic`, `ise1-ip`, `ise-nsg`, and
`ise1osdisk` by name instead.
