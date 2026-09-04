# cml-azure-lab: repo skeleton and CML tier

Status: approved 2026-09-02
Scope: sub-project 1 of 3. The external ISE and FTD tier and the TrustSec lab
content are separate specs that build on this one.

## 1. Goal

An on-demand Cisco Modeling Labs instance in Azure that is built and destroyed
per session, where the things that must survive a rebuild live in a separate,
never-destroyed tier. Claude Code runs on the Mac and drives CML through the
cml-mcp server and SSH.

Success for this spec, in order:

1. `scripts/00-preflight.sh` passes.
2. `scripts/20-up.sh` builds bootstrap, persistent, and CML from nothing.
3. `scripts/90-smoke-test.sh` passes and `cml-mcp` on the Mac lists labs.
4. A throwaway lab is created and exported by `scripts/30-export-labs.sh`.
5. `scripts/40-down.sh` destroys only the CML VM, with the license released.
6. A second `20-up.sh` comes up with images already on the data disk and the
   exported lab reimportable.
7. The persistent root shows zero diff throughout.

## 2. Decisions already made

| Decision | Choice | ADR |
|---|---|---|
| How to consume cloud-cml | GitHub fork, branch `azure-lab`, pinned as a git submodule | 0001 |
| State layout | Three Terraform roots split by lifetime | 0002 |
| Lab to VNet connectivity | Routed design: CML host forwards, Azure route table, no NAT | 0003 |
| Secrets | `random_password` in Terraform plus gitignored tfvars, no Key Vault | 0004 |
| Region and subscription | `eastus2`, subscription from `ARM_SUBSCRIPTION_ID` | 0002 |
| Where Claude Code runs | Mac only | 0003 |

Rejected alternatives and why are recorded in each ADR under `docs/decisions/`.

## 3. Architecture

### 3.1 Tiers

```
Azure subscription, eastus2
├── rg-cml-lab-tfstate                bootstrap root, local state
│   └── st<suffix>tfstate             container "tfstate", versioning + soft delete
└── rg-cml-lab                        persistent root, blob state
    ├── stcmllab<suffix>              containers "cml" (pkg + refplat), "exports"
    ├── sshkey-cml-lab                SSH public key resource
    ├── pip-cml-lab                   Standard SKU static public IP
    ├── disk-cml-lab-data             Premium_LRS 512 GB, prevent_destroy
    ├── vnet-cml-lab  10.20.0.0/16
    │   ├── snet-cml        10.20.1.0/24   CML host, static private IP 10.20.1.10
    │   ├── snet-apps       10.20.2.0/24   ISE, future appliances
    │   ├── snet-fw-mgmt    10.20.3.0/24   reserved for FTDv
    │   ├── snet-fw-inside  10.20.4.0/24   reserved for FTDv
    │   └── snet-fw-outside 10.20.5.0/24   reserved for FTDv
    └── rt-apps                       10.100.0.0/16 -> 10.20.1.10, attached to snet-apps
        (disposable, owned by the fork's Terraform root)
        ├── vm cml-controller         size from config, spot optional
        ├── cml-nic-<rand>            upstream naming; ip forwarding on, accelerated networking on
        ├── cml-sg-<rand> + rules     upstream naming; upstream rules plus lab-transit-in
        └── data disk attachment      disk-cml-lab-data at LUN 0
```

Lab-side addressing: `10.100.0.0/16` is the lab summary. `10.100.0.0/24` is the
transit network on the CML host's local bridge, host at `10.100.0.1`, lab edge
router at `10.100.0.2`. Everything else in the summary is behind the lab edge.
The lab edge router and the host's local bridge are lab content and belong to a
later spec; this spec only reserves the addresses and creates the route.

### 3.2 Repo layout

```
cml-azure-lab/
├── CLAUDE.md
├── README.md
├── .gitignore
├── .gitmodules                    vendor/cloud-cml -> fork, branch azure-lab
├── .pre-commit-config.yaml
├── .gitleaks.toml
├── .claude/settings.json
├── vendor/cloud-cml/              submodule, CML Terraform root, local state
├── terraform/
│   ├── bootstrap/                 local state: rg-cml-lab-tfstate + storage
│   └── persistent/                blob state: everything under rg-cml-lab
├── config/
│   ├── cml.yml.tftpl              template rendered by 20-up.sh
│   ├── cml.tfvars.example         license token and allowed CIDRs, placeholders
│   └── mcp-env/                   gitignored, self-ignoring; cml.env written by 20-up.sh
├── labs/                          one YAML topology per scenario, empty in this spec
├── scripts/
│   ├── 00-preflight.sh
│   ├── 20-up.sh
│   ├── 30-export-labs.sh
│   ├── 40-down.sh
│   ├── 50-tunnels.sh
│   └── 90-smoke-test.sh
├── docs/
│   ├── design-notes.md
│   ├── decisions/0001..0004
│   ├── superpowers/specs/
│   ├── STATUS.md
│   └── LESSONS-LEARNED.md
└── deep-dive/
```

Gitignored: `*.tfstate*`, `*.tfvars` except `*.example`, `config/cml.yml`,
`config/mcp-env/*`, `.terraform/`, `.terraform.lock.hcl` in the submodule only,
`keys/`, `*.pem`, `.envrc`.

## 4. Terraform roots

### 4.1 bootstrap (`terraform/bootstrap/`)

Local state. Files: `versions.tf`, `providers.tf`, `main.tf`, `outputs.tf`.

Creates `rg-cml-lab-tfstate`, one Standard_LRS storage account with a random
suffix, blob versioning and soft delete enabled, and a private container
`tfstate`. `lifecycle { prevent_destroy = true }` on the storage account.

Outputs: `resource_group_name`, `storage_account_name`, `container_name`.

### 4.2 persistent (`terraform/persistent/`)

Blob backend pointing at the bootstrap outputs via `backend.tf` with
`use_azuread_auth = true`. Files: `versions.tf`, `providers.tf`, `backend.tf`,
`variables.tf`, `locals.tf`, `main.tf`, `outputs.tf`.

Variables: `location` (default `eastus2`), `owner`, `expires`,
`ssh_public_key`, `data_disk_size_gb` (default 512), `vnet_cidr` and the five
subnet CIDRs with the defaults in 3.1, `lab_summary_cidr` (default
`10.100.0.0/16`), `cml_private_ip` (default `10.20.1.10`).

Resources: everything under `rg-cml-lab` in 3.1, plus two `random_password`
resources for the CML application admin and the system admin, 16 characters,
`special = false` to match cloud-cml's dummy secret manager. `prevent_destroy`
on the data disk. `locals.common_tags` with `project`, `owner`, `expires`
applied to every resource.

Outputs, all with descriptions, secrets marked `sensitive`: resource group
name, location, storage account name, `cml` and `exports` container names,
SSH key resource name, public IP name and address, data disk ID, VNet name,
`snet-cml` name and ID, `snet-apps` ID, CML private IP, app admin password,
system admin password.

### 4.3 CML root (`vendor/cloud-cml`, the fork)

Upstream root, unchanged except through the fork. Local state inside the
submodule directory, already gitignored by upstream. Invoked as
`terraform -chdir=vendor/cloud-cml` with `TF_VAR_cfg_file` pointing at
`config/cml.yml` and `TF_VAR_azure_subscription_id` and `_tenant_id` exported
by `20-up.sh` from `az account show`.

## 5. Fork changes, branch `azure-lab`

One commit per item, Conventional Commits, scoped `infra(azure)`. All in
`modules/deploy/azure/main.tf` unless noted. New `config.yml` keys live under
`azure:` so the AWS path is untouched.

| # | Change | New config key |
|---|---|---|
| 1 | VNet and subnet become data sources; NIC private IP static | `azure.vnet_name`, `azure.subnet_name`, `azure.private_ip` |
| 2 | Public IP becomes a data source | `azure.public_ip_name` |
| 3 | NIC: `enable_ip_forwarding = true`, `accelerated_networking_enabled = true` | none |
| 4 | OS disk type from config, default `Premium_LRS` | `azure.os_disk_type` |
| 5 | `azurerm_virtual_machine_data_disk_attachment` at LUN 0 | `azure.data_disk_id` |
| 6 | SAS validity from config, default `4h` | `azure.sas_validity` |
| 7 | Optional spot: `priority`, `eviction_policy = "Deallocate"`, `max_bid_price` | `azure.spot.enabled`, `azure.spot.max_bid_price` |
| 8 | NSG rule `lab-transit-in`: source `azure.apps_subnet_cidr`, destination lab summary, any port | `azure.apps_subnet_cidr`, `azure.lab_summary_cidr` |
| 9 | `modules/deploy/data/cloud-config.txt`: `disk_setup`, `fs_setup`, `mounts` for the LUN 0 data disk at `/data`, ext4, format only when blank (implemented as `05-persist.sh`, which finds the disk on the NVMe or SCSI link, ADR 0005) | none |
| 10 | New `modules/deploy/data/05-persist.sh`: if `/data/images` is populated, replace `/var/lib/libvirt/images` with a symlink to it, otherwise move the freshly copied images there and symlink; create `/data/exports`; log to `/var/log/provision/`; exit nonzero on any failure | listed in `app.customize` |

Every change carries a comment explaining why and naming ADR 0001. Upstream
merges: `git fetch upstream && git merge <tag>` on the fork, then bump the
submodule pointer here. Tooling merge always precedes a CML software rebuild.

Accepted deviation from terraform-patterns: the module does its own data-source
lookups rather than receiving IDs explicitly. That is upstream's structure and
is kept to keep merges small.

## 6. Config and secrets flow

```
terraform/bootstrap outputs  -> terraform/persistent backend.tf (static values, committed)
terraform/persistent outputs -> 20-up.sh -> config/cml.yml (rendered from cml.yml.tftpl, gitignored)
config/cml.tfvars (gitignored)-> smartlicense_token, allowed_ipv4_subnets_mgmt, allowed_ipv4_subnets_cml2, azure.size, spot settings
az account show               -> TF_VAR_azure_subscription_id, TF_VAR_azure_tenant_id
```

`cml.yml.tftpl` keeps upstream's schema: `target: azure`, the `azure:` block
with the keys in section 5, `common:` with hostname `cml-controller`,
`disk_size` 200, and the two allowed-subnet lists from tfvars, `secret:` with
`manager: dummy` and the two passwords from persistent outputs plus the token
from tfvars, `app:` with the package filename and `customize: [05-persist.sh,
99-dummy.sh]`, `license:` and `refplat:` copied from upstream and trimmed to
the images in the container.

`20-up.sh` renders the template with a small Python or `envsubst` step, never
with Terraform, so the fork stays unaware of this repo.

`config/mcp-env/cml.env` is written by `20-up.sh` with `CML_URL`,
`CML_USERNAME`, `CML_PASSWORD`, `CML_VERIFY_SSL=false`, and is the file the
`cml-mcp` entry in Claude Code's MCP config sources.

## 7. Scripts

All Bash, `#!/usr/bin/env bash`, `set -euo pipefail`, header block explaining
what the script checks, `REPO_ROOT` derived from `BASH_SOURCE`, env-var
overrides with defaults, small named functions, `main "$@"` at the bottom.
Output lines `[OK]`, `[WARN]`, `[FAIL]` with counts; nonzero exit on any FAIL.

| Script | Does | Refuses when |
|---|---|---|
| `00-preflight.sh` | az login valid; `ARM_SUBSCRIPTION_ID` set; the requested size's family quota in region covers it; terraform, az, azcopy, jq, uv present; `terraform fmt -check` and `validate` on all three roots; submodule at pinned commit; `config/cml.tfvars` present, no `0.0.0.0/0`; package and listed refplat images present in the `cml` container; sum of image sizes versus SAS validity warning | Any FAIL |
| `20-up.sh` | Bootstrap apply if no local state; persistent apply; render `cml.yml`; CML apply; wait for readiness; write `mcp-env/cml.env`; print URL, IP, and the `del.sh` command | Preflight marker older than this shell session; CML VM already exists |
| `30-export-labs.sh` | Export every lab to YAML under `/data/exports/<UTC timestamp>/` via the CML API over SSH, copy that folder to the `exports` container with azcopy | API unreachable |
| `40-down.sh` | Run export; stop all labs; run `/provision/del.sh` over SSH; `terraform destroy` in the submodule only | Deregistration fails, unless `--force-license` |
| `50-tunnels.sh` | `up`, `down`, `status` for SSH `-L` forwards through the CML host, pid files in `~/.cml-tunnels/` | Host unreachable on 22 |
| `90-smoke-test.sh` | API answers; license registered; `/data` mounted; `/data/images` populated; data disk at LUN 0; public IP equals persistent output; `uvx cml-mcp` lists labs | Reports pass or fail per check |

No script ever runs `destroy` against bootstrap or persistent.

## 8. Repo conventions

- `CLAUDE.md`: purpose, scope in and out, repo layout table, commands, STOP
  list (apply, destroy, state, anything under `vendor/`, edits to `CLAUDE.md`
  or `.claude/`), Never list (commit state, hardcode subscription, `0.0.0.0/0`,
  destroy persistent or bootstrap), skill routing table, code style, testing,
  definition of done.
- `.claude/settings.json`: read-only allowlist only. `terraform init`, `fmt`,
  `validate`, `plan`, `output`; `az account show`, `az vm list-skus`,
  `az network` and `az vm` read verbs; `git submodule status`; `bash -n`;
  `shellcheck`; `pre-commit run`. Edit and Write scoped to `terraform/**`,
  `scripts/**`, `config/**`, `docs/**`, `labs/**`.
- Pre-commit: trailing-whitespace, end-of-file-fixer, check-merge-conflict,
  `terraform_fmt`, `terraform_validate`, `shellcheck`, gitleaks.
- `.gitleaks.toml`: default rules plus custom rules for Cisco Smart License
  tokens and Azure storage account keys.
- ADRs in `docs/decisions/NNNN-kebab-title.md`: Status, Context, Decision,
  Consequences, Options considered.
- `STATUS.md`: dated handoff with Where things stand, Done, Deferred on
  purpose, Watch out for, Next.
- `LESSONS-LEARNED.md`: Symptom, Cause, Fix.
- Commits: Conventional Commits, types `feat`, `fix`, `infra`, `docs`, `chore`,
  `test`; subject under 72 characters; one logical change.
- Writing: plain prose, no em-dashes, comments explain why and cite the ADR.

## 9. Error handling

- Scripts fail fast with a remediation pointer naming the exact command.
- `05-persist.sh` logs each step and exits nonzero so the failure is visible in
  `/var/log/cloud-init-output.log` even though upstream swallows the code.
- SAS expiry stays a known failure mode; preflight warns, config extends.
- `prevent_destroy` on the state storage account and data disk makes a
  persistent-root destroy fail by design. `CLAUDE.md` says so.
- License deregistration failure blocks `40-down.sh` by default because a
  stranded license blocks the next build.

## 10. Verification

The seven steps in section 1, run in order on a clean subscription, with
`terraform plan` on the persistent root showing no changes after step 3 and
after step 6. Anything that bit on the first pass goes into
`LESSONS-LEARNED.md` before the spec is marked done.

## 11. Out of scope for this spec

- The ISE and FTD VMs, their NSG rules, and their backup repositories.
- The lab edge C8000v, the host's local bridge, and IP forwarding sysctl on the
  host. These are lab content and arrive with the TrustSec spec.
- Any lab topology YAML.
- Key Vault, managed identity for storage, CI workflows, Azure Bastion.
- Cluster or multi-VM CML.
