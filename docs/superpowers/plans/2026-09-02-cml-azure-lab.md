# cml-azure-lab: repo skeleton and CML tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the repo, the two durable Terraform roots, the cloud-cml fork patches, and the seven operator scripts so a CML instance can be built and destroyed per session with its images and lab exports surviving on a persistent data disk.

**Architecture:** Three Terraform roots split by lifetime: `terraform/bootstrap` (local state, holds the state storage), `terraform/persistent` (blob state, everything that must survive), and `vendor/cloud-cml` (a pinned fork submodule, local state, the disposable CML VM). Bash scripts on the Mac orchestrate the three roots, render the fork's config file from persistent outputs, and talk to the CML host over SSH on port 1122. A provisioning hook inside the fork mounts the data disk and bind-mounts the libvirt images directory onto it before CML installs, so images copy once.

**Tech Stack:** Terraform 1.5.7 with azurerm 4.x, Azure CLI 2.89, azcopy 10.32, bash 3.2 on macOS (scripts) and bash 5 on Ubuntu 24.04 (provisioning), Python 3.14 stdlib only, uv/uvx for cml-mcp, shellcheck, gitleaks, pre-commit.

Spec: `docs/superpowers/specs/2026-09-02-cml-azure-lab-design.md`. Read it once before starting any task.

## Global Constraints

- Terraform `required_version = ">= 1.5.0"` in every root. The Mac has 1.5.7, so no `terraform test`, no `removed` blocks, no provider-defined functions.
- azurerm provider `~> 4.0` in `terraform/bootstrap`, `terraform/persistent`, and the fork's `modules/deploy/azure-on.t-f`. azurerm 5.x is current on the registry and upstream's `>=3.82.0` would pull it in. Argument names are the 4.x names: `ip_forwarding_enabled`, `accelerated_networking_enabled`, `https_traffic_only_enabled`, `storage_account_id`.
- Every Mac-side script runs on bash 3.2: no associative arrays, no `mapfile`, no `${var,,}`, no `declare -A`. Scripts that run on the Ubuntu host may use bash 5, but `05-persist.sh` has a dry-run mode that is tested on the Mac, so it also stays bash 3.2 compatible.
- Every script: `#!/usr/bin/env bash`, `set -euo pipefail`, header comment block, `REPO_ROOT` from `BASH_SOURCE`, env-var overrides with defaults, small named functions, `main "$@"` at the bottom, output lines `[OK]`, `[WARN]`, `[FAIL]`, nonzero exit on any FAIL.
- Python: stdlib only, type hints on every signature, `python3 -m unittest` for tests.
- No script ever runs `terraform destroy` against `terraform/bootstrap` or `terraform/persistent`.
- SSH to the CML host is always port `1122` as user `sysadmin`. Port 22 on a CML host is the console server, not the system shell.
- Nothing is written outside the repo. Tunnel pid files, generated keys, downloaded software, rendered config, and exports all live in gitignored folders under the repo root.
- Region `eastus2`. Subscription only from `ARM_SUBSCRIPTION_ID`. Never `0.0.0.0/0` in an allowed-subnet list.
- Commits: Conventional Commits, types `feat`, `fix`, `infra`, `docs`, `chore`, `test`; subject under 72 characters; one logical change per commit. Fork commits use scope `infra(azure)`.
- Writing: plain prose, no em-dashes. Comments explain why and cite the ADR.
- Naming from the spec, verbatim: `rg-cml-lab-tfstate`, `rg-cml-lab`, `stcmllab<suffix>`, `sshkey-cml-lab`, `pip-cml-lab`, `disk-cml-lab-data`, `vnet-cml-lab` `10.20.0.0/16`, `snet-cml` `10.20.1.0/24`, `snet-apps` `10.20.2.0/24`, `snet-fw-mgmt` `10.20.3.0/24`, `snet-fw-inside` `10.20.4.0/24`, `snet-fw-outside` `10.20.5.0/24`, `rt-apps`, CML private IP `10.20.1.10`, lab summary `10.100.0.0/16`, hostname `cml-controller`.

## Deviations from the spec, decided while planning

Each of these keeps the spec's intent. They are listed here so nobody hunts for the spec text.

1. **Data disk preparation moves out of cloud-init `disk_setup` and into `05-persist.sh pre`.** Terraform attaches the data disk with a separate `azurerm_virtual_machine_data_disk_attachment` after the VM exists, and cloud-init starts at first boot before that attachment lands. A `disk_setup` block would run against a device that is not there yet. The script waits for the LUN 0 device for up to ten minutes, formats it only when blank, and mounts it.
2. **Bind mount instead of symlink.** Upstream's `cml.sh` decides whether to copy the whole refplat folder with `find /var/lib/libvirt/images -type f | wc -l`. `find` does not follow a symlink given as its starting point, so a symlinked images directory always looks empty and triggers a full copy. A bind mount is transparent to `find`.
3. **The hook runs twice.** A `pre` phase from cloud-init's `runcmd` before `cml.sh` mounts the disk, bind-mounts the images directory, and empties the `images` list in `/provision/refplat` when `/data/images` already holds files, so the second build skips the image copy entirely. A `post` phase, run by upstream's `postprocess`, verifies and fixes ownership. This is what makes spec success step 6 mean "no re-copy" instead of "re-copy and then move".
4. **Tunnel pid files live in `.cml-tunnels/` under the repo root**, not `~/.cml-tunnels/`. Repo rule: nothing outside the project folder.
5. **`config/cml.tfvars` is parsed by Python, not Terraform.** It is read by `20-up.sh` and rendered into `config/cml.yml`. The supported syntax is the HCL subset `key = "string"`, `key = 123`, `key = true`, `key = ["a", "b"]`, and `#` comments. The name stays `cml.tfvars` so the `*.tfvars` gitignore covers it.
6. **The refplat selection lives in `config/refplat.txt`**, one `definition image` pair per line. It is the single source for the upload script, the preflight presence check, and the rendered `refplat:` block, so the three can never disagree.
7. **The preflight marker check is age based.** `20-up.sh` refuses when `.preflight-ok` is missing or older than `PREFLIGHT_MAX_AGE_MIN` (default 240). Tying it to the shell session's start time is not portable.
8. **Blob uploads from the Mac use `AZCOPY_AUTO_LOGIN_TYPE=AZCLI`**, which reuses the `az login` session. The persistent root grants the current principal `Storage Blob Data Contributor` on the lab storage account for this.
9. **A project `.mcp.json` plus `scripts/mcp-cml.sh` wrapper** is how Claude Code launches cml-mcp with the credentials from `config/mcp-env/cml.env`. Claude Code's MCP config cannot source a file on its own.
10. **Fork patch 0 is added**: switch the `azure.tf` and `aws.tf` symlinks to the on and off stubs and pin azurerm to 4.x. Upstream expects `prepare.sh` to do the symlink part interactively, which does not fit a submodule.

## Caveat carried forward to the TrustSec and SD-WAN specs

The June 2025 refplat ISO holds `cat8000v`, `cat9000v-q200`, `cat9000v-uadp`, `csr1000v`, `nxosv9300`, `iosxrv9000`, `asav`, `iosv`, `iosvl2`, IOL, and the Linux tools. It does not hold Catalyst SD-WAN Manager, Controller, or Validator images. Confirm what the latest ISO holds before the SD-WAN scenario is planned.

## File structure

```
cml-azure-lab/
├── CLAUDE.md                          Task 1
├── README.md                          Task 1, expanded Task 20
├── .gitignore                         exists, extended Task 1
├── .gitmodules                        Task 6
├── .mcp.json                          Task 9
├── .pre-commit-config.yaml            Task 1
├── .gitleaks.toml                     Task 1
├── .claude/settings.json              Task 1
├── vendor/cloud-cml/                  Task 6, submodule
├── terraform/
│   ├── bootstrap/{versions,providers,main,outputs}.tf      Task 3
│   └── persistent/{versions,providers,backend,variables,locals,main,outputs}.tf  Task 4, 5
│       └── terraform.tfvars.example
├── config/
│   ├── refplat.txt                    Task 9
│   ├── cml.tfvars.example             Task 9
│   ├── cml.yml.tftpl                  Task 9
│   ├── tunnels.conf.example           Task 17
│   └── mcp-env/.gitignore             Task 9
├── keys/.gitignore                    Task 1
├── exports/.gitignore                 Task 1
├── labs/README.md                     Task 1
├── scripts/
│   ├── lib/common.sh                  Task 2
│   ├── lib/tfvars.py                  Task 9
│   ├── lib/render_cml_config.py       Task 9
│   ├── lib/cml-remote.sh              Task 10
│   ├── lib/mcp_call.py                Task 11
│   ├── mcp-cml.sh                     Task 9
│   ├── 00-preflight.sh                Task 12
│   ├── 10-upload-images.sh            Task 13
│   ├── 20-up.sh                       Task 14
│   ├── 30-export-labs.sh              Task 15
│   ├── 40-down.sh                     Task 16
│   ├── 50-tunnels.sh                  Task 17
│   └── 90-smoke-test.sh               Task 18
├── tests/
│   ├── run.sh                         Task 2
│   ├── test_common.sh                 Task 2
│   ├── test_persist.sh                Task 8
│   ├── test_tfvars.py                 Task 9
│   ├── test_render.py                 Task 9
│   ├── fake_cml_api.py                Task 10
│   ├── test_cml_remote.sh             Task 10
│   ├── fake_mcp_server.py             Task 11
│   ├── test_mcp_call.py               Task 11
│   ├── test_upload_dry_run.sh         Task 13
│   └── test_up_dry_run.sh             Task 14
└── docs/
    ├── decisions/0001..0004           Task 19
    ├── STATUS.md                      Task 20
    └── LESSONS-LEARNED.md             Task 20
```

Fork branch `azure-lab` in `vendor/cloud-cml`, one commit per numbered patch:

```
modules/deploy/azure.tf -> azure-on.t-f, aws.tf -> aws-off.t-f, azure-on.t-f pin   patch 0, Task 6
modules/deploy/azure/main.tf                                                        patches 1 to 8, Tasks 7
modules/deploy/azure/output.tf                                                      patch 2, Task 7
modules/deploy/data/cloud-config.txt                                                patch 9, Task 8
modules/deploy/data/05-persist.sh                                                   patch 10, Task 8
```

## Interfaces shared across tasks

These names are used by more than one task. Later tasks assume them exactly.

**`scripts/lib/common.sh`** (Task 2), sourced by every script:

```bash
REPO_ROOT                      # absolute repo root, exported
pass "msg"; warn "msg"; miss "msg"   # print [OK]/[WARN]/[FAIL], bump counters ok/warns/fail
summary_and_exit               # print "summary: N OK, N WARN, N FAIL", exit 1 if fail > 0
die "msg"                      # print [FAIL] msg to stderr, exit 1
require_cmd terraform az       # die if any command missing
require_env ARM_SUBSCRIPTION_ID
tf_out ROOT NAME               # terraform -chdir=$REPO_ROOT/terraform/ROOT output -raw NAME
cml_ip                         # public IP from the persistent root output public_ip_address
cml_ssh "cmd"                  # ssh -p 1122 -i keys/cml-lab -o StrictHostKeyChecking=accept-new sysadmin@$(cml_ip) cmd
confirm "question"             # returns 0 on y/yes or when ASSUME_YES=1, else 1
```

**Persistent root outputs** (Task 4), read with `tf_out persistent NAME`:
`resource_group_name`, `location`, `storage_account_name`, `cml_container_name`, `exports_container_name`, `ssh_key_name`, `public_ip_name`, `public_ip_address`, `data_disk_id`, `vnet_name`, `cml_subnet_name`, `cml_subnet_id`, `apps_subnet_id`, `apps_subnet_cidr`, `cml_private_ip`, `lab_summary_cidr`, `app_admin_password` (sensitive), `sys_admin_password` (sensitive).

**Bootstrap root outputs** (Task 3): `resource_group_name`, `storage_account_name`, `container_name`.

**`config/cml.tfvars` keys** (Task 9): `smartlicense_token`, `license_flavor`, `allowed_ipv4_subnets_mgmt`, `allowed_ipv4_subnets_cml2`, `vm_size`, `os_disk_size_gb`, `spot_enabled`, `spot_max_bid_price`, `sas_validity`, `software_package`.

**`config/cml.yml.tftpl` placeholders** (Task 9), all `${NAME}` and all required: `RESOURCE_GROUP`, `STORAGE_ACCOUNT`, `CONTAINER_NAME`, `VM_SIZE`, `VNET_NAME`, `SUBNET_NAME`, `PRIVATE_IP`, `PUBLIC_IP_NAME`, `DATA_DISK_ID`, `OS_DISK_TYPE`, `SAS_VALIDITY`, `SPOT_ENABLED`, `SPOT_MAX_BID_PRICE`, `APPS_SUBNET_CIDR`, `LAB_SUMMARY_CIDR`, `OS_DISK_SIZE_GB`, `SSH_KEY_NAME`, `ALLOWED_MGMT`, `ALLOWED_CML2`, `APP_PASSWORD`, `SYS_PASSWORD`, `LICENSE_TOKEN`, `LICENSE_FLAVOR`, `SOFTWARE_PACKAGE`, `REFPLAT_DEFINITIONS`, `REFPLAT_IMAGES`.

**Fork config keys read by the patched module** (Task 7), all under `azure:`. Required, no default: `vnet_name`, `subnet_name`, `private_ip`, `public_ip_name`. Optional, read with `try()` and a default: `os_disk_type` (Premium_LRS), `data_disk_id` (empty, no attachment), `sas_validity` (4h), `spot.enabled` (false), `spot.max_bid_price` (-1), `apps_subnet_cidr` (empty, no NSG rule), `lab_summary_cidr`.

**`scripts/lib/cml-remote.sh` subcommands** (Task 10), run on the host through `cml_ssh "bash -s -- CMD" < scripts/lib/cml-remote.sh`: `list-labs`, `export-labs DIR`, `stop-labs`, `license-status`, `deregister`.

**`scripts/lib/mcp_call.py`** (Task 11): `python3 scripts/lib/mcp_call.py --cmd "scripts/mcp-cml.sh" --tool get_cml_labs` prints the tool result text and exits 0.

---

### Task 1: Repo conventions and guardrails

**Files:**
- Create: `CLAUDE.md`
- Create: `.claude/settings.json`
- Create: `.pre-commit-config.yaml`
- Create: `.gitleaks.toml`
- Create: `keys/.gitignore`, `exports/.gitignore`, `labs/README.md`, `README.md`
- Modify: `.gitignore` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: the STOP and Never lists every later task obeys; the pre-commit gate every later commit passes; the allowlist that lets read-only Terraform and Azure commands run without prompts.

- [ ] **Step 1: Write the failing check**

Pre-commit is the test harness for this task. Run it before any files exist to confirm it is not silently passing:

Run: `cd "$REPO" && pre-commit run --all-files`
Expected: error `InvalidConfigError` or `No .pre-commit-config.yaml file was found`.

- [ ] **Step 2: Append to `.gitignore`**

```gitignore

# Generated by scripts, never committed
.preflight-ok
.cml-tunnels/
.refplat-mount/
.azcopy/
tests/.tmp*/
keys/*
!keys/.gitignore
exports/*
!exports/.gitignore
config/tunnels.conf
```

- [ ] **Step 3: Create the self-ignoring folders and the labs placeholder**

`keys/.gitignore`:
```gitignore
# SSH key pair for the CML host, generated by scripts/20-up.sh. Never committed.
*
!.gitignore
```

`exports/.gitignore`:
```gitignore
# Local copies of lab exports pulled by scripts/30-export-labs.sh. The blob
# container "exports" is the durable copy. Never committed.
*
!.gitignore
```

`labs/README.md`:
```markdown
# labs/

One YAML topology per scenario. Empty in the repo skeleton spec. The TrustSec
spec adds the first topology.
```

- [ ] **Step 4: Write `.pre-commit-config.yaml`**

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v5.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-merge-conflict
      - id: detect-private-key
      - id: check-added-large-files
        args: ["--maxkb=1024"]

  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.96.1
    hooks:
      - id: terraform_fmt
        files: ^terraform/
      - id: terraform_validate
        files: ^terraform/
        args:
          - --hook-config=--retry-once-with-cleanup=true
          - --tf-init-args=-backend=false

  - repo: https://github.com/shellcheck-py/shellcheck-py
    rev: v0.10.0.1
    hooks:
      - id: shellcheck
        files: \.sh$
        args: ["--severity=warning", "--external-sources"]

  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.21.2
    hooks:
      - id: gitleaks
```

Note: `vendor/` is a submodule, so pre-commit never sees its files. The fork is checked by hand with `shellcheck` and `terraform validate` in Tasks 6 to 8.

- [ ] **Step 5: Write `.gitleaks.toml`**

```toml
title = "cml-azure-lab gitleaks config"

[extend]
useDefault = true

[allowlist]
description = "Examples and docs carry placeholders, never real values"
paths = [
  '''config/cml\.tfvars\.example''',
  '''terraform/persistent/terraform\.tfvars\.example''',
  '''config/tunnels\.conf\.example''',
  '''docs/.*\.md''',
  '''tests/.*''',
]

# Cisco Smart License tokens are long base64-like strings that usually end in
# the URL-encoded newline "%0A". Match any assignment of one.
[[rules]]
id = "cisco-smart-license-token"
description = "Cisco Smart License registration token"
regex = '''(?i)(smart[-_]?licen[cs]e[-_]?token|CFG_LICENSE_TOKEN|LICENSE_TOKEN)\s*[=:]\s*['"]?[A-Za-z0-9+/=%_-]{40,}'''
tags = ["cisco", "credential"]

# Azure storage account keys are 88 characters of base64 ending in "==".
[[rules]]
id = "azure-storage-account-key"
description = "Azure storage account access key"
regex = '''(?i)(AccountKey|storage[-_]?account[-_]?key|ARM_ACCESS_KEY)\s*[=:]\s*['"]?[A-Za-z0-9+/]{86}=='''
tags = ["azure", "credential"]

# The persistent root generates these; they must never land in a file.
[[rules]]
id = "cml-admin-password"
description = "CML admin or sysadmin password assignment"
regex = '''(?i)(CML_PASSWORD|CFG_APP_PASS|CFG_SYS_PASS|raw_secret)\s*[=:]\s*['"]?[A-Za-z0-9]{16}['"]?\s*$'''
tags = ["cml", "credential"]
```

- [ ] **Step 6: Write `.claude/settings.json`**

```json
{
  "permissions": {
    "allow": [
      "Bash(terraform init*)",
      "Bash(terraform fmt*)",
      "Bash(terraform validate*)",
      "Bash(terraform plan*)",
      "Bash(terraform output*)",
      "Bash(terraform version)",
      "Bash(terraform -chdir=terraform/bootstrap init*)",
      "Bash(terraform -chdir=terraform/bootstrap fmt*)",
      "Bash(terraform -chdir=terraform/bootstrap validate*)",
      "Bash(terraform -chdir=terraform/bootstrap plan*)",
      "Bash(terraform -chdir=terraform/bootstrap output*)",
      "Bash(terraform -chdir=terraform/persistent init*)",
      "Bash(terraform -chdir=terraform/persistent fmt*)",
      "Bash(terraform -chdir=terraform/persistent validate*)",
      "Bash(terraform -chdir=terraform/persistent plan*)",
      "Bash(terraform -chdir=terraform/persistent output*)",
      "Bash(terraform -chdir=vendor/cloud-cml init*)",
      "Bash(terraform -chdir=vendor/cloud-cml fmt*)",
      "Bash(terraform -chdir=vendor/cloud-cml validate*)",
      "Bash(terraform -chdir=vendor/cloud-cml plan*)",
      "Bash(terraform -chdir=vendor/cloud-cml output*)",
      "Bash(az account show*)",
      "Bash(az vm list-skus*)",
      "Bash(az vm list-usage*)",
      "Bash(az vm show*)",
      "Bash(az vm list*)",
      "Bash(az vm get-instance-view*)",
      "Bash(az network * show*)",
      "Bash(az network * list*)",
      "Bash(az storage blob list*)",
      "Bash(az group show*)",
      "Bash(git submodule status*)",
      "Bash(git status*)",
      "Bash(git diff*)",
      "Bash(git log*)",
      "Bash(bash -n *)",
      "Bash(shellcheck *)",
      "Bash(pre-commit run *)",
      "Bash(tests/run.sh*)",
      "Bash(python3 -m unittest*)",
      "Bash(scripts/00-preflight.sh*)",
      "Bash(scripts/50-tunnels.sh status)",
      "Bash(scripts/90-smoke-test.sh*)",
      "Edit(terraform/**)",
      "Write(terraform/**)",
      "Edit(scripts/**)",
      "Write(scripts/**)",
      "Edit(tests/**)",
      "Write(tests/**)",
      "Edit(config/**)",
      "Write(config/**)",
      "Edit(docs/**)",
      "Write(docs/**)",
      "Edit(labs/**)",
      "Write(labs/**)"
    ]
  }
}
```

- [ ] **Step 7: Write `CLAUDE.md`**

```markdown
# cml-azure-lab

An on-demand Cisco Modeling Labs instance in Azure. Built and destroyed per
session. The things that must survive a rebuild live in a separate,
never-destroyed Terraform root. Claude Code runs on the Mac and drives CML
through the cml-mcp server and SSH.

Spec: `docs/superpowers/specs/2026-09-02-cml-azure-lab-design.md`.
Prerequisites you must provide: `docs/PREREQUISITES.md`.

## Scope

In scope: the repo skeleton, the bootstrap and persistent Terraform roots,
the cloud-cml fork patches, the operator scripts, and the cml-mcp wiring.

Out of scope until their own specs exist: ISE and FTD VMs, the lab edge
router and the host's local bridge, any lab topology YAML, Key Vault,
managed identity, CI, Bastion, CML clusters.

Do not add out-of-scope components. If a task seems to need one, stop and ask.

## Repo layout

| Path | Contents |
|---|---|
| `terraform/bootstrap/` | Local state. Creates the state storage account. Never destroyed. |
| `terraform/persistent/` | Blob state. Everything under `rg-cml-lab` that survives a rebuild. Never destroyed. |
| `vendor/cloud-cml/` | Git submodule, our fork on branch `azure-lab`. The disposable CML VM. Local state. |
| `config/` | Templates and examples. Rendered `cml.yml` and `mcp-env/` are gitignored. |
| `scripts/` | Numbered bash, `00-` through `90-`. Shared helpers in `scripts/lib/`. |
| `tests/` | `tests/run.sh` runs every check. Python unittest, bash dry-run tests. |
| `software/` | Cisco downloads. Gitignored except its README. |
| `labs/` | One YAML topology per scenario. Empty for now. |
| `docs/decisions/` | ADRs. One file per decision. |
| `docs/STATUS.md` | Dated handoff. Read it first in a new session. |
| `docs/LESSONS-LEARNED.md` | Symptom, cause, fix. Add to it when something bites. |

## Commands

    scripts/00-preflight.sh                 # read-only readiness check
    scripts/10-upload-images.sh --dry-run   # what would be uploaded
    scripts/20-up.sh                        # bootstrap, persistent, CML
    scripts/30-export-labs.sh               # every lab to YAML, to blob
    scripts/40-down.sh                      # export, deregister, destroy CML only
    scripts/50-tunnels.sh up|down|status    # SSH forwards through the CML host
    scripts/90-smoke-test.sh                # post-build checks
    tests/run.sh                            # all local tests
    pre-commit run --all-files

    terraform -chdir=terraform/persistent plan   # must show no changes after a build

## STOP and ask a human

Do not proceed on inference.

- `terraform apply`, `terraform destroy`, any `terraform state` or `terraform import` subcommand, in any root
- `scripts/20-up.sh` and `scripts/40-down.sh` without `--dry-run`
- Anything under `vendor/`: edits, commits, submodule pointer bumps, upstream merges
- Editing `CLAUDE.md`, `.claude/`, `.gitignore`, `.pre-commit-config.yaml`, `.gitleaks.toml`
- Installing or upgrading a tool, provider, or Python package
- Git history rewrites on pushed commits
- Creating a file outside the paths in Repo layout

## Never

- Never commit state. `*.tfstate*` is gitignored. Do not remove that line.
- Never hardcode the subscription ID or tenant ID. They come from `ARM_SUBSCRIPTION_ID` and `az account show`.
- Never put `0.0.0.0/0` in an allowed-subnet list.
- Never run destroy against `terraform/bootstrap` or `terraform/persistent`. Both carry `prevent_destroy` and a destroy fails by design.
- Never write a secret, token, password, or key into a tracked file. Rendered config and `mcp-env/` are gitignored for this reason.
- Never create files outside this repo. Not in the home directory, not in `/tmp`.
- Never ask the human to paste a secret into chat.

## Skills

Load the matching skill before writing. Name it in the response.

| Task | Skills |
|---|---|
| Terraform in `terraform/` or the fork | `terraform-patterns`, `azure-cloud-architect`, `cloud-security` |
| Fork patches under `vendor/` | `karpathy-guidelines`, smallest possible diff |
| Bash and Python in `scripts/` | `senior-secops` for anything touching credentials |
| Secrets handling, gitleaks rules | `env-secrets-manager` |
| Reviewing changes before an apply | `adversarial-reviewer` |
| Debugging anything broken | `systematic-debugging`. Do not blind-patch. |
| ADRs, STATUS, prose | `humanizer` |

## Code style

- Bash: `set -euo pipefail`, bash 3.2 compatible on the Mac side, quote every variable, no unguarded `rm`, functions under 40 lines, `main "$@"` at the bottom, `[OK]` `[WARN]` `[FAIL]` output.
- Python: stdlib only, type hints on every signature, `unittest`.
- Terraform: every variable has a description and a type, every resource carries `local.common_tags`, no magic strings.
- Comments explain why and cite the ADR. Plain prose. No em-dashes.

## Testing

- `tests/run.sh` must pass before any commit. It runs shellcheck, `bash -n`, Python unittest, and the bash dry-run tests.
- `terraform fmt -check` and `terraform validate` on all three roots.
- `pre-commit run --all-files`.
- After a real build, `scripts/90-smoke-test.sh` and `terraform -chdir=terraform/persistent plan` showing no changes.

## Definition of done

1. Skill named in the response.
2. ADR written for any architectural change.
3. `tests/run.sh` and `pre-commit run --all-files` pass.
4. One logical commit with a Conventional Commits message.
5. Changed files and their purpose summarized.
6. `docs/STATUS.md` updated if the state of the build changed.
```

- [ ] **Step 8: Write `README.md`**

```markdown
# cml-phoenix

An on-demand Cisco Modeling Labs instance in Azure that is built and
destroyed per session. Reference platform images and lab exports survive on
a persistent data disk and blob storage, so a rebuild costs minutes, not an
afternoon.

- Design: `docs/superpowers/specs/2026-09-02-cml-azure-lab-design.md`
- What you need before the first build: `docs/PREREQUISITES.md`
- How the work is organized for Claude Code: `CLAUDE.md`
- Current state: `docs/STATUS.md`

Built on [CiscoDevNet/cloud-cml](https://github.com/CiscoDevNet/cloud-cml)
through a lightly patched fork, pinned as a submodule. Driven from the Mac
with [cml-mcp](https://github.com/xorrkaz/cml-mcp).
```

- [ ] **Step 9: Run the gate**

Run: `cd "$REPO" && git submodule status; pre-commit run --all-files`
Expected: every hook `Passed` or `Skipped` (terraform hooks skip because no `.tf` files exist yet). If `end-of-file-fixer` or `trailing-whitespace` modify files, re-run until clean.

- [ ] **Step 10: Prove the custom gitleaks rule fires**

Run:
```bash
cd "$REPO" && printf 'smartlicense_token = "%s"\n' "$(printf 'A%.0s' $(seq 1 60))" | gitleaks stdin --config .gitleaks.toml -v 2>&1 | grep -q 'cisco-smart-license-token' && echo RULE-FIRES
```
Expected: `RULE-FIRES`. If gitleaks reports the deprecated `detect --pipe` form instead, the installed version is older than 8.19; `gitleaks detect --pipe --config .gitleaks.toml -v` is the equivalent.

- [ ] **Step 11: Commit**

```bash
git add CLAUDE.md README.md .claude/settings.json .pre-commit-config.yaml .gitleaks.toml .gitignore keys/.gitignore exports/.gitignore labs/README.md
git commit -m "chore: add repo conventions, pre-commit, gitleaks, and Claude settings"
```

---

### Task 2: Shared bash library and test runner

**Files:**
- Create: `scripts/lib/common.sh`
- Create: `tests/run.sh`
- Create: `tests/test_common.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `REPO_ROOT`, `pass`, `warn`, `miss`, `summary_and_exit`, `die`, `require_cmd`, `require_env`, `tf_out`, `cml_ip`, `cml_ssh`, `confirm`, exactly as listed under "Interfaces shared across tasks". `tests/run.sh` is the single local gate used by every later task.

- [ ] **Step 1: Write the failing test**

`tests/test_common.sh`:
```bash
#!/usr/bin/env bash
# Tests for scripts/lib/common.sh. Runs on macOS bash 3.2.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    echo "[OK]    ${label}"
  else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"
    failures=$((failures + 1))
  fi
}

# Each case runs in a subshell so counters and exit codes stay isolated.

out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; pass a; warn b; miss c; summary_and_exit" 2>&1 || true)"
assert_eq "summary counts" "summary: 1 OK, 1 WARN, 1 FAIL" "$(echo "${out}" | tail -1)"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; pass a; summary_and_exit" >/dev/null 2>&1 || rc=$?
assert_eq "exit 0 with no FAIL" "0" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; miss a; summary_and_exit" >/dev/null 2>&1 || rc=$?
assert_eq "exit 1 with a FAIL" "1" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_cmd bash definitely-not-a-command-xyz" >/dev/null 2>&1 || rc=$?
assert_eq "require_cmd fails on missing tool" "1" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; require_env NOT_SET_VAR_XYZ" >/dev/null 2>&1 || rc=$?
assert_eq "require_env fails on unset var" "1" "${rc}"

rc=0; bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; ASSUME_YES=1 confirm 'go?'" >/dev/null 2>&1 || rc=$?
assert_eq "confirm honours ASSUME_YES" "0" "${rc}"

rc=0; echo "n" | bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; confirm 'go?'" >/dev/null 2>&1 || rc=$?
assert_eq "confirm returns 1 on n" "1" "${rc}"

out="$(bash -c "source '${REPO_ROOT}/scripts/lib/common.sh'; echo \"\${REPO_ROOT}\"")"
assert_eq "REPO_ROOT resolves" "${REPO_ROOT}" "${out}"

if [[ "${failures}" -gt 0 ]]; then
  echo "test_common: ${failures} failure(s)"
  exit 1
fi
echo "test_common: all passed"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_common.sh`
Expected: several `[FAIL]` lines (the library does not exist), exit 1.

- [ ] **Step 3: Write `scripts/lib/common.sh`**

```bash
#!/usr/bin/env bash
# Shared helpers for every script in scripts/. Source it, do not run it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Provides: REPO_ROOT, pass/warn/miss counters, summary_and_exit, die,
# require_cmd, require_env, tf_out, cml_ip, cml_ssh, confirm.
#
# Must stay bash 3.2 compatible: this runs on macOS.

# Resolve the repo root from this file, two levels up, regardless of cwd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

ok=0
warns=0
fail=0

if [[ -t 1 ]]; then
  green='\033[32m'; yellow='\033[33m'; red='\033[31m'; reset='\033[0m'
else
  green=''; yellow=''; red=''; reset=''
fi

pass() { printf "${green}[OK]${reset}    %s\n" "$1"; ok=$((ok + 1)); }
warn() { printf "${yellow}[WARN]${reset}  %s\n" "$1"; warns=$((warns + 1)); }
miss() { printf "${red}[FAIL]${reset}  %s\n" "$1"; fail=$((fail + 1)); }

summary_and_exit() {
  printf "\nsummary: %d OK, %d WARN, %d FAIL\n" "${ok}" "${warns}" "${fail}"
  if [[ "${fail}" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

die() {
  printf "${red}[FAIL]${reset}  %s\n" "$1" >&2
  exit 1
}

require_cmd() {
  local tool
  for tool in "$@"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      die "${tool} is not installed. See docs/PREREQUISITES.md section 4."
    fi
  done
}

require_env() {
  local name
  for name in "$@"; do
    if [[ -z "${!name:-}" ]]; then
      die "${name} is not set. See docs/PREREQUISITES.md section 2.2."
    fi
  done
}

# tf_out ROOT NAME: raw output from terraform/ROOT. ROOT is bootstrap or
# persistent. The cloud-cml root has its own outputs and is read directly.
tf_out() {
  local root="$1" name="$2"
  terraform -chdir="${REPO_ROOT}/terraform/${root}" output -raw "${name}"
}

cml_ip() {
  tf_out persistent public_ip_address
}

# cml_ssh CMD...: run a command on the CML host as sysadmin. Port 1122 is the
# system shell on a CML host; 22 is the console server (ADR 0003 notes).
cml_ssh() {
  local key="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
  ssh -p 1122 -i "${key}" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "sysadmin@$(cml_ip)" "$@"
}

# confirm QUESTION: prompt for y/yes. ASSUME_YES=1 skips the prompt so
# scripts can run unattended when the human has already decided.
confirm() {
  local question="$1" answer
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  printf "%s [y/N] " "${question}"
  read -r answer
  case "${answer}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}
```

- [ ] **Step 4: Write `tests/run.sh`**

```bash
#!/usr/bin/env bash
# Runs every local check. This is the gate before any commit.
#
#   1. bash -n on every script
#   2. shellcheck on every script (warning severity, external sources)
#   3. Python unittest discovery in tests/
#   4. Every tests/test_*.sh
#
# Exit code is nonzero if anything fails.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
failed=0

echo "== bash -n"
for f in scripts/*.sh scripts/lib/*.sh tests/*.sh; do
  [[ -f "${f}" ]] || continue
  if ! bash -n "${f}"; then
    echo "[FAIL]  syntax: ${f}"; failed=1
  fi
done

echo "== shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2046
  if ! shellcheck --severity=warning --external-sources $(ls scripts/*.sh scripts/lib/*.sh tests/*.sh 2>/dev/null); then
    failed=1
  fi
else
  echo "[WARN]  shellcheck not installed, skipping"
fi

echo "== python unittest"
if ls tests/test_*.py >/dev/null 2>&1; then
  if ! python3 -m unittest discover -s tests -p 'test_*.py'; then
    failed=1
  fi
else
  echo "(no python tests yet)"
fi

echo "== bash tests"
for t in tests/test_*.sh; do
  [[ -f "${t}" ]] || continue
  echo "-- ${t}"
  if ! bash "${t}"; then
    failed=1
  fi
done

if [[ "${failed}" -ne 0 ]]; then
  echo "tests/run.sh: FAILED"
  exit 1
fi
echo "tests/run.sh: all passed"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `chmod +x tests/run.sh scripts/lib/common.sh && tests/run.sh`
Expected: `test_common: all passed` and `tests/run.sh: all passed`. shellcheck clean.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/common.sh tests/run.sh tests/test_common.sh
git commit -m "feat: add shared bash helpers and local test runner"
```

---

### Task 3: Bootstrap Terraform root

**Files:**
- Create: `terraform/bootstrap/versions.tf`
- Create: `terraform/bootstrap/providers.tf`
- Create: `terraform/bootstrap/main.tf`
- Create: `terraform/bootstrap/outputs.tf`

**Interfaces:**
- Consumes: `ARM_SUBSCRIPTION_ID` from the shell.
- Produces: outputs `resource_group_name`, `storage_account_name`, `container_name`. Task 5 copies them into `terraform/persistent/backend.tf`.

- [ ] **Step 1: Confirm the gate fails first**

Run: `terraform -chdir=terraform/bootstrap validate`
Expected: error, directory does not exist.

- [ ] **Step 2: Write `versions.tf`**

```hcl
# Bootstrap root: local state. Creates the storage that holds every other
# root's state, so it cannot use blob state itself. ADR 0002.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
```

- [ ] **Step 3: Write `providers.tf`**

```hcl
# Subscription and tenant come from ARM_SUBSCRIPTION_ID and the az login
# session. Nothing is hardcoded here on purpose (CLAUDE.md, Never list).
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}
```

- [ ] **Step 4: Write `main.tf`**

```hcl
# Who is running Terraform. Used to grant data-plane access to the state
# container: subscription Contributor does not include blob data access.
data "azurerm_client_config" "current" {}

locals {
  common_tags = {
    project = "cml-azure-lab"
    owner   = var.owner
    expires = var.expires
    purpose = "terraform-state"
  }
}

variable "location" {
  description = "Azure region for the state storage. Same region as the lab."
  type        = string
  default     = "eastus2"
}

variable "owner" {
  description = "Tag value: who owns these resources."
  type        = string
}

variable "expires" {
  description = "Tag value: review date, YYYY-MM-DD. Informational only."
  type        = string
}

variable "soft_delete_retention_days" {
  description = "Days a deleted or overwritten state blob can be recovered."
  type        = number
  default     = 14
}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-cml-lab-tfstate"
  location = var.location
  tags     = local.common_tags
}

# Storage account names are global and must be 3 to 24 lowercase
# alphanumerics. The random suffix keeps the name unique without a human
# picking one. It lives in local state, which is why that state is precious.
resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "tfstate" {
  name                            = "st${random_string.suffix.result}tfstate"
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = azurerm_resource_group.tfstate.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  # The persistent root authenticates with Azure AD (use_azuread_auth in
  # backend.tf). Shared keys stay on only because the azurerm provider still
  # reads them when managing blob properties; nothing in this repo uses them.
  shared_access_key_enabled = true
  tags                      = local.common_tags

  blob_properties {
    versioning_enabled = true
    delete_retention_policy {
      days = var.soft_delete_retention_days
    }
    container_delete_retention_policy {
      days = var.soft_delete_retention_days
    }
  }

  # Losing this account loses the persistent root's state. ADR 0002.
  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

resource "azurerm_role_assignment" "tfstate_blob" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}
```

- [ ] **Step 5: Write `outputs.tf`**

```hcl
# These three values are copied verbatim into terraform/persistent/backend.tf
# by Task 5. If they change, backend.tf must change with them.
output "resource_group_name" {
  description = "Resource group holding the state storage account."
  value       = azurerm_resource_group.tfstate.name
}

output "storage_account_name" {
  description = "Storage account holding the state container."
  value       = azurerm_storage_account.tfstate.name
}

output "container_name" {
  description = "Blob container holding every remote state file."
  value       = azurerm_storage_container.tfstate.name
}
```

- [ ] **Step 6: Write `terraform.tfvars.example` and a local `terraform.tfvars`**

`terraform/bootstrap/terraform.tfvars.example`:
```hcl
owner   = "your-name"
expires = "2027-03-01"
```

Copy it to `terraform/bootstrap/terraform.tfvars` (gitignored) and fill in real values before planning.

- [ ] **Step 7: Format, validate, and plan**

Run:
```bash
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap fmt -check
terraform -chdir=terraform/bootstrap validate
terraform -chdir=terraform/bootstrap plan
```
Expected: `Success! The configuration is valid.` and a plan of 5 to add (resource group, random string, storage account, container, role assignment), 0 to change, 0 to destroy.

- [ ] **Step 8: Commit, including the lock file**

```bash
git add terraform/bootstrap/*.tf terraform/bootstrap/.terraform.lock.hcl terraform/bootstrap/terraform.tfvars.example
git commit -m "infra: add bootstrap root for Terraform state storage"
```

Note: `.gitignore` ignores `**/.terraform/` and `*.tfstate*` but not the root lock files. Only the submodule's lock file is ignored. Committing the lock file pins azurerm to the exact 4.x release that validated.

---

### Task 4: Persistent Terraform root

**Files:**
- Create: `terraform/persistent/versions.tf`
- Create: `terraform/persistent/providers.tf`
- Create: `terraform/persistent/backend.tf` (placeholder values, replaced in Task 5)
- Create: `terraform/persistent/variables.tf`
- Create: `terraform/persistent/locals.tf`
- Create: `terraform/persistent/main.tf`
- Create: `terraform/persistent/outputs.tf`
- Create: `terraform/persistent/terraform.tfvars.example`

**Interfaces:**
- Consumes: `keys/cml-lab.pub` (generated in Task 5 step 1).
- Produces: the outputs listed under "Interfaces shared across tasks". Task 9's template and Task 14's `20-up.sh` read them by these exact names.

- [ ] **Step 1: Confirm the gate fails first**

Run: `terraform -chdir=terraform/persistent validate`
Expected: error, directory does not exist.

- [ ] **Step 2: Write `versions.tf`**

```hcl
# Persistent root: everything under rg-cml-lab that must survive a CML
# rebuild. Blob state in the bootstrap root's storage account. ADR 0002.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
```

- [ ] **Step 3: Write `providers.tf`**

```hcl
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}
```

- [ ] **Step 4: Write `backend.tf` with placeholders**

```hcl
# Static values copied from `terraform -chdir=terraform/bootstrap output`.
# Backend blocks cannot reference variables, which is why they are literal.
# Task 5 replaces the placeholders after the bootstrap apply.
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-cml-lab-tfstate"
    storage_account_name = "REPLACE_AFTER_BOOTSTRAP_APPLY"
    container_name       = "tfstate"
    key                  = "persistent.tfstate"
    use_azuread_auth     = true
  }
}
```

- [ ] **Step 5: Write `variables.tf`**

```hcl
variable "location" {
  description = "Azure region. Must match the bootstrap root."
  type        = string
  default     = "eastus2"
}

variable "owner" {
  description = "Tag value: who owns these resources."
  type        = string
}

variable "expires" {
  description = "Tag value: review date, YYYY-MM-DD. Informational only."
  type        = string
}

variable "ssh_public_key_file" {
  description = "Path to the RSA public key for the CML host, relative to this root."
  type        = string
  default     = "../../keys/cml-lab.pub"
}

variable "data_disk_size_gb" {
  description = "Size of the persistent data disk that holds refplat images and exports."
  type        = number
  default     = 512
}

variable "vnet_cidr" {
  description = "Address space of the lab VNet."
  type        = string
  default     = "10.20.0.0/16"
}

variable "cml_subnet_cidr" {
  description = "Subnet for the CML host."
  type        = string
  default     = "10.20.1.0/24"
}

variable "apps_subnet_cidr" {
  description = "Subnet for ISE and future appliances. Carries the route to the lab."
  type        = string
  default     = "10.20.2.0/24"
}

variable "fw_mgmt_subnet_cidr" {
  description = "Reserved for FTDv management."
  type        = string
  default     = "10.20.3.0/24"
}

variable "fw_inside_subnet_cidr" {
  description = "Reserved for FTDv inside."
  type        = string
  default     = "10.20.4.0/24"
}

variable "fw_outside_subnet_cidr" {
  description = "Reserved for FTDv outside."
  type        = string
  default     = "10.20.5.0/24"
}

variable "lab_summary_cidr" {
  description = "Summary prefix for every network inside CML. Routed to the CML host. ADR 0003."
  type        = string
  default     = "10.100.0.0/16"
}

variable "cml_private_ip" {
  description = "Static private IP of the CML host. Next hop for the lab summary route."
  type        = string
  default     = "10.20.1.10"
}
```

- [ ] **Step 6: Write `locals.tf`**

```hcl
locals {
  resource_group_name = "rg-cml-lab"

  common_tags = {
    project = "cml-azure-lab"
    owner   = var.owner
    expires = var.expires
  }
}
```

- [ ] **Step 7: Write `main.tf`**

```hcl
data "azurerm_client_config" "current" {}

resource "azurerm_resource_group" "lab" {
  name     = local.resource_group_name
  location = var.location
  tags     = local.common_tags
}

# ---- Storage: CML package, refplat images, lab exports --------------------

resource "random_string" "suffix" {
  length  = 6
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_storage_account" "lab" {
  name                            = "stcmllab${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  # cloud-cml builds a read-only SAS from the account's connection string so
  # the VM can pull images with azcopy. That needs shared keys on. ADR 0001.
  shared_access_key_enabled = true
  tags                      = local.common_tags
}

resource "azurerm_storage_container" "cml" {
  name                  = "cml"
  storage_account_id    = azurerm_storage_account.lab.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "exports" {
  name                  = "exports"
  storage_account_id    = azurerm_storage_account.lab.id
  container_access_type = "private"
}

# The Mac uploads images and exports with azcopy using the az login session
# (AZCOPY_AUTO_LOGIN_TYPE=AZCLI). That is data-plane access, granted here.
resource "azurerm_role_assignment" "lab_blob" {
  scope                = azurerm_storage_account.lab.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# ---- Identity and addressing that must not change between builds ---------

resource "azurerm_ssh_public_key" "cml" {
  name                = "sshkey-cml-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  public_key          = file("${path.root}/${var.ssh_public_key_file}")
  tags                = local.common_tags
}

# Standard SKU is required for a static IP that survives VM deletion. The
# cml-mcp config on the Mac points at this address. ADR 0003.
resource "azurerm_public_ip" "cml" {
  name                = "pip-cml-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# ---- Data disk: refplat images and exports live here -----------------------

resource "azurerm_managed_disk" "data" {
  name                 = "disk-cml-lab-data"
  resource_group_name  = azurerm_resource_group.lab.name
  location             = azurerm_resource_group.lab.location
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = local.common_tags

  # This disk is the whole point of the persistent root. ADR 0002.
  lifecycle {
    prevent_destroy = true
  }
}

# ---- Network -----------------------------------------------------------------

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-cml-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = [var.vnet_cidr]
  tags                = local.common_tags
}

resource "azurerm_subnet" "cml" {
  name                 = "snet-cml"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.cml_subnet_cidr]
}

resource "azurerm_subnet" "apps" {
  name                 = "snet-apps"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.apps_subnet_cidr]
}

resource "azurerm_subnet" "fw_mgmt" {
  name                 = "snet-fw-mgmt"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.fw_mgmt_subnet_cidr]
}

resource "azurerm_subnet" "fw_inside" {
  name                 = "snet-fw-inside"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.fw_inside_subnet_cidr]
}

resource "azurerm_subnet" "fw_outside" {
  name                 = "snet-fw-outside"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [var.fw_outside_subnet_cidr]
}

# Azure's fabric, not the VM's routing table, decides where a packet from the
# apps subnet goes. Without this UDR the lab summary falls to the Internet
# route and is dropped. The CML NIC must also have IP forwarding on, which
# the fork sets. ADR 0003.
resource "azurerm_route_table" "apps" {
  name                          = "rt-apps"
  resource_group_name           = azurerm_resource_group.lab.name
  location                      = azurerm_resource_group.lab.location
  bgp_route_propagation_enabled = false
  tags                          = local.common_tags

  route {
    name                   = "lab-summary-via-cml"
    address_prefix         = var.lab_summary_cidr
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.cml_private_ip
  }
}

resource "azurerm_subnet_route_table_association" "apps" {
  subnet_id      = azurerm_subnet.apps.id
  route_table_id = azurerm_route_table.apps.id
}

# ---- Secrets: generated here, read back with terraform output ---------------

# 16 characters, no specials, matching cloud-cml's dummy secret manager so
# the YAML we render needs no escaping. ADR 0004.
resource "random_password" "app_admin" {
  length  = 16
  special = false
}

resource "random_password" "sys_admin" {
  length  = 16
  special = false
}
```

- [ ] **Step 8: Write `outputs.tf`**

```hcl
output "resource_group_name" {
  description = "Resource group that holds every persistent resource and the CML VM."
  value       = azurerm_resource_group.lab.name
}

output "location" {
  description = "Azure region."
  value       = azurerm_resource_group.lab.location
}

output "storage_account_name" {
  description = "Storage account holding the cml and exports containers."
  value       = azurerm_storage_account.lab.name
}

output "cml_container_name" {
  description = "Container with the CML package and refplat images."
  value       = azurerm_storage_container.cml.name
}

output "exports_container_name" {
  description = "Container with dated lab export folders."
  value       = azurerm_storage_container.exports.name
}

output "ssh_key_name" {
  description = "Azure SSH public key resource name, referenced by the fork as common.key_name."
  value       = azurerm_ssh_public_key.cml.name
}

output "public_ip_name" {
  description = "Static public IP resource name, referenced by the fork as azure.public_ip_name."
  value       = azurerm_public_ip.cml.name
}

output "public_ip_address" {
  description = "Static public IP address of the CML host. Stable across rebuilds."
  value       = azurerm_public_ip.cml.ip_address
}

output "data_disk_id" {
  description = "Resource ID of the persistent data disk, referenced by the fork as azure.data_disk_id."
  value       = azurerm_managed_disk.data.id
}

output "vnet_name" {
  description = "VNet name, referenced by the fork as azure.vnet_name."
  value       = azurerm_virtual_network.lab.name
}

output "cml_subnet_name" {
  description = "CML subnet name, referenced by the fork as azure.subnet_name."
  value       = azurerm_subnet.cml.name
}

output "cml_subnet_id" {
  description = "CML subnet resource ID."
  value       = azurerm_subnet.cml.id
}

output "apps_subnet_id" {
  description = "Apps subnet resource ID, for the ISE and FTD spec."
  value       = azurerm_subnet.apps.id
}

output "apps_subnet_cidr" {
  description = "Apps subnet prefix, referenced by the fork as azure.apps_subnet_cidr for the NSG rule."
  value       = var.apps_subnet_cidr
}

output "cml_private_ip" {
  description = "Static private IP for the CML NIC, referenced by the fork as azure.private_ip."
  value       = var.cml_private_ip
}

output "lab_summary_cidr" {
  description = "Lab summary prefix, referenced by the fork as azure.lab_summary_cidr."
  value       = var.lab_summary_cidr
}

output "app_admin_password" {
  description = "CML application admin password. Rendered into config/cml.yml."
  value       = random_password.app_admin.result
  sensitive   = true
}

output "sys_admin_password" {
  description = "CML sysadmin password. Rendered into config/cml.yml."
  value       = random_password.sys_admin.result
  sensitive   = true
}
```

- [ ] **Step 9: Write `terraform.tfvars.example`**

```hcl
owner   = "your-name"
expires = "2027-03-01"
# Everything else has a default matching the spec. Override only with intent.
# data_disk_size_gb = 512
```

- [ ] **Step 10: Validate without the backend**

Run:
```bash
mkdir -p keys && [[ -f keys/cml-lab.pub ]] || ssh-keygen -t rsa -b 4096 -N "" -C "cml-lab" -f keys/cml-lab
terraform -chdir=terraform/persistent init -backend=false
terraform -chdir=terraform/persistent fmt -check
terraform -chdir=terraform/persistent validate
```
Expected: `Success! The configuration is valid.` The key is generated only so `file()` resolves during validate. RSA, because `azurerm_ssh_public_key` and `admin_ssh_key` on Linux VMs accept RSA universally.

- [ ] **Step 11: Commit**

```bash
git add terraform/persistent/
git commit -m "infra: add persistent root for storage, network, disk, and IP"
```

`.terraform.lock.hcl` for this root is committed too.

---

### Task 5: Apply bootstrap, wire the persistent backend, plan persistent

This task changes Azure. It is cheap (a Standard_LRS storage account) and reversible only by hand, so a human runs the apply. Do not automate past the plan.

**Files:**
- Modify: `terraform/persistent/backend.tf` (replace the placeholder)

**Interfaces:**
- Consumes: bootstrap outputs.
- Produces: a working blob backend for the persistent root, and a persistent plan that `20-up.sh` will later apply.

- [ ] **Step 1: Human runs the bootstrap apply**

```bash
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
terraform -chdir=terraform/bootstrap apply
```
Expected: 5 added. Outputs printed.

- [ ] **Step 2: Copy the storage account name into `backend.tf`**

```bash
SA="$(terraform -chdir=terraform/bootstrap output -raw storage_account_name)"
sed -i '' "s/REPLACE_AFTER_BOOTSTRAP_APPLY/${SA}/" terraform/persistent/backend.tf
grep storage_account_name terraform/persistent/backend.tf
```
Expected: the real name, `st<6 chars>tfstate`.

- [ ] **Step 3: Init the persistent root against the backend**

Run: `terraform -chdir=terraform/persistent init -reconfigure`
Expected: `Successfully configured the backend "azurerm"!` If it fails with an authorization error, wait two minutes: the role assignment from Step 1 takes time to propagate.

- [ ] **Step 4: Plan the persistent root**

```bash
cp -n terraform/persistent/terraform.tfvars.example terraform/persistent/terraform.tfvars
# edit owner and expires in terraform/persistent/terraform.tfvars
terraform -chdir=terraform/persistent plan
```
Expected: 19 to add (resource group, random string, storage account, 2 containers, role assignment, SSH key, public IP, managed disk, VNet, 5 subnets, route table with its inline route, route table association, 2 passwords), 0 to change, 0 to destroy. Do not apply yet: the 512 GB Premium disk bills from creation. `20-up.sh` applies it when the images are ready.

- [ ] **Step 5: Commit**

```bash
git add terraform/persistent/backend.tf
git commit -m "infra: point persistent backend at the bootstrap state account"
```

---

### Task 6: Submodule wiring and fork patch 0

The fork already exists at `https://github.com/itsAmeMario0o/cloud-cml` with branch `azure-lab` at tag v2.9.0, commit `b32edd5`.

**Files:**
- Create: `.gitmodules` (via `git submodule add`)
- Create: `vendor/cloud-cml/` (submodule)
- Fork, modify: `modules/deploy/azure.tf`, `modules/deploy/aws.tf` (symlink targets), `modules/deploy/azure-on.t-f`

**Interfaces:**
- Consumes: nothing.
- Produces: a submodule whose `terraform -chdir=vendor/cloud-cml validate` passes with the Azure module enabled and azurerm pinned to 4.x.

- [ ] **Step 1: Add the submodule**

```bash
git submodule add -b azure-lab https://github.com/itsAmeMario0o/cloud-cml vendor/cloud-cml
git submodule status
```
Expected: `.gitmodules` created, status shows `b32edd5... vendor/cloud-cml (v2.9.0)`.

- [ ] **Step 2: Add the upstream remote inside the fork**

```bash
cd vendor/cloud-cml
git remote add upstream https://github.com/CiscoDevNet/cloud-cml
git fetch upstream --tags
cd ../..
```

- [ ] **Step 3: Confirm the gate fails first**

Run: `terraform -chdir=vendor/cloud-cml init -backend=false && terraform -chdir=vendor/cloud-cml validate`
Expected: validate passes but the Azure module is the dummy (`modules/deploy/azure.tf -> azure-off.t-f`). Confirm with `readlink vendor/cloud-cml/modules/deploy/azure.tf`, which prints `azure-off.t-f`.

- [ ] **Step 4: Fork patch 0, switch the symlinks**

```bash
cd vendor/cloud-cml/modules/deploy
rm azure.tf aws.tf
ln -s azure-on.t-f azure.tf
ln -s aws-off.t-f aws.tf
cd ../../../..
```

- [ ] **Step 5: Fork patch 0, pin azurerm in `modules/deploy/azure-on.t-f`**

Replace the `required_providers` block:

```hcl
terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # Pinned to 4.x by the azure-lab fork. azurerm 5.x is current on the
      # registry and upstream's open lower bound would select it. The patches
      # on this branch use 4.x argument names. ADR 0001.
      version = "~> 4.0"
    }
  }
  required_version = ">= 1.1.0"
}
```

- [ ] **Step 6: Validate with the Azure module live**

Run:
```bash
rm -rf vendor/cloud-cml/.terraform
terraform -chdir=vendor/cloud-cml init -backend=false
terraform -chdir=vendor/cloud-cml validate
```
Expected: `Success! The configuration is valid.` Init downloads azurerm 4.x (check the line `Installing hashicorp/azurerm v4.`).

- [ ] **Step 7: Commit in the fork and push**

```bash
cd vendor/cloud-cml
git add modules/deploy/azure.tf modules/deploy/aws.tf modules/deploy/azure-on.t-f
git commit -m "infra(azure): enable Azure target and pin azurerm to 4.x

Symlinks replace the interactive prepare.sh step because this repo is
consumed as a submodule. See ADR 0001 in cml-azure-lab."
git push origin azure-lab
cd ../..
```

- [ ] **Step 8: Commit the submodule pointer here**

```bash
git add .gitmodules vendor/cloud-cml
git commit -m "infra: add cloud-cml fork as submodule on branch azure-lab"
```

---

### Task 7: Fork patches 1 to 8 in the Azure module

All edits are in `vendor/cloud-cml/modules/deploy/azure/main.tf` unless noted. One commit per patch, in this order, each with `terraform validate` green before committing. Work on branch `azure-lab`. Every added block carries a comment starting `azure-lab fork:` and naming ADR 0001, so a future upstream merge shows why the line differs.

**Files:**
- Fork, modify: `modules/deploy/azure/main.tf`
- Fork, modify: `modules/deploy/azure/output.tf`

**Interfaces:**
- Consumes: the `azure:` config keys listed under "Interfaces shared across tasks".
- Produces: an Azure module that consumes the persistent root's network, IP, and disk instead of creating its own.

- [ ] **Step 1: Confirm the gate is green before touching anything**

Run: `terraform -chdir=vendor/cloud-cml validate`
Expected: `Success!`. Every patch below must keep it that way.

- [ ] **Step 2: Patch 1, VNet and subnet become data sources, NIC private IP static**

Delete the `azurerm_virtual_network` and `azurerm_subnet` resource blocks. In their place:

```hcl
# azure-lab fork: the VNet and subnet are owned by the persistent root in
# cml-azure-lab so they survive a rebuild. Upstream created them here with a
# hardcoded 10.0.0.0/16. ADR 0001.
data "azurerm_virtual_network" "cml" {
  name                = var.options.cfg.azure.vnet_name
  resource_group_name = data.azurerm_resource_group.cml.name
}

data "azurerm_subnet" "cml" {
  name                 = var.options.cfg.azure.subnet_name
  virtual_network_name = data.azurerm_virtual_network.cml.name
  resource_group_name  = data.azurerm_resource_group.cml.name
}
```

Change the NIC `ip_configuration` block to:

```hcl
  ip_configuration {
    name      = "internal"
    subnet_id = data.azurerm_subnet.cml.id
    # azure-lab fork: static, because the Azure route table for the lab
    # summary names this address as its next hop. ADR 0003.
    private_ip_address_allocation = "Static"
    private_ip_address            = var.options.cfg.azure.private_ip
    public_ip_address_id          = azurerm_public_ip.cml.id
  }
```

Validate, then commit in the fork:
```bash
terraform -chdir=vendor/cloud-cml validate
cd vendor/cloud-cml && git add -A && git commit -m "infra(azure): use existing VNet and subnet, static private IP" && cd ../..
```

- [ ] **Step 3: Patch 2, public IP becomes a data source**

Delete the `azurerm_public_ip` resource. Add:

```hcl
# azure-lab fork: the public IP is owned by the persistent root so the
# address, and the cml-mcp config that points at it, survive a rebuild.
# ADR 0003.
data "azurerm_public_ip" "cml" {
  name                = var.options.cfg.azure.public_ip_name
  resource_group_name = data.azurerm_resource_group.cml.name
}
```

In the NIC `ip_configuration`, change `public_ip_address_id = azurerm_public_ip.cml.id` to `public_ip_address_id = data.azurerm_public_ip.cml.id`.

In `modules/deploy/azure/output.tf`, change the `public_ip` output to:

```hcl
output "public_ip" {
  value = data.azurerm_public_ip.cml.ip_address
}
```

Validate, then commit: `infra(azure): use existing static public IP`.

- [ ] **Step 4: Patch 3, IP forwarding and accelerated networking on the NIC**

Inside `resource "azurerm_network_interface" "cml"`, above `ip_configuration`:

```hcl
  # azure-lab fork: the CML host forwards between the lab transit network and
  # the VNet. Azure drops forwarded packets unless this is on. Accelerated
  # networking is free on E-series sizes and helps the image copy. ADR 0003.
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = true
```

Validate, then commit: `infra(azure): enable IP forwarding and accelerated networking`.

- [ ] **Step 5: Patch 4, OS disk type from config**

In the VM's `os_disk` block, replace `storage_account_type = "Standard_LRS"` with:

```hcl
    # azure-lab fork: Standard_LRS is too slow for a 200 GB disk full of
    # qcow2 images. Premium needs an "s" size, which the spec mandates. ADR 0001.
    storage_account_type = try(var.options.cfg.azure.os_disk_type, "Premium_LRS")
```

Validate, then commit: `infra(azure): OS disk type from config, default Premium_LRS`.

- [ ] **Step 6: Patch 5, data disk attachment at LUN 0**

After the `azurerm_linux_virtual_machine` resource:

```hcl
# azure-lab fork: attach the persistent data disk. It is created and kept by
# the persistent root; this only attaches it. LUN 0 is what the provisioning
# hook 05-persist.sh waits for at /dev/disk/azure/scsi1/lun0. ADR 0002.
resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  count              = try(var.options.cfg.azure.data_disk_id, "") != "" ? 1 : 0
  managed_disk_id    = var.options.cfg.azure.data_disk_id
  virtual_machine_id = azurerm_linux_virtual_machine.cml.id
  lun                = 0
  caching            = "ReadOnly"
}
```

Validate, then commit: `infra(azure): attach persistent data disk at LUN 0`.

- [ ] **Step 7: Patch 6, SAS validity from config**

In `data "azurerm_storage_account_sas" "cml"`, replace `expiry = timeadd(timestamp(), "1h")` with:

```hcl
  # azure-lab fork: one hour is not enough for a large refplat selection over
  # a busy link. Default four hours, overridable per build. ADR 0001.
  expiry = timeadd(timestamp(), try(var.options.cfg.azure.sas_validity, "4h"))
```

Validate, then commit: `infra(azure): SAS validity from config, default 4h`.

- [ ] **Step 8: Patch 7, optional spot**

Inside `resource "azurerm_linux_virtual_machine" "cml"`, after `size = var.options.cfg.azure.size`:

```hcl
  # azure-lab fork: optional spot pricing. Deallocate on eviction so the OS
  # disk and the attached data disk survive; the next 20-up.sh rebuilds.
  # max_bid_price -1 means "up to the on-demand price". ADR 0001.
  priority        = try(var.options.cfg.azure.spot.enabled, false) ? "Spot" : "Regular"
  eviction_policy = try(var.options.cfg.azure.spot.enabled, false) ? "Deallocate" : null
  max_bid_price   = try(var.options.cfg.azure.spot.enabled, false) ? try(var.options.cfg.azure.spot.max_bid_price, -1) : null
```

Validate, then commit: `infra(azure): optional spot priority with deallocate eviction`.

- [ ] **Step 9: Patch 8, NSG rule for lab transit**

After `resource "azurerm_network_security_rule" "cml_patty_udp"`:

```hcl
# azure-lab fork: ISE and FTD in the apps subnet reach lab prefixes through
# this host. The NSG sits on the NIC and sees the forwarded packet's real
# destination, which is a lab address, hence the summary as destination.
# ADR 0003.
resource "azurerm_network_security_rule" "lab_transit" {
  count                       = try(var.options.cfg.azure.apps_subnet_cidr, "") != "" ? 1 : 0
  name                        = "lab-transit-in"
  priority                    = 400
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = var.options.cfg.azure.apps_subnet_cidr
  destination_address_prefix  = var.options.cfg.azure.lab_summary_cidr
  resource_group_name         = data.azurerm_resource_group.cml.name
  network_security_group_name = azurerm_network_security_group.cml.name
}
```

Validate, then commit: `infra(azure): NSG rule for apps subnet to lab summary`.

- [ ] **Step 10: Format check and push**

```bash
terraform -chdir=vendor/cloud-cml fmt -check -recursive
cd vendor/cloud-cml && git log --oneline v2.9.0..HEAD && git push origin azure-lab && cd ../..
```
Expected: 9 commits above v2.9.0 (patch 0 plus 1 to 8). fmt reports nothing.

- [ ] **Step 11: Bump the submodule pointer here**

```bash
git add vendor/cloud-cml
git commit -m "infra: bump cloud-cml fork to patches 1 through 8"
```

---

### Task 8: Fork patches 9 and 10, the persistence hook

**Files:**
- Fork, modify: `modules/deploy/data/cloud-config.txt`
- Fork, create: `modules/deploy/data/05-persist.sh`
- Create: `tests/test_persist.sh`

**Interfaces:**
- Consumes: the data disk at `/dev/disk/azure/scsi1/lun0` (Task 7 patch 5), `/provision/refplat` written by cloud-init (upstream).
- Produces: `/data` mounted, `/data/images` bind-mounted on `/var/lib/libvirt/images`, `/data/exports` present. Task 15 writes exports there; Task 18 checks all three.

- [ ] **Step 1: Write the failing test**

`tests/test_persist.sh`:
```bash
#!/usr/bin/env bash
# Dry-run tests for the fork's 05-persist.sh. The script runs on Ubuntu as
# root; here DRY_RUN=1 prints the commands it would run and the PRETEND_*
# variables stand in for disk and filesystem probes.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/vendor/cloud-cml/modules/deploy/data/05-persist.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
failures=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "[OK]    ${label}"
  else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1))
  fi
}
assert_not_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then
    echo "[FAIL]  ${label}: unexpected '${needle}'"; failures=$((failures + 1))
  else
    echo "[OK]    ${label}"
  fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

common_env="DRY_RUN=1 LOG_DIR=${TMP} DATA_MNT=${TMP}/data IMAGES_DIR=${TMP}/images REFPLAT_JSON=${TMP}/refplat FSTAB=${TMP}/fstab WAIT_SECS=1"
echo '{"definitions":["alpine"],"images":["alpine-base-3-21-3"]}' > "${TMP}/refplat"
touch "${TMP}/fstab"

# 1. First boot: blank disk, no images yet. Must format, mount, bind, and
#    leave the refplat image list alone so cml.sh copies the images.
out="$(env ${common_env} PRETEND_FS= PRETEND_IMAGE_FILES=0 bash "${SCRIPT}" pre 2>&1)"
assert_contains "first boot formats" "+ mkfs.ext4 -L cmldata" "${out}"
assert_contains "first boot partitions" "+ parted -s" "${out}"
assert_contains "first boot binds images" "+ mount --bind ${TMP}/data/images ${TMP}/images" "${out}"
assert_contains "first boot fstab data line" "LABEL=cmldata ${TMP}/data ext4" "${out}"
assert_contains "first boot fstab bind line" "${TMP}/data/images ${TMP}/images none bind" "${out}"
assert_not_contains "first boot keeps image list" "images = []" "${out}"

# 2. Rebuild: formatted disk with images. Must not format, must bind, and
#    must empty the image list so cml.sh skips the copy.
out="$(env ${common_env} PRETEND_FS=ext4 PRETEND_IMAGE_FILES=12 bash "${SCRIPT}" pre 2>&1)"
assert_not_contains "rebuild does not format" "mkfs.ext4" "${out}"
assert_contains "rebuild binds images" "+ mount --bind" "${out}"
assert_contains "rebuild skips image copy" "images = []" "${out}"
assert_contains "rebuild reports reuse" "reusing 12 image files" "${out}"

# 3. Post phase fails loudly when the bind mount is gone.
rc=0; env ${common_env} PRETEND_BOUND=0 bash "${SCRIPT}" post >/dev/null 2>&1 || rc=$?
assert_eq "post fails without bind mount" "1" "${rc}"

# 4. Post phase passes when bound.
out="$(env ${common_env} PRETEND_BOUND=1 PRETEND_IMAGE_FILES=12 bash "${SCRIPT}" post 2>&1)"; rc=$?
assert_contains "post confirms bind" "bind mount active" "${out}"

# 5. Unknown phase is an error.
rc=0; env ${common_env} bash "${SCRIPT}" bogus >/dev/null 2>&1 || rc=$?
assert_eq "unknown phase exits 2" "2" "${rc}"

# 6. The script is shellcheck clean (it is outside the pre-commit scope).
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity=warning "${SCRIPT}"; then echo "[OK]    shellcheck"; else
    echo "[FAIL]  shellcheck"; failures=$((failures + 1)); fi
fi

if [[ "${failures}" -gt 0 ]]; then echo "test_persist: ${failures} failure(s)"; exit 1; fi
echo "test_persist: all passed"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test_persist.sh`
Expected: `[FAIL]` lines, the script does not exist.

- [ ] **Step 3: Write `vendor/cloud-cml/modules/deploy/data/05-persist.sh`**

```bash
#!/bin/bash
#
# 05-persist.sh: keep refplat images and lab exports on the persistent data
# disk so a rebuilt CML host does not copy them again.
#
# Two phases:
#   pre   Run by cloud-init runcmd before cml.sh. Waits for the data disk,
#         formats it only when blank, mounts it at /data, bind-mounts
#         /data/images onto /var/lib/libvirt/images and, when images are
#         already there, empties the image list in /provision/refplat so
#         cml.sh copies only the small node definitions.
#   post  Run by cml.sh postprocess after CML is installed. Verifies the
#         bind mount survived the install, fixes ownership, logs a summary.
#
# A bind mount rather than a symlink because cml.sh decides whether to copy
# everything with `find $images -type f | wc -l`, and find does not follow a
# symlink given as its starting point.
#
# Exits nonzero on failure so it is visible in the log even though upstream
# postprocess swallows the code. Logs to /var/log/provision/05-persist-<phase>.log.
#
# DRY_RUN=1 prints commands instead of running them and replaces probes with
# PRETEND_* values. Used by tests on macOS. Stays bash 3.2 compatible.
#
# Part of the azure-lab fork. ADR 0001 and ADR 0002 in cml-azure-lab.
set -euo pipefail

PHASE="${1:-post}"
DATA_DEV="${DATA_DEV:-/dev/disk/azure/scsi1/lun0}"
DATA_MNT="${DATA_MNT:-/data}"
IMAGES_DIR="${IMAGES_DIR:-/var/lib/libvirt/images}"
REFPLAT_JSON="${REFPLAT_JSON:-/provision/refplat}"
FSTAB="${FSTAB:-/etc/fstab}"
LOG_DIR="${LOG_DIR:-/var/log/provision}"
WAIT_SECS="${WAIT_SECS:-600}"
DRY_RUN="${DRY_RUN:-0}"
PRETEND_FS="${PRETEND_FS:-}"
PRETEND_IMAGE_FILES="${PRETEND_IMAGE_FILES:-0}"
PRETEND_BOUND="${PRETEND_BOUND:-0}"

log() { echo "[05-persist:${PHASE}] $*"; }

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

append_line() {
  local file="$1" line="$2"
  if grep -qF -- "${line}" "${file}" 2>/dev/null; then
    return 0
  fi
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ append to ${file}: ${line}"
  else
    echo "${line}" >> "${file}"
  fi
}

wait_for_device() {
  local waited=0
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "dry run: assuming ${DATA_DEV} is present"
    return 0
  fi
  while [[ ! -e "${DATA_DEV}" ]]; do
    if [[ "${waited}" -ge "${WAIT_SECS}" ]]; then
      log "data disk ${DATA_DEV} did not appear in ${WAIT_SECS}s"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "data disk present after ${waited}s"
}

partition_fs_type() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${PRETEND_FS}"
  else
    blkid -s TYPE -o value "${DATA_DEV}-part1" 2>/dev/null || true
  fi
}

format_if_blank() {
  local fstype
  fstype="$(partition_fs_type)"
  if [[ -n "${fstype}" ]]; then
    log "partition already formatted as ${fstype}, keeping it"
    return 0
  fi
  log "blank disk, creating one ext4 partition"
  run parted -s "${DATA_DEV}" mklabel gpt mkpart primary ext4 0% 100%
  run udevadm settle
  run mkfs.ext4 -L cmldata "${DATA_DEV}-part1"
}

mount_data() {
  run mkdir -p "${DATA_MNT}"
  append_line "${FSTAB}" "LABEL=cmldata ${DATA_MNT} ext4 defaults,nofail,x-systemd.device-timeout=30 0 2"
  run mount "${DATA_MNT}"
  run mkdir -p "${DATA_MNT}/images" "${DATA_MNT}/exports"
}

image_file_count() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "${PRETEND_IMAGE_FILES}"
  else
    find "${DATA_MNT}/images" -type f 2>/dev/null | wc -l | tr -d ' '
  fi
}

is_bound() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    [[ "${PRETEND_BOUND}" == "1" ]]
  else
    [[ "$(findmnt -n -o TARGET --target "${IMAGES_DIR}" 2>/dev/null)" == "${IMAGES_DIR}" ]]
  fi
}

bind_images() {
  run mkdir -p "${IMAGES_DIR}"
  if is_bound; then
    log "bind mount already active"
  else
    run mount --bind "${DATA_MNT}/images" "${IMAGES_DIR}"
  fi
  append_line "${FSTAB}" "${DATA_MNT}/images ${IMAGES_DIR} none bind,x-systemd.requires=${DATA_MNT} 0 0"
}

skip_image_copy_if_present() {
  local count
  count="$(image_file_count)"
  if [[ "${count}" -eq 0 ]]; then
    log "no images on the data disk yet, cml.sh will copy them"
    return 0
  fi
  log "reusing ${count} image files from ${DATA_MNT}/images, emptying refplat image list"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ jq '.images = []' ${REFPLAT_JSON}"
  else
    jq '.images = []' "${REFPLAT_JSON}" > "${REFPLAT_JSON}.tmp"
    mv "${REFPLAT_JSON}.tmp" "${REFPLAT_JSON}"
  fi
}

phase_pre() {
  wait_for_device
  format_if_blank
  mount_data
  bind_images
  skip_image_copy_if_present
  log "pre phase done"
}

phase_post() {
  if ! is_bound; then
    log "FAIL: ${IMAGES_DIR} is not a bind mount of ${DATA_MNT}/images"
    return 1
  fi
  log "bind mount active"
  if [[ "${DRY_RUN}" != "1" ]] && getent passwd virl2 >/dev/null 2>&1; then
    run chown -R virl2:virl2 "${IMAGES_DIR}"
  fi
  log "$(image_file_count) image files on the data disk"
  log "post phase done"
}

main() {
  mkdir -p "${LOG_DIR}"
  exec > >(tee -a "${LOG_DIR}/05-persist-${PHASE}.log") 2>&1
  log "start $(date -u +%FT%TZ)"
  case "${PHASE}" in
    pre) phase_pre ;;
    post) phase_post ;;
    *) log "unknown phase '${PHASE}', expected pre or post"; exit 2 ;;
  esac
}

main "$@"
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/test_persist.sh`
Expected: every `[OK]`, then `test_persist: all passed`.

- [ ] **Step 5: Patch 9, run the pre phase from cloud-init**

In `vendor/cloud-cml/modules/deploy/data/cloud-config.txt`, replace the `runcmd:` block with:

```yaml
runcmd:
  # azure-lab fork: prepare the data disk before cml.sh copies images. The
  # file only exists when 05-persist.sh is listed under app.customize, so
  # upstream configs are unaffected. Failures surface in the post phase and
  # in /var/log/provision/05-persist-pre.log. ADR 0002 in cml-azure-lab.
  - [ sh, -c, "test -f /provision/05-persist.sh && bash /provision/05-persist.sh pre || true" ]
  - /provision/cml.sh && touch /run/reboot || echo "CML provisioning failed.  Not rebooting"
```

Keep everything else in the file byte for byte. Note the file is a Terraform template: `${...}` and `%{...}` are interpolation, so the added lines must not contain either.

- [ ] **Step 6: Validate the fork and run the full local gate**

```bash
terraform -chdir=vendor/cloud-cml validate
tests/run.sh
```
Expected: validate `Success!`, `tests/run.sh: all passed`.

- [ ] **Step 7: Commit in the fork, two commits, and push**

```bash
cd vendor/cloud-cml
git add modules/deploy/data/cloud-config.txt
git commit -m "infra(azure): run 05-persist.sh pre phase from cloud-init"
git add modules/deploy/data/05-persist.sh
git commit -m "infra(azure): add 05-persist.sh data disk and image persistence hook"
git push origin azure-lab
cd ../..
```

- [ ] **Step 8: Bump the submodule pointer and commit the test**

```bash
git add vendor/cloud-cml tests/test_persist.sh
git commit -m "infra: bump cloud-cml fork to the persistence hook, add its tests"
```

---

### Task 9: Config files, the tfvars parser, the config renderer, and the MCP wiring

**Files:**
- Create: `config/refplat.txt`
- Create: `config/cml.tfvars.example`
- Create: `config/cml.yml.tftpl`
- Create: `config/mcp-env/.gitignore`
- Create: `scripts/lib/tfvars.py`
- Create: `scripts/lib/render_cml_config.py`
- Create: `scripts/mcp-cml.sh`
- Create: `.mcp.json`
- Create: `tests/test_tfvars.py`, `tests/test_render.py`

**Interfaces:**
- Consumes: persistent outputs by name (passed in as `--set`), `config/cml.tfvars`, `config/refplat.txt`.
- Produces: `config/cml.yml` for the fork (`TF_VAR_cfg_file`), and `scripts/mcp-cml.sh` for `.mcp.json` and Task 11. `python3 scripts/lib/render_cml_config.py --template T --tfvars V --refplat R --out O --set K=V...` exits 0 on success, 1 with a message naming every missing placeholder or bad value.

- [ ] **Step 1: Write the failing tests**

`tests/test_tfvars.py`:
```python
"""Tests for scripts/lib/tfvars.py, the HCL-subset parser."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts" / "lib"))
import tfvars  # noqa: E402


class ParseTfvarsTest(unittest.TestCase):
    def test_parses_every_supported_type(self) -> None:
        text = """
        # comment line
        name = "cml"   # trailing comment
        count = 12
        price = -1
        flag = true
        other = false
        cidrs = ["10.0.0.1/32", "10.0.0.2/32"]
        empty = []
        """
        result = tfvars.parse_tfvars(text)
        self.assertEqual(result["name"], "cml")
        self.assertEqual(result["count"], 12)
        self.assertEqual(result["price"], -1)
        self.assertIs(result["flag"], True)
        self.assertIs(result["other"], False)
        self.assertEqual(result["cidrs"], ["10.0.0.1/32", "10.0.0.2/32"])
        self.assertEqual(result["empty"], [])

    def test_rejects_unknown_syntax_with_line_number(self) -> None:
        with self.assertRaises(ValueError) as ctx:
            tfvars.parse_tfvars('a = "ok"\nb = { nested = 1 }\n')
        self.assertIn("line 2", str(ctx.exception))

    def test_string_may_contain_hash(self) -> None:
        result = tfvars.parse_tfvars('token = "abc#def"\n')
        self.assertEqual(result["token"], "abc#def")


if __name__ == "__main__":
    unittest.main()
```

`tests/test_render.py`:
```python
"""Tests for scripts/lib/render_cml_config.py."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RENDER = REPO / "scripts" / "lib" / "render_cml_config.py"
TEMPLATE = REPO / "config" / "cml.yml.tftpl"

SETS = {
    "RESOURCE_GROUP": "rg-cml-lab", "STORAGE_ACCOUNT": "stcmllababc123",
    "CONTAINER_NAME": "cml", "VNET_NAME": "vnet-cml-lab", "SUBNET_NAME": "snet-cml",
    "PRIVATE_IP": "10.20.1.10", "PUBLIC_IP_NAME": "pip-cml-lab",
    "DATA_DISK_ID": "/subscriptions/x/resourceGroups/rg-cml-lab/providers/Microsoft.Compute/disks/disk-cml-lab-data",
    "OS_DISK_TYPE": "Premium_LRS", "APPS_SUBNET_CIDR": "10.20.2.0/24",
    "LAB_SUMMARY_CIDR": "10.100.0.0/16", "SSH_KEY_NAME": "sshkey-cml-lab",
    "APP_PASSWORD": "AppPass1234567890", "SYS_PASSWORD": "SysPass1234567890",
}

TFVARS = '''
smartlicense_token = "TOKENVALUE"
license_flavor = "CML_Personal"
allowed_ipv4_subnets_mgmt = ["203.0.113.10/32"]
allowed_ipv4_subnets_cml2 = ["203.0.113.10/32", "203.0.113.11/32"]
vm_size = "Standard_E16ds_v5"
os_disk_size_gb = 200
spot_enabled = false
spot_max_bid_price = -1
sas_validity = "4h"
software_package = "cml2_2.9.0-3_amd64-3.pkg"
'''

REFPLAT = "# def image\nalpine alpine-base-3-21-3\niosv iosv-159-3-m10\n"


class RenderTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp_root = REPO / "tests"
        self.tmp = Path(tempfile.mkdtemp(prefix=".tmp.", dir=tmp_root))
        (self.tmp / "cml.tfvars").write_text(TFVARS)
        (self.tmp / "refplat.txt").write_text(REFPLAT)

    def tearDown(self) -> None:
        for p in self.tmp.iterdir():
            p.unlink()
        self.tmp.rmdir()

    def run_render(self, tfvars_text: str | None = None, sets: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        if tfvars_text is not None:
            (self.tmp / "cml.tfvars").write_text(tfvars_text)
        cmd = [sys.executable, str(RENDER), "--template", str(TEMPLATE),
               "--tfvars", str(self.tmp / "cml.tfvars"), "--refplat", str(self.tmp / "refplat.txt"),
               "--out", str(self.tmp / "cml.yml")]
        for k, v in (sets if sets is not None else SETS).items():
            cmd += ["--set", f"{k}={v}"]
        return subprocess.run(cmd, capture_output=True, text=True)

    def test_renders_complete_yaml(self) -> None:
        proc = self.run_render()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        out = (self.tmp / "cml.yml").read_text()
        self.assertNotIn("${", out)
        self.assertIn("target: azure", out)
        self.assertIn("size: Standard_E16ds_v5", out)
        self.assertIn('allowed_ipv4_subnets_cml2: ["203.0.113.10/32", "203.0.113.11/32"]', out)
        self.assertIn("    - alpine-base-3-21-3", out)
        self.assertIn("    - iosv\n", out)
        self.assertIn("raw_secret: TOKENVALUE", out)
        self.assertIn("software: cml2_2.9.0-3_amd64-3.pkg", out)
        self.assertIn("enabled: false", out)
        mode = oct(os.stat(self.tmp / "cml.yml").st_mode & 0o777)
        self.assertEqual(mode, "0o600")

    def test_refuses_open_cidr(self) -> None:
        proc = self.run_render(TFVARS.replace('"203.0.113.10/32"]', '"0.0.0.0/0"]', 1))
        self.assertEqual(proc.returncode, 1)
        self.assertIn("0.0.0.0/0", proc.stderr)

    def test_reports_missing_placeholders(self) -> None:
        sets = dict(SETS)
        del sets["DATA_DISK_ID"]
        proc = self.run_render(sets=sets)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("DATA_DISK_ID", proc.stderr)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run them to verify they fail**

Run: `python3 -m unittest discover -s tests -p 'test_*.py'`
Expected: import errors and failures, the modules and template do not exist.

- [ ] **Step 3: Write `config/refplat.txt`**

```text
# Reference platform selection. One "definition image" pair per line.
# Single source for scripts/10-upload-images.sh, the preflight presence
# check, and the refplat block rendered into config/cml.yml.
#
# Names must match the folders on the refplat ISO exactly. These are from
# the June 2025 ISO; update them from the newer ISO before the first upload.
# Keep the first build small. Add Nexus, Cat9k, and IOS XR per scenario.
alpine alpine-base-3-21-3
ubuntu ubuntu-24-04-20250503
iosv iosv-159-3-m10
iosvl2 iosvl2-2020
cat8000v cat8000v-17-16-01a
```

- [ ] **Step 4: Write `config/cml.tfvars.example`**

```hcl
# Copy to config/cml.tfvars (gitignored) and fill in. Parsed by
# scripts/lib/tfvars.py: only "string", numbers, true/false, and ["lists"]
# of strings are supported. One key per line.

# From Smart Software Manager. See docs/PREREQUISITES.md section 1.2.
smartlicense_token = "PASTE-TOKEN-HERE"

# CML_Personal, CML_Personal40, CML_Education, or CML_Enterprise.
license_flavor = "CML_Personal"

# Your public IP as /32. `curl -4 ifconfig.me`. Never 0.0.0.0/0.
allowed_ipv4_subnets_mgmt = ["203.0.113.10/32"]
allowed_ipv4_subnets_cml2 = ["203.0.113.10/32"]

# Needs Edsv5 quota in eastus2. See docs/PREREQUISITES.md section 2.1.
vm_size = "Standard_E16ds_v5"

# OS disk holds CML itself and node overlay disks. Images are on /data.
os_disk_size_gb = 200

# Spot: false for the first build. -1 bids up to the on-demand price.
spot_enabled = false
spot_max_bid_price = -1

# How long the image copy SAS stays valid. Preflight warns if too short.
sas_validity = "4h"

# Exact filename of the package in software/ and in the cml container.
software_package = "cml2_2.9.0-3_amd64-3.pkg"
```

- [ ] **Step 5: Write `config/cml.yml.tftpl`**

Every `${NAME}` is a placeholder for `render_cml_config.py`. The `aws:` and `cluster:` blocks stay because upstream's `vars.sh` and templates read them even for the Azure target.

```yaml
# Rendered by scripts/20-up.sh from this template. Do not edit config/cml.yml.
# Schema is upstream cloud-cml v2.9.0 config.yml. Keys under azure: that
# upstream does not know are read by the azure-lab fork, ADR 0001.
target: azure

aws:
  region: unused
  availability_zone: unused
  bucket: unused
  flavor: unused
  flavor_compute: unused
  profile: unused
  subnet_id: ""
  sg_id: ""
  public_vpc_ipv4_cidr: 10.0.0.0/16
  enable_ebs_encryption: false
  vpc_id: ""
  gw_id: ""
  spot_instances:
    use_spot_for_controller: false
    use_spot_for_computes: false

azure:
  resource_group: ${RESOURCE_GROUP}
  size: ${VM_SIZE}
  size_compute: unused_at_the_moment
  storage_account: ${STORAGE_ACCOUNT}
  container_name: ${CONTAINER_NAME}
  # azure-lab fork keys
  vnet_name: ${VNET_NAME}
  subnet_name: ${SUBNET_NAME}
  private_ip: ${PRIVATE_IP}
  public_ip_name: ${PUBLIC_IP_NAME}
  data_disk_id: ${DATA_DISK_ID}
  os_disk_type: ${OS_DISK_TYPE}
  sas_validity: ${SAS_VALIDITY}
  spot:
    enabled: ${SPOT_ENABLED}
    max_bid_price: ${SPOT_MAX_BID_PRICE}
  apps_subnet_cidr: ${APPS_SUBNET_CIDR}
  lab_summary_cidr: ${LAB_SUMMARY_CIDR}

common:
  disk_size: ${OS_DISK_SIZE_GB}
  controller_hostname: cml-controller
  key_name: ${SSH_KEY_NAME}
  allowed_ipv4_subnets_mgmt: ${ALLOWED_MGMT}
  allowed_ipv4_subnets_cml2: ${ALLOWED_CML2}
  enable_patty: false

cluster:
  enable_cluster: false
  allow_vms_on_controller: true
  number_of_compute_nodes: 0
  compute_hostname_prefix: cml-compute
  compute_disk_size: 32

secret:
  manager: dummy
  conjur:
  vault:
    kv_secret_v2_mount: secret
    skip_child_token: true
  secrets:
    app:
      username: admin
      raw_secret: ${APP_PASSWORD}
    sys:
      username: sysadmin
      raw_secret: ${SYS_PASSWORD}
    smartlicense_token:
      raw_secret: ${LICENSE_TOKEN}
    cluster:

app:
  software: ${SOFTWARE_PACKAGE}
  customize:
    - 05-persist.sh
    - 99-dummy.sh

license:
  flavor: ${LICENSE_FLAVOR}
  nodes: 0

refplat:
  definitions:
${REFPLAT_DEFINITIONS}
  images:
${REFPLAT_IMAGES}
```

- [ ] **Step 6: Write `scripts/lib/tfvars.py`**

```python
#!/usr/bin/env python3
"""Parse the HCL subset used by config/cml.tfvars.

Supported, one assignment per line:
    key = "string"
    key = 123        (also negative)
    key = true | false
    key = ["a", "b"] (strings only, may be empty)
    # comments, whole line or after a value

Anything else raises ValueError naming the line. Stdlib only.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Any

_ASSIGN = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")
_STRING = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$')
_NUMBER = re.compile(r"^(-?\d+)\s*(?:#.*)?$")
_BOOL = re.compile(r"^(true|false)\s*(?:#.*)?$")
_LIST = re.compile(r"^\[(.*)\]\s*(?:#.*)?$")
_LIST_ITEM = re.compile(r'"((?:[^"\\]|\\.)*)"')


def _parse_value(raw: str, lineno: int) -> Any:
    if m := _STRING.match(raw):
        return m.group(1)
    if m := _NUMBER.match(raw):
        return int(m.group(1))
    if m := _BOOL.match(raw):
        return m.group(1) == "true"
    if m := _LIST.match(raw):
        body = m.group(1).strip()
        if not body:
            return []
        items = _LIST_ITEM.findall(body)
        leftover = _LIST_ITEM.sub("", body).replace(",", "").strip()
        if leftover:
            raise ValueError(f"line {lineno}: lists may hold only quoted strings")
        return items
    raise ValueError(f"line {lineno}: unsupported value syntax: {raw!r}")


def parse_tfvars(text: str) -> dict[str, Any]:
    """Return a dict of the assignments in *text*."""
    result: dict[str, Any] = {}
    for lineno, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        m = _ASSIGN.match(line)
        if not m:
            raise ValueError(f"line {lineno}: expected 'key = value'")
        result[m.group(1)] = _parse_value(m.group(2), lineno)
    return result


def load(path: Path) -> dict[str, Any]:
    """Parse the file at *path*."""
    return parse_tfvars(path.read_text())
```

- [ ] **Step 7: Write `scripts/lib/render_cml_config.py`**

```python
#!/usr/bin/env python3
"""Render config/cml.yml from the template, cml.tfvars, refplat.txt, and
values passed as --set NAME=VALUE (the persistent Terraform outputs).

Exit 0 on success. Exit 1 with a message on stderr naming every missing
placeholder, an open CIDR, or a malformed input. Never touches Terraform so
the fork stays unaware of this repo. ADR 0004 for why secrets pass this way.
"""
from __future__ import annotations

import argparse
import os
import string
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tfvars  # noqa: E402

REQUIRED_TFVARS = [
    "smartlicense_token", "license_flavor", "allowed_ipv4_subnets_mgmt",
    "allowed_ipv4_subnets_cml2", "vm_size", "os_disk_size_gb", "spot_enabled",
    "spot_max_bid_price", "sas_validity", "software_package",
]


def yaml_flow_list(items: list[str]) -> str:
    return "[" + ", ".join(f'"{item}"' for item in items) + "]"


def yaml_block_list(items: list[str], indent: int = 4) -> str:
    return "\n".join(f"{' ' * indent}- {item}" for item in items)


def read_refplat(path: Path) -> tuple[list[str], list[str]]:
    definitions: list[str] = []
    images: list[str] = []
    for lineno, line in enumerate(path.read_text().splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.split()
        if len(parts) != 2:
            raise ValueError(f"{path}: line {lineno}: expected 'definition image'")
        if parts[0] not in definitions:
            definitions.append(parts[0])
        images.append(parts[1])
    if not images:
        raise ValueError(f"{path}: no images listed")
    return definitions, images


def check_cidrs(values: dict[str, Any]) -> None:
    for key in ("allowed_ipv4_subnets_mgmt", "allowed_ipv4_subnets_cml2"):
        cidrs = values[key]
        if not isinstance(cidrs, list) or not cidrs:
            raise ValueError(f"{key} must be a non-empty list")
        if "0.0.0.0/0" in cidrs:
            raise ValueError(f"{key} contains 0.0.0.0/0, which is never allowed")


def build_mapping(values: dict[str, Any], refplat: tuple[list[str], list[str]], sets: dict[str, str]) -> dict[str, str]:
    definitions, images = refplat
    mapping = dict(sets)
    mapping.update({
        "LICENSE_TOKEN": str(values["smartlicense_token"]),
        "LICENSE_FLAVOR": str(values["license_flavor"]),
        "ALLOWED_MGMT": yaml_flow_list(values["allowed_ipv4_subnets_mgmt"]),
        "ALLOWED_CML2": yaml_flow_list(values["allowed_ipv4_subnets_cml2"]),
        "VM_SIZE": str(values["vm_size"]),
        "OS_DISK_SIZE_GB": str(values["os_disk_size_gb"]),
        "SPOT_ENABLED": "true" if values["spot_enabled"] else "false",
        "SPOT_MAX_BID_PRICE": str(values["spot_max_bid_price"]),
        "SAS_VALIDITY": str(values["sas_validity"]),
        "SOFTWARE_PACKAGE": str(values["software_package"]),
        "REFPLAT_DEFINITIONS": yaml_block_list(definitions),
        "REFPLAT_IMAGES": yaml_block_list(images),
    })
    return mapping


def render(template_text: str, mapping: dict[str, str]) -> str:
    template = string.Template(template_text)
    needed = {m.group("named") or m.group("braced") for m in template.pattern.finditer(template_text)}
    needed.discard(None)
    missing = sorted(name for name in needed if name not in mapping)
    if missing:
        raise KeyError("missing placeholders: " + ", ".join(missing))
    return template.substitute(mapping)


def parse_sets(pairs: list[str]) -> dict[str, str]:
    sets: dict[str, str] = {}
    for pair in pairs:
        if "=" not in pair:
            raise ValueError(f"--set expects NAME=VALUE, got {pair!r}")
        name, value = pair.split("=", 1)
        sets[name.strip()] = value
    return sets


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--tfvars", required=True, type=Path)
    parser.add_argument("--refplat", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--set", action="append", default=[], metavar="NAME=VALUE")
    args = parser.parse_args(argv)
    try:
        values = tfvars.load(args.tfvars)
        missing = [k for k in REQUIRED_TFVARS if k not in values]
        if missing:
            raise ValueError(f"{args.tfvars}: missing keys: {', '.join(missing)}")
        check_cidrs(values)
        mapping = build_mapping(values, read_refplat(args.refplat), parse_sets(args.set))
        rendered = render(args.template.read_text(), mapping)
    except (ValueError, KeyError, OSError) as exc:
        print(f"render_cml_config: {exc}", file=sys.stderr)
        return 1
    args.out.write_text(rendered)
    os.chmod(args.out, 0o600)
    print(f"rendered {args.out} ({len(mapping)} values)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `python3 -m unittest discover -s tests -p 'test_*.py' -v`
Expected: all tests in `test_tfvars` and `test_render` pass.

- [ ] **Step 9: Write the MCP wiring**

`config/mcp-env/.gitignore`:
```gitignore
# CML credentials written by scripts/20-up.sh. Everything but this file is ignored.
*
!.gitignore
```

`scripts/mcp-cml.sh`:
```bash
#!/usr/bin/env bash
# Launch cml-mcp for Claude Code with credentials from config/mcp-env/cml.env.
# Referenced by .mcp.json. Claude Code cannot source a file itself, hence
# this wrapper. The env file is written by scripts/20-up.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${CML_MCP_ENV:-${REPO_ROOT}/config/mcp-env/cml.env}"

main() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "mcp-cml: ${ENV_FILE} missing. Run scripts/20-up.sh first." >&2
    exit 1
  fi
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
  exec uvx cml-mcp "$@"
}

main "$@"
```

`.mcp.json`:
```json
{
  "mcpServers": {
    "cml": {
      "type": "stdio",
      "command": "bash",
      "args": ["scripts/mcp-cml.sh"]
    }
  }
}
```

- [ ] **Step 10: Run the full gate and commit**

```bash
chmod +x scripts/mcp-cml.sh scripts/lib/render_cml_config.py
tests/run.sh && pre-commit run --all-files
git add config/refplat.txt config/cml.tfvars.example config/cml.yml.tftpl config/mcp-env/.gitignore scripts/lib/tfvars.py scripts/lib/render_cml_config.py scripts/mcp-cml.sh .mcp.json tests/test_tfvars.py tests/test_render.py
git commit -m "feat: add config template, tfvars parser, renderer, and cml-mcp wiring"
```

---

### Task 10: Remote CML API helper, run on the host over SSH

**Files:**
- Create: `scripts/lib/cml-remote.sh`
- Create: `tests/fake_cml_api.py`
- Create: `tests/test_cml_remote.sh`

**Interfaces:**
- Consumes: `/provision/vars.sh` on the host (upstream writes `CFG_APP_USER` and `CFG_APP_PASS` there, readable by sysadmin), the local API at `http://ip6-localhost:8001/api/v0`.
- Produces: subcommands `list-labs`, `export-labs DIR`, `stop-labs`, `license-status`, `deregister`. Invoked from the Mac as `cml_ssh "bash -s -- SUBCOMMAND ARGS" < scripts/lib/cml-remote.sh`. Output formats below are what Tasks 15, 16, and 18 parse.

Output contract:
- `list-labs`: one line per lab, tab separated `id<TAB>title<TAB>state`. Empty output when no labs.
- `export-labs DIR`: creates `DIR`, writes `<title-slug>-<id>.yaml` per lab, prints `exported N labs to DIR`.
- `stop-labs`: stops every lab not already `STOPPED`, prints `stopped N labs`.
- `license-status`: prints `REGISTERED` or `NOT_REGISTERED` (the value of `registration.status`).
- `deregister`: calls `DELETE /licensing/deregistration`, then prints the new `license-status`. Exit 1 if it is still `REGISTERED`.

- [ ] **Step 1: Write the fake API used by the test**

`tests/fake_cml_api.py`:
```python
#!/usr/bin/env python3
"""Minimal stand-in for the CML controller API, for tests of cml-remote.sh.

Serves on 127.0.0.1 at the port given as argv[1]. State lives in memory:
two labs, one started, one stopped, and a registered license.
"""
from __future__ import annotations

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STATE: dict = {
    "labs": {
        "lab-1": {"lab_title": "Spine Leaf", "state": "STARTED"},
        "lab-2": {"lab_title": "TrustSec Demo", "state": "STOPPED"},
    },
    "registration": "REGISTERED",
}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: object, content_type: str = "application/json") -> None:
        data = body.encode() if isinstance(body, str) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _authorized(self) -> bool:
        return self.headers.get("Authorization") == "Bearer FAKE-TOKEN"

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/api/v0/authenticate":
            length = int(self.headers.get("Content-Length", "0"))
            creds = json.loads(self.rfile.read(length))
            if creds == {"username": "admin", "password": "secret"}:
                self._send(200, "FAKE-TOKEN")
            else:
                self._send(403, {"description": "bad credentials"})
            return
        self._send(404, {})

    def do_GET(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {})
            return
        if self.path == "/api/v0/labs":
            self._send(200, list(STATE["labs"]))
        elif self.path == "/api/v0/licensing":
            self._send(200, {"registration": {"status": STATE["registration"]}})
        elif self.path.startswith("/api/v0/labs/") and self.path.endswith("/download"):
            lab_id = self.path.split("/")[4]
            self._send(200, f"lab:\n  title: {STATE['labs'][lab_id]['lab_title']}\n", "text/plain")
        elif self.path.startswith("/api/v0/labs/"):
            lab_id = self.path.split("/")[4]
            self._send(200, {"id": lab_id, **STATE["labs"][lab_id]})
        else:
            self._send(404, {})

    def do_PUT(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {})
            return
        if self.path.startswith("/api/v0/labs/") and self.path.endswith("/stop"):
            STATE["labs"][self.path.split("/")[4]]["state"] = "STOPPED"
            self._send(204, "")
        else:
            self._send(404, {})

    def do_DELETE(self) -> None:  # noqa: N802
        if not self._authorized():
            self._send(401, {})
            return
        if self.path == "/api/v0/licensing/deregistration":
            STATE["registration"] = "NOT_REGISTERED"
            self._send(202, {})
        else:
            self._send(404, {})

    def log_message(self, *_: object) -> None:
        pass


def main() -> None:
    port = int(sys.argv[1])
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write the failing test**

`tests/test_cml_remote.sh`:
```bash
#!/usr/bin/env bash
# Runs scripts/lib/cml-remote.sh against tests/fake_cml_api.py.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/lib/cml-remote.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
PORT=18001
failures=0

python3 "${REPO_ROOT}/tests/fake_cml_api.py" "${PORT}" &
API_PID=$!
trap 'kill "${API_PID}" 2>/dev/null || true; rm -rf "${TMP}"' EXIT
sleep 1

printf 'CFG_APP_USER="admin"\nCFG_APP_PASS="secret"\n' > "${TMP}/vars.sh"
export CML_API="http://127.0.0.1:${PORT}/api/v0" VARS_FILE="${TMP}/vars.sh"

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

out="$(bash "${SCRIPT}" list-labs)"
assert_eq "list-labs two lines" "2" "$(echo "${out}" | wc -l | tr -d ' ')"
assert_eq "list-labs first row" "$(printf 'lab-1\tSpine Leaf\tSTARTED')" "$(echo "${out}" | head -1)"

out="$(bash "${SCRIPT}" export-labs "${TMP}/exports")"
assert_eq "export message" "exported 2 labs to ${TMP}/exports" "${out}"
assert_eq "export file exists" "yes" "$([[ -f "${TMP}/exports/spine-leaf-lab-1.yaml" ]] && echo yes || echo no)"
assert_eq "export file content" "lab:" "$(head -1 "${TMP}/exports/spine-leaf-lab-1.yaml")"

out="$(bash "${SCRIPT}" stop-labs)"
assert_eq "stop-labs stops the started one" "stopped 1 labs" "${out}"
assert_eq "second stop is a no-op" "stopped 0 labs" "$(bash "${SCRIPT}" stop-labs)"

assert_eq "license-status registered" "REGISTERED" "$(bash "${SCRIPT}" license-status)"
assert_eq "deregister" "NOT_REGISTERED" "$(bash "${SCRIPT}" deregister)"
assert_eq "license-status after" "NOT_REGISTERED" "$(bash "${SCRIPT}" license-status)"

rc=0; bash "${SCRIPT}" bogus >/dev/null 2>&1 || rc=$?
assert_eq "unknown subcommand exits 2" "2" "${rc}"

if [[ "${failures}" -gt 0 ]]; then echo "test_cml_remote: ${failures} failure(s)"; exit 1; fi
echo "test_cml_remote: all passed"
```

- [ ] **Step 3: Run it to verify it fails**

Run: `bash tests/test_cml_remote.sh`
Expected: `[FAIL]` lines, script missing.

- [ ] **Step 4: Write `scripts/lib/cml-remote.sh`**

```bash
#!/usr/bin/env bash
# Runs ON THE CML HOST, piped over SSH from the Mac:
#   cml_ssh "bash -s -- list-labs" < scripts/lib/cml-remote.sh
#
# Talks to the controller's local API with the admin credentials that
# cloud-cml leaves in /provision/vars.sh (group-readable by sysadmin).
#
# Subcommands and output contract (parsed by 30-export, 40-down, 90-smoke):
#   list-labs          id<TAB>title<TAB>state per line
#   export-labs DIR    writes <slug>-<id>.yaml, prints "exported N labs to DIR"
#   stop-labs          stops labs not STOPPED, prints "stopped N labs"
#   license-status     prints registration.status
#   deregister         deregisters, prints new status, exit 1 if still REGISTERED
#
# Overrides for tests: CML_API, VARS_FILE. Needs curl and jq, both present on
# a cloud-cml host. Stays bash 3.2 compatible so tests run on the Mac.
set -euo pipefail

CML_API="${CML_API:-http://ip6-localhost:8001/api/v0}"
VARS_FILE="${VARS_FILE:-/provision/vars.sh}"
TOKEN=""

load_credentials() {
  if [[ ! -r "${VARS_FILE}" ]]; then
    echo "cml-remote: cannot read ${VARS_FILE}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${VARS_FILE}"
  : "${CFG_APP_USER:?missing in ${VARS_FILE}}" "${CFG_APP_PASS:?missing in ${VARS_FILE}}"
}

authenticate() {
  TOKEN="$(printf '{"username":"%s","password":"%s"}' "${CFG_APP_USER}" "${CFG_APP_PASS}" |
    curl -sf -H "Content-Type: application/json" -d @- "${CML_API}/authenticate" | jq -r .)"
  if [[ -z "${TOKEN}" || "${TOKEN}" == "null" ]]; then
    echo "cml-remote: authentication failed" >&2
    exit 1
  fi
}

api() {
  local method="$1" path="$2"
  curl -sf -X "${method}" -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/json" "${CML_API}${path}"
}

lab_ids() {
  api GET /labs | jq -r '.[]'
}

lab_row() {
  local id="$1"
  api GET "/labs/${id}" | jq -r '[.id, .lab_title, .state] | @tsv'
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]+/-/g' -e 's/[^a-z0-9]/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

cmd_list_labs() {
  local id
  for id in $(lab_ids); do
    lab_row "${id}"
  done
}

cmd_export_labs() {
  local dir="$1" id title count=0
  mkdir -p "${dir}"
  for id in $(lab_ids); do
    title="$(api GET "/labs/${id}" | jq -r .lab_title)"
    api GET "/labs/${id}/download" > "${dir}/$(slugify "${title}")-${id}.yaml"
    count=$((count + 1))
  done
  echo "exported ${count} labs to ${dir}"
}

cmd_stop_labs() {
  local id state count=0
  for id in $(lab_ids); do
    state="$(api GET "/labs/${id}" | jq -r .state)"
    if [[ "${state}" != "STOPPED" ]]; then
      api PUT "/labs/${id}/stop" > /dev/null
      count=$((count + 1))
    fi
  done
  echo "stopped ${count} labs"
}

cmd_license_status() {
  api GET /licensing | jq -r '.registration.status'
}

cmd_deregister() {
  local status
  api DELETE /licensing/deregistration > /dev/null || true
  status="$(cmd_license_status)"
  echo "${status}"
  [[ "${status}" != "REGISTERED" ]]
}

main() {
  local sub="${1:-}"
  shift || true
  load_credentials
  authenticate
  case "${sub}" in
    list-labs) cmd_list_labs ;;
    export-labs) cmd_export_labs "${1:?export-labs needs a directory}" ;;
    stop-labs) cmd_stop_labs ;;
    license-status) cmd_license_status ;;
    deregister) cmd_deregister ;;
    *) echo "usage: cml-remote.sh list-labs|export-labs DIR|stop-labs|license-status|deregister" >&2; exit 2 ;;
  esac
}

main "$@"
```

Note on `slugify`: BSD sed on macOS has no `+` in basic regex, which is why the second expression repeats the class and the third collapses runs. It gives `spine-leaf` for `Spine Leaf` on both platforms.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/test_cml_remote.sh`
Expected: all `[OK]`, `test_cml_remote: all passed`. Then `tests/run.sh` all passed.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/cml-remote.sh tests/fake_cml_api.py tests/test_cml_remote.sh
git commit -m "feat: add remote CML API helper with fake API tests"
```

---

### Task 11: MCP stdio client for the smoke test

**Files:**
- Create: `scripts/lib/mcp_call.py`
- Create: `tests/fake_mcp_server.py`
- Create: `tests/test_mcp_call.py`

**Interfaces:**
- Consumes: any MCP stdio server command, by default `scripts/mcp-cml.sh`.
- Produces: `python3 scripts/lib/mcp_call.py --cmd CMD --tool NAME [--arg K=V]` prints the tool result's text content and exits 0; exits 1 on any JSON-RPC error or if the tool is not listed; exits 2 on a timeout (default 60 s).

- [ ] **Step 1: Write the fake server and the failing test**

`tests/fake_mcp_server.py`:
```python
#!/usr/bin/env python3
"""Tiny MCP stdio server: answers initialize, tools/list, and tools/call for
one tool, get_cml_labs. Newline-delimited JSON-RPC, like real servers."""
from __future__ import annotations

import json
import sys


def reply(msg_id: object, result: object) -> None:
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg_id, "result": result}) + "\n")
    sys.stdout.flush()


def main() -> None:
    for line in sys.stdin:
        msg = json.loads(line)
        method = msg.get("method")
        if method == "initialize":
            reply(msg["id"], {"protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
                              "serverInfo": {"name": "fake", "version": "0"}})
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list":
            reply(msg["id"], {"tools": [{"name": "get_cml_labs", "description": "labs", "inputSchema": {"type": "object"}}]})
        elif method == "tools/call":
            if msg["params"]["name"] == "get_cml_labs":
                reply(msg["id"], {"content": [{"type": "text", "text": '[{"id": "lab-1", "title": "Spine Leaf"}]'}]})
            else:
                sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"],
                                             "error": {"code": -32601, "message": "unknown tool"}}) + "\n")
                sys.stdout.flush()


if __name__ == "__main__":
    main()
```

`tests/test_mcp_call.py`:
```python
"""Tests for scripts/lib/mcp_call.py against tests/fake_mcp_server.py."""
import subprocess
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CLIENT = REPO / "scripts" / "lib" / "mcp_call.py"
FAKE = f"{sys.executable} {REPO / 'tests' / 'fake_mcp_server.py'}"


def call(*extra: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(CLIENT), "--cmd", FAKE, *extra],
                          capture_output=True, text=True, timeout=30)


class McpCallTest(unittest.TestCase):
    def test_calls_tool_and_prints_text(self) -> None:
        proc = call("--tool", "get_cml_labs")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Spine Leaf", proc.stdout)

    def test_unknown_tool_exits_1(self) -> None:
        proc = call("--tool", "nope")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("nope", proc.stderr)

    def test_dead_command_exits_1(self) -> None:
        proc = subprocess.run([sys.executable, str(CLIENT), "--cmd", "false", "--tool", "x"],
                              capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 1)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `python3 -m unittest tests.test_mcp_call -v`
Expected: failures, the client does not exist.

- [ ] **Step 3: Write `scripts/lib/mcp_call.py`**

```python
#!/usr/bin/env python3
"""Call one tool on an MCP stdio server and print its text result.

    python3 scripts/lib/mcp_call.py --cmd "bash scripts/mcp-cml.sh" --tool get_cml_labs

Does the initialize handshake, checks the tool is listed, calls it, prints
the concatenated text content. Exit 0 ok, 1 on error or unknown tool, 2 on
timeout. Stdlib only. Used by scripts/90-smoke-test.sh to prove cml-mcp can
reach the controller from the Mac.
"""
from __future__ import annotations

import argparse
import json
import shlex
import subprocess
import sys
import threading
from typing import Any

PROTOCOL = "2024-11-05"


class McpClient:
    def __init__(self, cmd: str, timeout: float) -> None:
        self.proc = subprocess.Popen(shlex.split(cmd), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True, bufsize=1)
        self.timeout = timeout
        self.next_id = 1

    def _write(self, msg: dict[str, Any]) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def _read_response(self, msg_id: int) -> dict[str, Any]:
        assert self.proc.stdout is not None
        result: dict[str, Any] = {}

        def reader() -> None:
            for line in self.proc.stdout:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if msg.get("id") == msg_id:
                    result.update(msg)
                    return

        t = threading.Thread(target=reader, daemon=True)
        t.start()
        t.join(self.timeout)
        if t.is_alive():
            raise TimeoutError(f"no response to request {msg_id} in {self.timeout}s")
        if not result:
            raise RuntimeError("server closed the stream: " + self._stderr_tail())
        return result

    def _stderr_tail(self) -> str:
        assert self.proc.stderr is not None
        try:
            return self.proc.stderr.read()[-2000:]
        except ValueError:
            return ""

    def request(self, method: str, params: dict[str, Any] | None = None) -> Any:
        msg_id = self.next_id
        self.next_id += 1
        self._write({"jsonrpc": "2.0", "id": msg_id, "method": method, "params": params or {}})
        response = self._read_response(msg_id)
        if "error" in response:
            raise RuntimeError(f"{method}: {response['error'].get('message', response['error'])}")
        return response["result"]

    def notify(self, method: str) -> None:
        self._write({"jsonrpc": "2.0", "method": method})

    def close(self) -> None:
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            self.proc.kill()


def parse_args_kv(pairs: list[str]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for pair in pairs:
        key, _, value = pair.partition("=")
        out[key] = value
    return out


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmd", required=True, help="server command line")
    parser.add_argument("--tool", required=True)
    parser.add_argument("--arg", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args(argv)

    try:
        client = McpClient(args.cmd, args.timeout)
    except OSError as exc:
        print(f"mcp_call: cannot start server: {exc}", file=sys.stderr)
        return 1
    try:
        client.request("initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                      "clientInfo": {"name": "cml-azure-lab-smoke", "version": "1"}})
        client.notify("notifications/initialized")
        tools = {t["name"] for t in client.request("tools/list").get("tools", [])}
        if args.tool not in tools:
            print(f"mcp_call: tool {args.tool!r} not offered. Offered: {sorted(tools)}", file=sys.stderr)
            return 1
        result = client.request("tools/call", {"name": args.tool, "arguments": parse_args_kv(args.arg)})
        if result.get("isError"):
            print(f"mcp_call: tool reported an error: {result}", file=sys.stderr)
            return 1
        for item in result.get("content", []):
            if item.get("type") == "text":
                print(item["text"])
        return 0
    except TimeoutError as exc:
        print(f"mcp_call: {exc}", file=sys.stderr)
        return 2
    except (RuntimeError, OSError) as exc:
        # OSError covers a server that died before reading (broken pipe).
        print(f"mcp_call: {exc}", file=sys.stderr)
        return 1
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `python3 -m unittest tests.test_mcp_call -v && tests/run.sh`
Expected: 3 tests pass, full gate passes.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/mcp_call.py tests/fake_mcp_server.py tests/test_mcp_call.py
git commit -m "feat: add MCP stdio client for smoke testing cml-mcp"
```

---

### Task 12: `00-preflight.sh`

**Files:**
- Create: `scripts/00-preflight.sh`
- Modify: `scripts/lib/tfvars.py` (add a command line entry point)
- Create: `tests/test_preflight.sh`

**Interfaces:**
- Consumes: `common.sh`, `config/cml.tfvars`, `config/refplat.txt`, persistent outputs when applied.
- Produces: `.preflight-ok` marker in the repo root on success (Task 14 checks its age). `python3 scripts/lib/tfvars.py FILE KEY` prints one value, lists space separated.

- [ ] **Step 1: Add the entry point to `scripts/lib/tfvars.py`**

Append:
```python


def _cli(argv: list[str]) -> int:
    """tfvars.py FILE KEY: print the value of KEY. Lists print space separated."""
    if len(argv) != 2:
        print("usage: tfvars.py FILE KEY", file=sys.stderr)
        return 2
    try:
        value = load(Path(argv[0]))[argv[1]]
    except (OSError, ValueError, KeyError) as exc:
        print(f"tfvars: {exc}", file=sys.stderr)
        return 1
    if isinstance(value, list):
        print(" ".join(value))
    elif isinstance(value, bool):
        print("true" if value else "false")
    else:
        print(value)
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(_cli(sys.argv[1:]))
```

Move `import sys` to the top of the file next to `import re` instead of inside the guard, so the module is tidy. Add this test to `tests/test_tfvars.py`:

```python
    def test_cli_prints_list_space_separated(self) -> None:
        import subprocess, tempfile
        with tempfile.NamedTemporaryFile("w", suffix=".tfvars", dir=Path(__file__).parent, delete=False) as fh:
            fh.write('cidrs = ["a/32", "b/32"]\nflag = true\n')
            name = fh.name
        try:
            out = subprocess.run([sys.executable, str(Path(tfvars.__file__)), name, "cidrs"], capture_output=True, text=True)
            self.assertEqual(out.stdout.strip(), "a/32 b/32")
            out = subprocess.run([sys.executable, str(Path(tfvars.__file__)), name, "flag"], capture_output=True, text=True)
            self.assertEqual(out.stdout.strip(), "true")
        finally:
            Path(name).unlink()
```

Run: `python3 -m unittest tests.test_tfvars -v`. Expected: pass.

- [ ] **Step 2: Write the failing test**

`tests/test_preflight.sh`:
```bash
#!/usr/bin/env bash
# Preflight is read-only, so the test runs it for real when RUN_AZ_TESTS=1
# and otherwise only checks the failure path that needs no Azure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/00-preflight.sh"
failures=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}

# Missing tfvars must be a FAIL line, not a crash, and the marker must not exist.
rm -f "${REPO_ROOT}/.preflight-ok"
out="$(CML_TFVARS="${REPO_ROOT}/does-not-exist.tfvars" bash "${SCRIPT}" 2>&1 || true)"
assert_contains "missing tfvars is a FAIL" "[FAIL]  config/cml.tfvars" "${out}"
assert_contains "summary line printed" "summary:" "${out}"
if [[ -f "${REPO_ROOT}/.preflight-ok" ]]; then
  echo "[FAIL]  marker written despite failure"; failures=$((failures + 1))
else
  echo "[OK]    no marker on failure"
fi

if [[ "${RUN_AZ_TESTS:-0}" == "1" ]]; then
  out="$(bash "${SCRIPT}" 2>&1 || true)"
  assert_contains "az login check ran" "azure login:" "${out}"
  assert_contains "quota check ran" "quota" "${out}"
fi

if [[ "${failures}" -gt 0 ]]; then echo "test_preflight: ${failures} failure(s)"; exit 1; fi
echo "test_preflight: all passed"
```

Run: `bash tests/test_preflight.sh`. Expected: `[FAIL]` lines, script missing.

- [ ] **Step 3: Write `scripts/00-preflight.sh`**

```bash
#!/usr/bin/env bash
# Pre-build readiness check. Read-only. Run it before scripts/20-up.sh.
#
# Checks:
#   1. az login valid, ARM_SUBSCRIPTION_ID set and matching
#   2. Toolchain: terraform az azcopy jq uv uvx python3 shellcheck pre-commit gitleaks
#   3. terraform fmt -check and validate on bootstrap, persistent, vendor/cloud-cml
#   4. Submodule at the pinned commit
#   5. config/cml.tfvars present, parses, no 0.0.0.0/0, refplat.txt parses
#   6. vCPU quota in the region for the requested size (family and regional)
#   7. Package and every listed refplat image present in the cml container
#      (skipped with a WARN until the persistent root has been applied)
#   8. Estimated copy time versus SAS validity (WARN only)
#
# Writes .preflight-ok in the repo root when nothing FAILs; 20-up.sh refuses
# to run without a fresh marker. Exit 1 on any FAIL.
#
# Overrides: LOCATION (eastus2), CML_TFVARS, REFPLAT_FILE, ASSUMED_MBPS (50).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

LOCATION="${LOCATION:-eastus2}"
CML_TFVARS="${CML_TFVARS:-${REPO_ROOT}/config/cml.tfvars}"
REFPLAT_FILE="${REFPLAT_FILE:-${REPO_ROOT}/config/refplat.txt}"
ASSUMED_MBPS="${ASSUMED_MBPS:-50}"
TFVARS_PY="${REPO_ROOT}/scripts/lib/tfvars.py"
MARKER="${REPO_ROOT}/.preflight-ok"

tfvar() { python3 "${TFVARS_PY}" "${CML_TFVARS}" "$1" 2>/dev/null; }

check_login() {
  local user sub_id
  if user="$(az account show --query user.name -o tsv 2>/dev/null)" && [[ -n "${user}" ]]; then
    pass "azure login: ${user}"
  else
    miss "azure login: not signed in. Run: az login"
    return 0
  fi
  if [[ -z "${ARM_SUBSCRIPTION_ID:-}" ]]; then
    miss "ARM_SUBSCRIPTION_ID: not set. See docs/PREREQUISITES.md section 2.2"
    return 0
  fi
  sub_id="$(az account show --query id -o tsv 2>/dev/null)"
  if [[ "${sub_id}" == "${ARM_SUBSCRIPTION_ID}" ]]; then
    pass "ARM_SUBSCRIPTION_ID matches the active subscription"
  else
    miss "ARM_SUBSCRIPTION_ID does not match az account show. Run: az account set"
  fi
}

check_tools() {
  local tool
  for tool in terraform az azcopy jq uv uvx python3 shellcheck pre-commit gitleaks ssh-keygen; do
    if command -v "${tool}" >/dev/null 2>&1; then
      pass "tool ${tool}"
    else
      miss "tool ${tool}: not installed. See docs/PREREQUISITES.md section 4"
    fi
  done
}

check_terraform_root() {
  local dir="$1" label="$2"
  if [[ ! -d "${dir}" ]]; then
    miss "terraform ${label}: ${dir} missing"
    return 0
  fi
  if terraform -chdir="${dir}" fmt -check -recursive >/dev/null 2>&1; then
    pass "terraform fmt ${label}"
  else
    miss "terraform fmt ${label}: run terraform -chdir=${dir} fmt -recursive"
  fi
  if [[ ! -d "${dir}/.terraform" ]]; then
    terraform -chdir="${dir}" init -backend=false -input=false >/dev/null 2>&1 || true
  fi
  if terraform -chdir="${dir}" validate >/dev/null 2>&1; then
    pass "terraform validate ${label}"
  else
    miss "terraform validate ${label}: run terraform -chdir=${dir} validate"
  fi
}

check_submodule() {
  local line
  line="$(cd "${REPO_ROOT}" && git submodule status vendor/cloud-cml 2>/dev/null || true)"
  case "${line}" in
    " "*) pass "submodule vendor/cloud-cml at pinned commit" ;;
    "+"*) miss "submodule vendor/cloud-cml differs from the pinned commit. Run: git submodule update" ;;
    "-"*) miss "submodule vendor/cloud-cml not initialized. Run: git submodule update --init" ;;
    *) miss "submodule vendor/cloud-cml: unexpected status '${line}'" ;;
  esac
}

check_config() {
  local key list
  if [[ ! -f "${CML_TFVARS}" ]]; then
    miss "config/cml.tfvars: missing. Copy config/cml.tfvars.example and fill it in"
    return 0
  fi
  pass "config/cml.tfvars present"
  for key in smartlicense_token license_flavor vm_size software_package sas_validity; do
    if [[ -n "$(tfvar "${key}")" ]]; then
      pass "cml.tfvars ${key} set"
    else
      miss "cml.tfvars ${key}: missing or unparsable"
    fi
  done
  if [[ "$(tfvar smartlicense_token)" == "PASTE-TOKEN-HERE" ]]; then
    miss "cml.tfvars smartlicense_token is still the placeholder"
  fi
  for key in allowed_ipv4_subnets_mgmt allowed_ipv4_subnets_cml2; do
    list="$(tfvar "${key}")"
    if [[ -z "${list}" ]]; then
      miss "cml.tfvars ${key}: empty"
    elif grep -q "0.0.0.0/0" <<<"${list}"; then
      miss "cml.tfvars ${key} contains 0.0.0.0/0"
    else
      pass "cml.tfvars ${key}: ${list}"
    fi
  done
  if [[ -f "${REFPLAT_FILE}" ]] && [[ "$(grep -cvE '^\s*(#|$)' "${REFPLAT_FILE}")" -gt 0 ]]; then
    pass "refplat.txt lists $(grep -cvE '^\s*(#|$)' "${REFPLAT_FILE}") images"
  else
    miss "config/refplat.txt missing or empty"
  fi
}

check_quota() {
  local size family vcpus limit total
  size="$(tfvar vm_size)"
  [[ -n "${size}" ]] || return 0
  family="$(az vm list-skus -l "${LOCATION}" --size "${size}" --query "[0].family" -o tsv 2>/dev/null || true)"
  vcpus="$(az vm list-skus -l "${LOCATION}" --size "${size}" --query "[0].capabilities[?name=='vCPUs'].value | [0]" -o tsv 2>/dev/null || true)"
  if [[ -z "${family}" || -z "${vcpus}" ]]; then
    miss "quota: size ${size} not found in ${LOCATION}"
    return 0
  fi
  limit="$(az vm list-usage -l "${LOCATION}" --query "[?name.value=='${family}'].limit | [0]" -o tsv 2>/dev/null || echo 0)"
  total="$(az vm list-usage -l "${LOCATION}" --query "[?name.value=='cores'].limit | [0]" -o tsv 2>/dev/null || echo 0)"
  if [[ "${limit:-0}" -ge "${vcpus}" ]]; then
    pass "quota ${family} in ${LOCATION}: ${limit} (need ${vcpus} for ${size})"
  else
    miss "quota ${family} in ${LOCATION}: ${limit:-0}, need ${vcpus}. See docs/PREREQUISITES.md section 2.1"
  fi
  if [[ "${total:-0}" -ge "${vcpus}" ]]; then
    pass "quota regional vCPUs in ${LOCATION}: ${total}"
  else
    miss "quota regional vCPUs in ${LOCATION}: ${total:-0}, need ${vcpus}"
  fi
}

sas_seconds() {
  local v="$1"
  case "${v}" in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *) echo 0 ;;
  esac
}

check_blobs() {
  local sa pkg def img count bytes total_bytes=0 est validity
  if ! sa="$(tf_out persistent storage_account_name 2>/dev/null)" || [[ -z "${sa}" ]]; then
    warn "blob checks skipped: persistent root not applied yet"
    return 0
  fi
  pkg="$(tfvar software_package)"
  if az storage blob show --auth-mode login --account-name "${sa}" -c cml -n "${pkg}" -o none 2>/dev/null; then
    pass "blob ${pkg} present"
  else
    miss "blob ${pkg} missing in container cml. Run: scripts/10-upload-images.sh"
  fi
  while read -r def img; do
    [[ -z "${def}" || "${def}" == \#* ]] && continue
    if az storage blob show --auth-mode login --account-name "${sa}" -c cml -n "refplat/node-definitions/${def}.yaml" -o none 2>/dev/null; then
      pass "blob node definition ${def}"
    else
      miss "blob node definition ${def} missing"
    fi
    count="$(az storage blob list --auth-mode login --account-name "${sa}" -c cml --prefix "refplat/virl-base-images/${img}/" --query "length(@)" -o tsv 2>/dev/null || echo 0)"
    if [[ "${count:-0}" -gt 0 ]]; then
      bytes="$(az storage blob list --auth-mode login --account-name "${sa}" -c cml --prefix "refplat/virl-base-images/${img}/" --query "sum([].properties.contentLength)" -o tsv 2>/dev/null || echo 0)"
      total_bytes=$(( total_bytes + ${bytes:-0} ))
      pass "blob image ${img} ($(( ${bytes:-0} / 1048576 )) MB)"
    else
      miss "blob image ${img} missing. Run: scripts/10-upload-images.sh"
    fi
  done < "${REFPLAT_FILE}"
  validity="$(sas_seconds "$(tfvar sas_validity)")"
  est=$(( total_bytes / (ASSUMED_MBPS * 1048576) ))
  if [[ "${validity}" -gt 0 && "${est}" -gt $(( validity * 8 / 10 )) ]]; then
    warn "image copy estimate ${est}s at ${ASSUMED_MBPS} MB/s is close to SAS validity ${validity}s. Raise sas_validity"
  else
    pass "image copy estimate ${est}s within SAS validity ${validity}s"
  fi
}

main() {
  rm -f "${MARKER}"
  check_login
  check_tools
  check_terraform_root "${REPO_ROOT}/terraform/bootstrap" bootstrap
  check_terraform_root "${REPO_ROOT}/terraform/persistent" persistent
  check_terraform_root "${REPO_ROOT}/vendor/cloud-cml" cloud-cml
  check_submodule
  check_config
  if [[ -f "${CML_TFVARS}" ]] && command -v az >/dev/null 2>&1; then
    check_quota
    check_blobs
  fi
  if [[ "${fail}" -eq 0 ]]; then
    touch "${MARKER}"
  fi
  summary_and_exit
}

main "$@"
```

- [ ] **Step 4: Run the tests**

Run: `chmod +x scripts/00-preflight.sh && bash tests/test_preflight.sh && RUN_AZ_TESTS=1 bash tests/test_preflight.sh && tests/run.sh`
Expected: both passes. The real run prints the current state: quota `[FAIL]` until the request is approved, blob checks `[WARN]` skipped.

- [ ] **Step 5: Commit**

```bash
git add scripts/00-preflight.sh scripts/lib/tfvars.py tests/test_tfvars.py tests/test_preflight.sh
git commit -m "feat: add preflight readiness check"
```

---

### Task 13: `10-upload-images.sh`

**Files:**
- Create: `scripts/10-upload-images.sh`
- Create: `tests/test_upload_dry_run.sh`

**Interfaces:**
- Consumes: `software/` (or `CML_SOFTWARE_DIR`), `config/refplat.txt`, `config/cml.tfvars` for `software_package`, persistent output `storage_account_name` (or `STORAGE_ACCOUNT` override).
- Produces: blobs in container `cml`: `<package>.pkg` at the root, `refplat/node-definitions/<def>.yaml`, `refplat/virl-base-images/<img>/...`. Layout matches upstream's Azure documentation.

- [ ] **Step 1: Write the failing test**

`tests/test_upload_dry_run.sh`:
```bash
#!/usr/bin/env bash
# Dry-run tests for scripts/10-upload-images.sh with a fake mounted ISO.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/10-upload-images.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
failures=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

# Fake ISO contents and software folder.
mkdir -p "${TMP}/iso/node-definitions" "${TMP}/iso/virl-base-images/alpine-base-3-21-3" "${TMP}/iso/virl-base-images/iosv-159-3-m10" "${TMP}/software"
touch "${TMP}/iso/node-definitions/alpine.yaml" "${TMP}/iso/node-definitions/iosv.yaml"
touch "${TMP}/iso/virl-base-images/alpine-base-3-21-3/alpine.qcow2" "${TMP}/iso/virl-base-images/iosv-159-3-m10/iosv.qcow2"
touch "${TMP}/software/cml2_2.9.0-3_amd64-3.pkg"
printf 'alpine alpine-base-3-21-3\niosv iosv-159-3-m10\n' > "${TMP}/refplat.txt"
printf 'software_package = "cml2_2.9.0-3_amd64-3.pkg"\n' > "${TMP}/cml.tfvars"

common="REFPLAT_DIR=${TMP}/iso CML_SOFTWARE_DIR=${TMP}/software REFPLAT_FILE=${TMP}/refplat.txt CML_TFVARS=${TMP}/cml.tfvars STORAGE_ACCOUNT=stfake"

out="$(env ${common} bash "${SCRIPT}" --dry-run 2>&1)"; rc=$?
assert_eq "dry run exits 0" "0" "${rc}"
assert_contains "package copy planned" "+ azcopy copy ${TMP}/software/cml2_2.9.0-3_amd64-3.pkg https://stfake.blob.core.windows.net/cml/cml2_2.9.0-3_amd64-3.pkg" "${out}"
assert_contains "definition copy planned" "+ azcopy copy ${TMP}/iso/node-definitions/alpine.yaml https://stfake.blob.core.windows.net/cml/refplat/node-definitions/alpine.yaml" "${out}"
assert_contains "image copy planned" "+ azcopy copy ${TMP}/iso/virl-base-images/iosv-159-3-m10 https://stfake.blob.core.windows.net/cml/refplat/virl-base-images/ --recursive" "${out}"
assert_contains "azcopy state kept in repo" "AZCOPY_LOG_LOCATION=${REPO_ROOT}/.azcopy" "${out}"

# A missing image is a FAIL and exit 1.
printf 'alpine alpine-base-3-21-3\nnxosv9000 nxosv9300-10-5-3-f\n' > "${TMP}/refplat.txt"
rc=0; out="$(env ${common} bash "${SCRIPT}" --dry-run 2>&1)" || rc=$?
assert_eq "missing image exits 1" "1" "${rc}"
assert_contains "missing image reported" "[FAIL]  image nxosv9300-10-5-3-f not on the ISO" "${out}"

if [[ "${failures}" -gt 0 ]]; then echo "test_upload_dry_run: ${failures} failure(s)"; exit 1; fi
echo "test_upload_dry_run: all passed"
```

Run: `bash tests/test_upload_dry_run.sh`. Expected: fails, script missing.

- [ ] **Step 2: Write `scripts/10-upload-images.sh`**

```bash
#!/usr/bin/env bash
# Upload the CML package and the selected refplat images to the cml container.
#
#   scripts/10-upload-images.sh [--dry-run]
#
# Mounts the refplat ISO from software/ read-only, copies only the node
# definitions and images listed in config/refplat.txt plus the package named
# in config/cml.tfvars, then unmounts. Existing blobs are skipped, so re-runs
# are cheap. Uses the az login session through AZCOPY_AUTO_LOGIN_TYPE=AZCLI;
# the persistent root grants Storage Blob Data Contributor for this.
#
# azcopy keeps logs and job plans under ~/.azcopy by default. Repo rule says
# nothing outside the repo, so they go to .azcopy/ here (gitignored).
#
# Overrides: CML_SOFTWARE_DIR (software/), REFPLAT_ISO (auto-detect
# refplat-*.iso), REFPLAT_DIR (skip mounting, use this folder), REFPLAT_FILE,
# CML_TFVARS, STORAGE_ACCOUNT (persistent output), CONTAINER (cml).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CML_SOFTWARE_DIR="${CML_SOFTWARE_DIR:-${REPO_ROOT}/software}"
REFPLAT_FILE="${REFPLAT_FILE:-${REPO_ROOT}/config/refplat.txt}"
CML_TFVARS="${CML_TFVARS:-${REPO_ROOT}/config/cml.tfvars}"
CONTAINER="${CONTAINER:-cml}"
MOUNT_POINT="${REPO_ROOT}/.refplat-mount"
DRY_RUN=0
MOUNTED=0

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

find_iso() {
  local candidates
  if [[ -n "${REFPLAT_ISO:-}" ]]; then
    echo "${REFPLAT_ISO}"
    return 0
  fi
  candidates="$(ls "${CML_SOFTWARE_DIR}"/refplat-*.iso 2>/dev/null || true)"
  if [[ "$(echo "${candidates}" | grep -c .)" -ne 1 ]]; then
    die "expected exactly one refplat-*.iso in ${CML_SOFTWARE_DIR}, found: ${candidates:-none}. Set REFPLAT_ISO."
  fi
  echo "${candidates}"
}

mount_iso() {
  local iso="$1"
  if [[ -n "${REFPLAT_DIR:-}" ]]; then
    echo "using REFPLAT_DIR=${REFPLAT_DIR}, not mounting"
    return 0
  fi
  require_cmd hdiutil
  mkdir -p "${MOUNT_POINT}"
  hdiutil attach -readonly -nobrowse -mountpoint "${MOUNT_POINT}" "${iso}" >/dev/null
  MOUNTED=1
  REFPLAT_DIR="${MOUNT_POINT}"
}

unmount_iso() {
  if [[ "${MOUNTED}" == "1" ]]; then
    hdiutil detach "${MOUNT_POINT}" -quiet || true
    rmdir "${MOUNT_POINT}" 2>/dev/null || true
  fi
}

storage_base() {
  local sa="${STORAGE_ACCOUNT:-}"
  if [[ -z "${sa}" ]]; then
    sa="$(tf_out persistent storage_account_name)" || die "persistent root not applied; set STORAGE_ACCOUNT or run 20-up.sh through the persistent step"
  fi
  echo "https://${sa}.blob.core.windows.net/${CONTAINER}"
}

verify_selection() {
  local def img
  while read -r def img; do
    [[ -z "${def}" || "${def}" == \#* ]] && continue
    if [[ -f "${REFPLAT_DIR}/node-definitions/${def}.yaml" ]]; then
      pass "definition ${def}"
    else
      miss "definition ${def} not on the ISO"
    fi
    if [[ -d "${REFPLAT_DIR}/virl-base-images/${img}" ]]; then
      pass "image ${img}"
    else
      miss "image ${img} not on the ISO"
    fi
  done < "${REFPLAT_FILE}"
}

upload_all() {
  local base="$1" pkg def img
  pkg="$(python3 "${REPO_ROOT}/scripts/lib/tfvars.py" "${CML_TFVARS}" software_package)"
  if [[ ! -f "${CML_SOFTWARE_DIR}/${pkg}" ]]; then
    miss "package ${CML_SOFTWARE_DIR}/${pkg} missing"
    return 0
  fi
  run azcopy copy "${CML_SOFTWARE_DIR}/${pkg}" "${base}/${pkg}" --overwrite=false
  while read -r def img; do
    [[ -z "${def}" || "${def}" == \#* ]] && continue
    run azcopy copy "${REFPLAT_DIR}/node-definitions/${def}.yaml" "${base}/refplat/node-definitions/${def}.yaml" --overwrite=false
    run azcopy copy "${REFPLAT_DIR}/virl-base-images/${img}" "${base}/refplat/virl-base-images/" --recursive --overwrite=false
  done < "${REFPLAT_FILE}"
  pass "uploads issued to ${base}"
}

main() {
  local iso base
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
  export AZCOPY_AUTO_LOGIN_TYPE=AZCLI
  export AZCOPY_LOG_LOCATION="${REPO_ROOT}/.azcopy" AZCOPY_JOB_PLAN_LOCATION="${REPO_ROOT}/.azcopy"
  mkdir -p "${AZCOPY_LOG_LOCATION}"
  echo "AZCOPY_LOG_LOCATION=${AZCOPY_LOG_LOCATION}"
  if [[ "${DRY_RUN}" != "1" ]]; then
    require_cmd azcopy az python3
  fi
  trap unmount_iso EXIT
  if [[ -z "${REFPLAT_DIR:-}" ]]; then
    iso="$(find_iso)"
    mount_iso "${iso}"
  fi
  base="$(storage_base)"
  verify_selection
  if [[ "${fail}" -gt 0 ]]; then
    summary_and_exit
  fi
  upload_all "${base}"
  summary_and_exit
}

main "$@"
```

- [ ] **Step 3: Run the tests**

Run: `chmod +x scripts/10-upload-images.sh && bash tests/test_upload_dry_run.sh && tests/run.sh`
Expected: all passed.

- [ ] **Step 4: Commit**

```bash
git add scripts/10-upload-images.sh tests/test_upload_dry_run.sh
git commit -m "feat: add refplat and package upload script with dry run"
```

---

### Task 14: `20-up.sh`

**Files:**
- Create: `scripts/20-up.sh`
- Create: `tests/stubs/az`
- Create: `tests/test_up_dry_run.sh`

**Interfaces:**
- Consumes: `.preflight-ok`, `keys/cml-lab`, the three roots, `render_cml_config.py`, persistent outputs.
- Produces: `config/cml.yml`, `config/mcp-env/cml.env` with `CML_URL`, `CML_USERNAME`, `CML_PASSWORD`, `CML_VERIFY_SSL=false`; a running CML host. Prints the URL, the IP, and the `del.sh` command.

- [ ] **Step 1: Write the az stub and the failing test**

`tests/stubs/az`:
```bash
#!/usr/bin/env bash
# Stand-in for the Azure CLI in dry-run tests. Answers only what 20-up.sh asks.
case "$*" in
  *"account show"*"--query id"*) echo "00000000-0000-0000-0000-000000000000" ;;
  *"account show"*"--query tenantId"*) echo "11111111-1111-1111-1111-111111111111" ;;
  *"account show"*) echo "stub-user" ;;
  *"vm show"*) exit 3 ;;
  *) echo "az stub: unhandled: $*" >&2; exit 1 ;;
esac
```

`tests/test_up_dry_run.sh`:
```bash
#!/usr/bin/env bash
# Dry-run test for scripts/20-up.sh: proves the order of operations and that
# nothing is executed. az is stubbed through PATH; terraform is never called
# because every state change goes through run().
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/20-up.sh"
chmod +x "${REPO_ROOT}/tests/stubs/az"
failures=0

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}
line_of() { grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1; }

out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000000 ASSUME_YES=1 bash "${SCRIPT}" --dry-run 2>&1)"; rc=$?
assert_eq "dry run exits 0" "0" "${rc}"
assert_contains "bootstrap apply planned" "+ terraform -chdir=${REPO_ROOT}/terraform/bootstrap apply" "${out}"
assert_contains "persistent apply planned" "+ terraform -chdir=${REPO_ROOT}/terraform/persistent apply" "${out}"
assert_contains "render planned" "+ python3 ${REPO_ROOT}/scripts/lib/render_cml_config.py" "${out}"
assert_contains "cml apply planned" "+ terraform -chdir=${REPO_ROOT}/vendor/cloud-cml apply" "${out}"
assert_contains "env file planned" "+ write ${REPO_ROOT}/config/mcp-env/cml.env" "${out}"

b="$(line_of "terraform/bootstrap apply" "${out}")"; p="$(line_of "terraform/persistent apply" "${out}")"
r="$(line_of "render_cml_config.py" "${out}")"; c="$(line_of "vendor/cloud-cml apply" "${out}")"
if [[ "${b}" -lt "${p}" && "${p}" -lt "${r}" && "${r}" -lt "${c}" ]]; then
  echo "[OK]    order bootstrap < persistent < render < cml"
else
  echo "[FAIL]  order wrong: ${b} ${p} ${r} ${c}"; failures=$((failures + 1))
fi

# Without the preflight marker, a real run refuses before doing anything.
rm -f "${REPO_ROOT}/.preflight-ok"
rc=0; out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=x bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "refuses without marker" "1" "${rc}"
assert_contains "names the remedy" "scripts/00-preflight.sh" "${out}"

if [[ "${failures}" -gt 0 ]]; then echo "test_up_dry_run: ${failures} failure(s)"; exit 1; fi
echo "test_up_dry_run: all passed"
```

Run: `bash tests/test_up_dry_run.sh`. Expected: fails, script missing.

- [ ] **Step 2: Write `scripts/20-up.sh`**

```bash
#!/usr/bin/env bash
# Bring the lab up: bootstrap (once), persistent, then the CML VM.
#
#   scripts/20-up.sh [--dry-run]
#
# Order:
#   1. Refuse unless .preflight-ok is fresh (PREFLIGHT_MAX_AGE_MIN, 240)
#   2. Generate keys/cml-lab if missing (RSA 4096)
#   3. Bootstrap apply if it has no local state; verify backend.tf matches
#   4. Persistent init and apply
#   5. Refuse if the CML VM already exists
#   6. Render config/cml.yml from persistent outputs, cml.tfvars, refplat.txt
#   7. cloud-cml init and apply (its readiness module waits for the API)
#   8. Write config/mcp-env/cml.env, print URL, IP, and the del.sh command
#
# Every apply prompts unless ASSUME_YES=1. --dry-run prints what would run.
# Never runs destroy. Never touches bootstrap or persistent with destroy.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PREFLIGHT_MAX_AGE_MIN="${PREFLIGHT_MAX_AGE_MIN:-240}"
CML_TFVARS="${CML_TFVARS:-${REPO_ROOT}/config/cml.tfvars}"
REFPLAT_FILE="${REFPLAT_FILE:-${REPO_ROOT}/config/refplat.txt}"
KEY_FILE="${REPO_ROOT}/keys/cml-lab"
CML_YML="${REPO_ROOT}/config/cml.yml"
ENV_FILE="${REPO_ROOT}/config/mcp-env/cml.env"
BOOTSTRAP="${REPO_ROOT}/terraform/bootstrap"
PERSISTENT="${REPO_ROOT}/terraform/persistent"
CLOUD_CML="${REPO_ROOT}/vendor/cloud-cml"
DRY_RUN=0

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

# In a dry run the roots may not be applied, so outputs fall back to a
# visible placeholder instead of aborting.
out_or_placeholder() {
  local value
  if value="$(tf_out persistent "$1" 2>/dev/null)" && [[ -n "${value}" ]]; then
    echo "${value}"
  elif [[ "${DRY_RUN}" == "1" ]]; then
    echo "<$1>"
  else
    die "persistent output $1 unavailable"
  fi
}

check_preflight_marker() {
  local marker="${REPO_ROOT}/.preflight-ok" age
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "dry run: skipping preflight marker check"
    return 0
  fi
  [[ -f "${marker}" ]] || die "no preflight marker. Run: scripts/00-preflight.sh"
  age=$(( ( $(date +%s) - $(stat -f %m "${marker}") ) / 60 ))
  if [[ "${age}" -gt "${PREFLIGHT_MAX_AGE_MIN}" ]]; then
    die "preflight marker is ${age} minutes old. Run: scripts/00-preflight.sh"
  fi
  pass "preflight marker ${age} minutes old"
}

ensure_ssh_key() {
  if [[ -f "${KEY_FILE}" && -f "${KEY_FILE}.pub" ]]; then
    pass "ssh key ${KEY_FILE}"
    return 0
  fi
  mkdir -p "${REPO_ROOT}/keys"
  run ssh-keygen -t rsa -b 4096 -N "" -C "cml-lab" -f "${KEY_FILE}"
}

apply_bootstrap() {
  if [[ -f "${BOOTSTRAP}/terraform.tfstate" ]]; then
    pass "bootstrap already applied"
  else
    confirm "Apply the bootstrap root (state storage account)?" || die "declined"
    run terraform -chdir="${BOOTSTRAP}" init -input=false
    run terraform -chdir="${BOOTSTRAP}" apply -input=false -auto-approve
  fi
  if [[ "${DRY_RUN}" != "1" ]]; then
    local sa
    sa="$(tf_out bootstrap storage_account_name)"
    grep -q "storage_account_name *= *\"${sa}\"" "${PERSISTENT}/backend.tf" ||
      die "terraform/persistent/backend.tf does not name ${sa}. Fix it and commit (plan Task 5)."
  fi
}

apply_persistent() {
  confirm "Apply the persistent root (network, IP, 512 GB disk, storage)?" || die "declined"
  run terraform -chdir="${PERSISTENT}" init -input=false
  run terraform -chdir="${PERSISTENT}" apply -input=false -auto-approve
}

refuse_if_vm_exists() {
  local rg
  rg="$(out_or_placeholder resource_group_name)"
  if az vm show -g "${rg}" -n cml-controller -o none 2>/dev/null; then
    die "VM cml-controller already exists in ${rg}. Run scripts/40-down.sh first."
  fi
  pass "no existing CML VM in ${rg}"
}

render_config() {
  local app_pw sys_pw
  app_pw="$(out_or_placeholder app_admin_password)"
  sys_pw="$(out_or_placeholder sys_admin_password)"
  run python3 "${REPO_ROOT}/scripts/lib/render_cml_config.py" \
    --template "${REPO_ROOT}/config/cml.yml.tftpl" \
    --tfvars "${CML_TFVARS}" --refplat "${REFPLAT_FILE}" --out "${CML_YML}" \
    --set "RESOURCE_GROUP=$(out_or_placeholder resource_group_name)" \
    --set "STORAGE_ACCOUNT=$(out_or_placeholder storage_account_name)" \
    --set "CONTAINER_NAME=$(out_or_placeholder cml_container_name)" \
    --set "VNET_NAME=$(out_or_placeholder vnet_name)" \
    --set "SUBNET_NAME=$(out_or_placeholder cml_subnet_name)" \
    --set "PRIVATE_IP=$(out_or_placeholder cml_private_ip)" \
    --set "PUBLIC_IP_NAME=$(out_or_placeholder public_ip_name)" \
    --set "DATA_DISK_ID=$(out_or_placeholder data_disk_id)" \
    --set "OS_DISK_TYPE=${OS_DISK_TYPE:-Premium_LRS}" \
    --set "APPS_SUBNET_CIDR=$(out_or_placeholder apps_subnet_cidr)" \
    --set "LAB_SUMMARY_CIDR=$(out_or_placeholder lab_summary_cidr)" \
    --set "SSH_KEY_NAME=$(out_or_placeholder ssh_key_name)" \
    --set "APP_PASSWORD=${app_pw}" \
    --set "SYS_PASSWORD=${sys_pw}"
}

apply_cml() {
  local tenant
  tenant="$(az account show --query tenantId -o tsv)"
  export TF_VAR_cfg_file="${CML_YML}"
  export TF_VAR_azure_subscription_id="${ARM_SUBSCRIPTION_ID}"
  export TF_VAR_azure_tenant_id="${tenant}"
  confirm "Apply the CML root (creates the VM, registers the license)?" || die "declined"
  run terraform -chdir="${CLOUD_CML}" init -input=false
  run terraform -chdir="${CLOUD_CML}" apply -input=false -auto-approve
}

write_env_and_report() {
  local ip pw
  ip="$(out_or_placeholder public_ip_address)"
  pw="$(out_or_placeholder app_admin_password)"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ write ${ENV_FILE}"
  else
    mkdir -p "$(dirname "${ENV_FILE}")"
    umask 077
    printf 'CML_URL=https://%s\nCML_USERNAME=admin\nCML_PASSWORD=%s\nCML_VERIFY_SSL=false\n' "${ip}" "${pw}" > "${ENV_FILE}"
    pass "wrote ${ENV_FILE}"
  fi
  echo
  echo "CML URL:      https://${ip}"
  echo "CML IP:       ${ip}"
  echo "SSH:          ssh -p 1122 -i ${KEY_FILE} sysadmin@${ip}"
  echo "Deregister:   ssh -p 1122 -i ${KEY_FILE} sysadmin@${ip} /provision/del.sh"
  echo "Next:         scripts/90-smoke-test.sh"
}

main() {
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
  require_env ARM_SUBSCRIPTION_ID
  require_cmd terraform az python3 ssh-keygen
  check_preflight_marker
  ensure_ssh_key
  apply_bootstrap
  apply_persistent
  refuse_if_vm_exists
  render_config
  apply_cml
  write_env_and_report
}

main "$@"
```

- [ ] **Step 3: Run the tests**

Run: `chmod +x scripts/20-up.sh && bash tests/test_up_dry_run.sh && tests/run.sh`
Expected: all passed. Note `stat -f %m` is the macOS form; the script only runs on the Mac.

- [ ] **Step 4: Commit**

```bash
git add scripts/20-up.sh tests/stubs/az tests/test_up_dry_run.sh
git commit -m "feat: add 20-up.sh with dry run and ordered applies"
```

---

### Task 15: `30-export-labs.sh`

**Files:**
- Create: `scripts/30-export-labs.sh`
- Create: `tests/stubs/terraform`
- Create: `tests/test_export_dry_run.sh`

**Interfaces:**
- Consumes: `cml_ip`, `cml_ssh`, `scripts/lib/cml-remote.sh export-labs`, persistent output `storage_account_name`.
- Produces: `/data/exports/<UTC timestamp>/` on the host, a copy under `exports/<timestamp>/` in the repo, and the same folder in blob container `exports`. Task 16 calls this script first.

- [ ] **Step 1: Write the terraform stub and the failing test**

`tests/stubs/terraform`:
```bash
#!/usr/bin/env bash
# Stand-in for terraform in dry-run tests. Only "output -raw NAME" is used.
if [[ "${TF_STUB_FAIL:-0}" == "1" ]]; then
  echo "stub: no state" >&2; exit 1
fi
case "$*" in
  *"output -raw public_ip_address"*) echo "203.0.113.5" ;;
  *"output -raw storage_account_name"*) echo "stfake" ;;
  *"output -raw resource_group_name"*) echo "rg-cml-lab" ;;
  *"output -raw"*) echo "stub-value" ;;
  *"output -json cml2info"*) echo '{"address":"203.0.113.5","url":"https://203.0.113.5","version":"2.9.0"}' ;;
  *) echo "terraform stub: unhandled: $*" >&2; exit 1 ;;
esac
```

`tests/test_export_dry_run.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/30-export-labs.sh"
chmod +x "${REPO_ROOT}/tests/stubs/"*
failures=0
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
line_of() { grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1; }

out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" bash "${SCRIPT}" --dry-run 2>&1)"
assert_contains "remote export planned" "bash -s -- export-labs /data/exports/" "${out}"
assert_contains "scp planned" "+ scp -P 1122" "${out}"
assert_contains "blob upload planned" "https://stfake.blob.core.windows.net/exports/" "${out}"
e="$(line_of "export-labs /data/exports/" "${out}")"; s="$(line_of "+ scp -P 1122" "${out}")"; u="$(line_of "blob.core.windows.net/exports/" "${out}")"
if [[ "${e}" -lt "${s}" && "${s}" -lt "${u}" ]]; then echo "[OK]    order export < scp < upload"; else
  echo "[FAIL]  order: ${e} ${s} ${u}"; failures=$((failures + 1)); fi

if [[ "${failures}" -gt 0 ]]; then echo "test_export_dry_run: ${failures} failure(s)"; exit 1; fi
echo "test_export_dry_run: all passed"
```

Run: `bash tests/test_export_dry_run.sh`. Expected: fails, script missing.

- [ ] **Step 2: Write `scripts/30-export-labs.sh`**

```bash
#!/usr/bin/env bash
# Export every lab to YAML and copy the folder to blob storage.
#
#   scripts/30-export-labs.sh [--dry-run]
#
# 1. Refuse if the CML API does not answer (nothing to export safely)
# 2. On the host: cml-remote.sh export-labs /data/exports/<UTC timestamp>
# 3. scp that folder to exports/<timestamp>/ in the repo (gitignored)
# 4. azcopy the local copy to the exports container, same folder name
#
# The blob copy is the durable one. The host copy dies with the VM, the
# local copy is a convenience for diffing. Reimport is by hand or via
# cml-mcp create_full_lab_topology, on purpose (spec section 3).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REMOTE_LIB="${REPO_ROOT}/scripts/lib/cml-remote.sh"
LOCAL_EXPORTS="${REPO_ROOT}/exports"
DRY_RUN=0

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

api_ready() {
  local ip="$1"
  [[ "$(curl -sk -m 10 "https://${ip}/api/v0/system_information" | jq -r .ready 2>/dev/null)" == "true" ]]
}

export_on_host() {
  local ip="$1" stamp="$2" key="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ssh -p 1122 sysadmin@${ip} bash -s -- export-labs /data/exports/${stamp} < ${REMOTE_LIB}"
  else
    ssh -p 1122 -i "${key}" -o StrictHostKeyChecking=accept-new "sysadmin@${ip}" \
      "bash -s -- export-labs /data/exports/${stamp}" < "${REMOTE_LIB}"
  fi
}

pull_local_copy() {
  local ip="$1" stamp="$2" key="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
  mkdir -p "${LOCAL_EXPORTS}"
  run scp -P 1122 -i "${key}" -o StrictHostKeyChecking=accept-new -q -r \
    "sysadmin@${ip}:/data/exports/${stamp}" "${LOCAL_EXPORTS}/${stamp}"
}

push_to_blob() {
  local stamp="$1" sa
  sa="$(tf_out persistent storage_account_name)"
  export AZCOPY_AUTO_LOGIN_TYPE=AZCLI
  export AZCOPY_LOG_LOCATION="${REPO_ROOT}/.azcopy" AZCOPY_JOB_PLAN_LOCATION="${REPO_ROOT}/.azcopy"
  mkdir -p "${AZCOPY_LOG_LOCATION}"
  run azcopy copy "${LOCAL_EXPORTS}/${stamp}" "https://${sa}.blob.core.windows.net/exports/" --recursive
}

main() {
  local ip stamp
  if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
  require_cmd terraform ssh scp azcopy curl jq
  ip="$(cml_ip)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ "${DRY_RUN}" != "1" ]] && ! api_ready "${ip}"; then
    die "CML API at https://${ip} is not ready. Nothing exported."
  fi
  export_on_host "${ip}" "${stamp}"
  pull_local_copy "${ip}" "${stamp}"
  push_to_blob "${stamp}"
  pass "exports in ${LOCAL_EXPORTS}/${stamp} and blob container exports/${stamp}"
  summary_and_exit
}

main "$@"
```

- [ ] **Step 3: Run the tests, commit**

Run: `chmod +x scripts/30-export-labs.sh && bash tests/test_export_dry_run.sh && tests/run.sh`
Expected: all passed.

```bash
git add scripts/30-export-labs.sh tests/stubs/terraform tests/test_export_dry_run.sh
git commit -m "feat: add lab export script with blob copy"
```

---

### Task 16: `40-down.sh`

**Files:**
- Create: `scripts/40-down.sh`
- Create: `tests/test_down_dry_run.sh`

**Interfaces:**
- Consumes: `30-export-labs.sh`, `cml-remote.sh stop-labs`, `license-status`, `deregister`, upstream `/provision/del.sh`, the cloud-cml root.
- Produces: the CML VM, NIC, NSG, and disk attachment destroyed. Persistent and bootstrap untouched. License released, or a refusal.

- [ ] **Step 1: Write the failing test**

`tests/test_down_dry_run.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/40-down.sh"
chmod +x "${REPO_ROOT}/tests/stubs/"*
failures=0
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
line_of() { grep -nF -- "$1" <<<"$2" | head -1 | cut -d: -f1; }

out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" ARM_SUBSCRIPTION_ID=x ASSUME_YES=1 bash "${SCRIPT}" --dry-run 2>&1)"
assert_contains "export first" "30-export-labs.sh --dry-run" "${out}"
assert_contains "stop labs" "bash -s -- stop-labs" "${out}"
assert_contains "deregister via del.sh" "/provision/del.sh" "${out}"
assert_contains "destroy cml root" "+ terraform -chdir=${REPO_ROOT}/vendor/cloud-cml destroy" "${out}"
a="$(line_of "30-export-labs.sh" "${out}")"; b="$(line_of "stop-labs" "${out}")"; c="$(line_of "/provision/del.sh" "${out}")"; d="$(line_of "vendor/cloud-cml destroy" "${out}")"
if [[ "${a}" -lt "${b}" && "${b}" -lt "${c}" && "${c}" -lt "${d}" ]]; then echo "[OK]    order export < stop < deregister < destroy"; else
  echo "[FAIL]  order: ${a} ${b} ${c} ${d}"; failures=$((failures + 1)); fi

# The script must never be able to destroy the other roots.
if grep -qE 'chdir=[^ ]*(persistent|bootstrap)[^ ]* +destroy' "${SCRIPT}"; then
  echo "[FAIL]  script references destroy on persistent or bootstrap"; failures=$((failures + 1))
else
  echo "[OK]    no destroy on persistent or bootstrap"
fi

if [[ "${failures}" -gt 0 ]]; then echo "test_down_dry_run: ${failures} failure(s)"; exit 1; fi
echo "test_down_dry_run: all passed"
```

Run: `bash tests/test_down_dry_run.sh`. Expected: fails, script missing.

- [ ] **Step 2: Write `scripts/40-down.sh`**

```bash
#!/usr/bin/env bash
# Tear down the CML VM only. Persistent and bootstrap are never touched.
#
#   scripts/40-down.sh [--dry-run] [--force-license]
#
# 1. scripts/30-export-labs.sh (refuses if the API is down)
# 2. Stop every lab
# 3. /provision/del.sh on the host, then verify NOT_REGISTERED; retry with
#    cml-remote.sh deregister. A stranded Smart License blocks the next
#    build, so a failure here stops the teardown unless --force-license.
# 4. terraform destroy in vendor/cloud-cml
#
# --dry-run prints the sequence. Prompts unless ASSUME_YES=1.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REMOTE_LIB="${REPO_ROOT}/scripts/lib/cml-remote.sh"
CLOUD_CML="${REPO_ROOT}/vendor/cloud-cml"
CML_YML="${REPO_ROOT}/config/cml.yml"
DRY_RUN=0
FORCE_LICENSE=0

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

remote() {
  local ip="$1"; shift
  local key="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ssh -p 1122 sysadmin@${ip} bash -s -- $* < ${REMOTE_LIB}"
  else
    ssh -p 1122 -i "${key}" -o StrictHostKeyChecking=accept-new "sysadmin@${ip}" "bash -s -- $*" < "${REMOTE_LIB}"
  fi
}

export_labs() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ${REPO_ROOT}/scripts/30-export-labs.sh --dry-run"
  else
    "${REPO_ROOT}/scripts/30-export-labs.sh" || die "export failed, not destroying. Fix the export or run 30-export-labs.sh by hand."
  fi
}

release_license() {
  local ip="$1" status
  run cml_ssh /provision/del.sh || true
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  status="$(remote "${ip}" license-status || echo UNKNOWN)"
  if [[ "${status}" == "REGISTERED" ]]; then
    warn "del.sh left the license REGISTERED, retrying through the API"
    status="$(remote "${ip}" deregister || echo REGISTERED)"
  fi
  if [[ "${status}" == "REGISTERED" ]]; then
    if [[ "${FORCE_LICENSE}" == "1" ]]; then
      warn "license still REGISTERED, continuing because of --force-license. Release it in Smart Software Manager."
    else
      die "license still REGISTERED. Fix it, or rerun with --force-license and release it in Smart Software Manager."
    fi
  else
    pass "license ${status}"
  fi
}

destroy_cml() {
  local tenant
  tenant="$(az account show --query tenantId -o tsv)"
  export TF_VAR_cfg_file="${CML_YML}"
  export TF_VAR_azure_subscription_id="${ARM_SUBSCRIPTION_ID}"
  export TF_VAR_azure_tenant_id="${tenant}"
  confirm "Destroy the CML VM (vendor/cloud-cml root only)?" || die "declined"
  run terraform -chdir="${CLOUD_CML}" destroy -input=false -auto-approve
}

main() {
  local ip arg
  for arg in "$@"; do
    case "${arg}" in
      --dry-run) DRY_RUN=1 ;;
      --force-license) FORCE_LICENSE=1 ;;
      *) die "usage: 40-down.sh [--dry-run] [--force-license]" ;;
    esac
  done
  require_env ARM_SUBSCRIPTION_ID
  require_cmd terraform az ssh
  ip="$(cml_ip)"
  export_labs
  remote "${ip}" stop-labs
  release_license "${ip}"
  destroy_cml
  pass "CML VM destroyed. Persistent resources untouched. Next build: scripts/20-up.sh"
  summary_and_exit
}

main "$@"
```

- [ ] **Step 3: Run the tests, commit**

Run: `chmod +x scripts/40-down.sh && bash tests/test_down_dry_run.sh && tests/run.sh`
Expected: all passed.

```bash
git add scripts/40-down.sh tests/test_down_dry_run.sh
git commit -m "feat: add 40-down.sh with license release gate"
```

---

### Task 17: `50-tunnels.sh`

**Files:**
- Create: `scripts/50-tunnels.sh`
- Create: `config/tunnels.conf.example`
- Create: `tests/test_tunnels.sh`

**Interfaces:**
- Consumes: `config/tunnels.conf` (or `TUNNELS_CONF`), lines `name local_port remote_host remote_port`; `cml_ip`; `keys/cml-lab`.
- Produces: background `ssh -N -L` processes with pid and log files in `.cml-tunnels/`. Subcommands `up`, `down`, `status`.

- [ ] **Step 1: Write the example config and the failing test**

`config/tunnels.conf.example`:
```text
# name  local_port  remote_host   remote_port
# Copy to config/tunnels.conf (gitignored). One forward per line, through
# the CML host on SSH 1122. Cockpit is reachable directly, this is an
# example. The ISE and FTD spec adds their entries.
cockpit 9090 127.0.0.1 9090
```

`tests/test_tunnels.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/50-tunnels.sh"
TMP="$(mktemp -d "${REPO_ROOT}/tests/.tmp.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
chmod +x "${REPO_ROOT}/tests/stubs/"*
failures=0
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

printf 'cockpit 19090 127.0.0.1 9090\nise 18443 10.20.2.10 443\n' > "${TMP}/tunnels.conf"
common="TUNNELS_CONF=${TMP}/tunnels.conf STATE_DIR=${TMP}/state"

out="$(env ${common} bash "${SCRIPT}" status 2>&1)"
assert_contains "status lists cockpit down" "cockpit: DOWN (localhost:19090)" "${out}"
assert_contains "status lists ise down" "ise: DOWN (localhost:18443)" "${out}"

rc=0; env ${common} bash "${SCRIPT}" bogus >/dev/null 2>&1 || rc=$?
assert_eq "bad usage exits 1" "1" "${rc}"

out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" env ${common} bash "${SCRIPT}" up --dry-run 2>&1)"
assert_contains "up plans the forward" "+ ssh -p 1122 -N -L 18443:10.20.2.10:443" "${out}"

rc=0; env TUNNELS_CONF="${TMP}/missing.conf" STATE_DIR="${TMP}/state" bash "${SCRIPT}" status >/dev/null 2>&1 || rc=$?
assert_eq "missing conf exits 1" "1" "${rc}"

if [[ "${failures}" -gt 0 ]]; then echo "test_tunnels: ${failures} failure(s)"; exit 1; fi
echo "test_tunnels: all passed"
```

Run: `bash tests/test_tunnels.sh`. Expected: fails, script missing.

- [ ] **Step 2: Write `scripts/50-tunnels.sh`**

```bash
#!/usr/bin/env bash
# SSH port forwards through the CML host, detached with pid files.
#
#   scripts/50-tunnels.sh up [--dry-run] | down | status
#
# Forwards come from config/tunnels.conf: "name local_port remote_host
# remote_port". Each runs as its own ssh -N -L on port 1122. State lives in
# .cml-tunnels/ inside the repo (pid and log per tunnel). "up" is idempotent:
# a tunnel that already listens is left alone. Refuses "up" when the host
# does not answer on 1122.
#
# Overrides: TUNNELS_CONF, STATE_DIR.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

TUNNELS_CONF="${TUNNELS_CONF:-${REPO_ROOT}/config/tunnels.conf}"
STATE_DIR="${STATE_DIR:-${REPO_ROOT}/.cml-tunnels}"
KEY_FILE="${CML_SSH_KEY:-${REPO_ROOT}/keys/cml-lab}"
DRY_RUN=0

run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ $*"
  else
    "$@"
  fi
}

port_listening() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

require_conf() {
  [[ -f "${TUNNELS_CONF}" ]] || die "${TUNNELS_CONF} missing. Copy config/tunnels.conf.example."
}

each_tunnel() {
  # Calls "$1 name local_port remote_host remote_port" per config line.
  local callback="$1" name lport rhost rport
  while read -r name lport rhost rport; do
    [[ -z "${name}" || "${name}" == \#* ]] && continue
    "${callback}" "${name}" "${lport}" "${rhost}" "${rport}"
  done < "${TUNNELS_CONF}"
}

host_reachable() {
  local ip="$1"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi
  nc -z -w 5 "${ip}" 1122 >/dev/null 2>&1
}

start_one() {
  local name="$1" lport="$2" rhost="$3" rport="$4" ip="${CML_HOST_IP}" tries
  if port_listening "${lport}"; then
    echo "${name}: already listening on ${lport}"
    return 0
  fi
  mkdir -p "${STATE_DIR}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "+ ssh -p 1122 -N -L ${lport}:${rhost}:${rport} sysadmin@${ip}"
    return 0
  fi
  nohup ssh -p 1122 -i "${KEY_FILE}" -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes \
    -N -L "${lport}:${rhost}:${rport}" "sysadmin@${ip}" >> "${STATE_DIR}/${name}.log" 2>&1 &
  echo "$!" > "${STATE_DIR}/${name}.pid"
  for tries in 1 2 3 4 5 6 7 8 9 10; do
    if port_listening "${lport}"; then
      echo "${name}: up on localhost:${lport} -> ${rhost}:${rport}"
      return 0
    fi
    sleep 1
  done
  echo "${name}: did not come up, see ${STATE_DIR}/${name}.log" >&2
  return 1
}

stop_one() {
  local name="$1" lport="$2" pid_file="${STATE_DIR}/$1.pid" holder
  if [[ -f "${pid_file}" ]]; then
    kill "$(cat "${pid_file}")" 2>/dev/null || true
    rm -f "${pid_file}"
  fi
  holder="$(lsof -nP -tiTCP:"${lport}" -sTCP:LISTEN 2>/dev/null || true)"
  if [[ -n "${holder}" ]]; then
    kill "${holder}" 2>/dev/null || true
  fi
  echo "${name}: stopped"
}

status_one() {
  local name="$1" lport="$2" rhost="$3" rport="$4"
  if port_listening "${lport}"; then
    echo "${name}: up (localhost:${lport} -> ${rhost}:${rport})"
  else
    echo "${name}: DOWN (localhost:${lport})"
  fi
}

main() {
  local cmd="${1:-}"
  if [[ "${2:-}" == "--dry-run" ]]; then
    DRY_RUN=1
  fi
  require_conf
  case "${cmd}" in
    up)
      CML_HOST_IP="$(cml_ip)"
      host_reachable "${CML_HOST_IP}" || die "CML host ${CML_HOST_IP} not reachable on 1122"
      each_tunnel start_one
      ;;
    down) each_tunnel stop_one ;;
    status) each_tunnel status_one ;;
    *) echo "usage: $0 up [--dry-run]|down|status" >&2; exit 1 ;;
  esac
}

main "$@"
```

- [ ] **Step 3: Run the tests, commit**

Run: `chmod +x scripts/50-tunnels.sh && bash tests/test_tunnels.sh && tests/run.sh`
Expected: all passed.

```bash
git add scripts/50-tunnels.sh config/tunnels.conf.example tests/test_tunnels.sh
git commit -m "feat: add SSH tunnel manager with in-repo state"
```

---

### Task 18: `90-smoke-test.sh`

**Files:**
- Create: `scripts/90-smoke-test.sh`
- Create: `tests/test_smoke.sh`

**Interfaces:**
- Consumes: persistent outputs, cloud-cml output `cml2info`, `cml_ssh`, `cml-remote.sh license-status`, `az vm show`, `mcp_call.py` with `scripts/mcp-cml.sh`.
- Produces: pass or fail per spec check, exit 1 on any fail.

- [ ] **Step 1: Write the failing test**

`tests/test_smoke.sh`:
```bash
#!/usr/bin/env bash
# The smoke test needs a live host. Here we only prove it fails cleanly when
# there is no state, and that it never crashes past the first check.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_ROOT}/scripts/90-smoke-test.sh"
chmod +x "${REPO_ROOT}/tests/stubs/"*
failures=0
assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if grep -qF -- "${needle}" <<<"${haystack}"; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: missing '${needle}'"; failures=$((failures + 1)); fi
}
assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then echo "[OK]    ${label}"; else
    echo "[FAIL]  ${label}: expected '${expected}' got '${actual}'"; failures=$((failures + 1)); fi
}

rc=0; out="$(PATH="${REPO_ROOT}/tests/stubs:${PATH}" TF_STUB_FAIL=1 bash "${SCRIPT}" 2>&1)" || rc=$?
assert_eq "no state exits 1" "1" "${rc}"
assert_contains "explains" "persistent output public_ip_address" "${out}"
assert_contains "summary printed" "summary:" "${out}"

if [[ "${failures}" -gt 0 ]]; then echo "test_smoke: ${failures} failure(s)"; exit 1; fi
echo "test_smoke: all passed"
```

Run: `bash tests/test_smoke.sh`. Expected: fails, script missing.

- [ ] **Step 2: Write `scripts/90-smoke-test.sh`**

```bash
#!/usr/bin/env bash
# Post-build checks, read-only. Run after scripts/20-up.sh.
#
#   1. persistent output public_ip_address readable
#   2. CML API answers and reports ready
#   3. cloud-cml output address equals the persistent public IP
#   4. License registered
#   5. /data mounted on the host
#   6. /data/images populated and bind-mounted on /var/lib/libvirt/images
#   7. Data disk attached at LUN 0 (az)
#   8. cml-mcp on the Mac lists labs through scripts/mcp-cml.sh
#
# Exit 1 on any FAIL. Overrides: none needed; CML_SSH_KEY for the key path.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

REMOTE_LIB="${REPO_ROOT}/scripts/lib/cml-remote.sh"
CLOUD_CML="${REPO_ROOT}/vendor/cloud-cml"

check_outputs() {
  if ! IP="$(cml_ip 2>/dev/null)" || [[ -z "${IP}" ]]; then
    miss "persistent output public_ip_address unreadable. Has 20-up.sh run?"
    summary_and_exit
  fi
  pass "public IP ${IP}"
}

check_api() {
  local ready
  ready="$(curl -sk -m 10 "https://${IP}/api/v0/system_information" | jq -r .ready 2>/dev/null || true)"
  if [[ "${ready}" == "true" ]]; then
    pass "CML API ready at https://${IP}"
  else
    miss "CML API at https://${IP} not ready (got '${ready:-no answer}')"
  fi
}

check_ip_matches() {
  local addr
  addr="$(terraform -chdir="${CLOUD_CML}" output -json cml2info 2>/dev/null | jq -r .address 2>/dev/null || true)"
  if [[ "${addr}" == "${IP}" ]]; then
    pass "cloud-cml address matches persistent public IP"
  else
    miss "cloud-cml address '${addr}' differs from persistent public IP ${IP}"
  fi
}

check_license() {
  local status
  status="$(cml_ssh "bash -s -- license-status" < "${REMOTE_LIB}" 2>/dev/null || echo UNREACHABLE)"
  if [[ "${status}" == "REGISTERED" ]]; then
    pass "license REGISTERED"
  else
    miss "license status '${status}'"
  fi
}

check_data_disk_on_host() {
  local mounted bound count
  mounted="$(cml_ssh "findmnt -n -o SOURCE /data" 2>/dev/null || true)"
  if [[ -n "${mounted}" ]]; then
    pass "/data mounted from ${mounted}"
  else
    miss "/data not mounted. See /var/log/provision/05-persist-pre.log on the host"
  fi
  bound="$(cml_ssh "findmnt -n -o TARGET --target /var/lib/libvirt/images" 2>/dev/null || true)"
  if [[ "${bound}" == "/var/lib/libvirt/images" ]]; then
    pass "/var/lib/libvirt/images is a bind mount"
  else
    miss "/var/lib/libvirt/images is not a bind mount (findmnt says '${bound}')"
  fi
  count="$(cml_ssh "find /data/images -type f 2>/dev/null | wc -l" 2>/dev/null | tr -d ' ' || echo 0)"
  if [[ "${count:-0}" -gt 0 ]]; then
    pass "/data/images holds ${count} files"
  else
    miss "/data/images is empty"
  fi
}

check_lun0() {
  local rg name
  rg="$(tf_out persistent resource_group_name)"
  name="$(az vm show -g "${rg}" -n cml-controller --query "storageProfile.dataDisks[?lun==\`0\`].name | [0]" -o tsv 2>/dev/null || true)"
  if [[ "${name}" == "disk-cml-lab-data" ]]; then
    pass "data disk disk-cml-lab-data at LUN 0"
  else
    miss "LUN 0 holds '${name:-nothing}', expected disk-cml-lab-data"
  fi
}

check_mcp() {
  local out
  if out="$(python3 "${REPO_ROOT}/scripts/lib/mcp_call.py" --cmd "bash ${REPO_ROOT}/scripts/mcp-cml.sh" --tool get_cml_labs 2>&1)"; then
    pass "cml-mcp get_cml_labs answered ($(echo "${out}" | wc -c | tr -d ' ') bytes)"
  else
    miss "cml-mcp failed: $(echo "${out}" | tail -1)"
  fi
}

main() {
  require_cmd terraform az curl jq ssh python3 uvx
  check_outputs
  check_api
  check_ip_matches
  check_license
  check_data_disk_on_host
  check_lun0
  check_mcp
  summary_and_exit
}

main "$@"
```

- [ ] **Step 3: Run the tests, commit**

Run: `chmod +x scripts/90-smoke-test.sh && bash tests/test_smoke.sh && tests/run.sh && pre-commit run --all-files`
Expected: all passed.

```bash
git add scripts/90-smoke-test.sh tests/test_smoke.sh
git commit -m "feat: add post-build smoke test"
```

---

### Task 19: Architecture decision records

**Files:**
- Create: `docs/decisions/0001-consume-cloud-cml-as-fork-submodule.md`
- Create: `docs/decisions/0002-three-terraform-roots-by-lifetime.md`
- Create: `docs/decisions/0003-routed-lab-connectivity.md`
- Create: `docs/decisions/0004-secrets-via-random-password-and-tfvars.md`

**Interfaces:**
- Consumes: spec section 2 and the design notes.
- Produces: the four files every code comment cites. Shape: Status, Context, Decision, Consequences, Options considered.

- [ ] **Step 1: Check the gate**

Run: `ls docs/decisions/ 2>/dev/null | wc -l`. Expected: `0` or a missing-directory error.

- [ ] **Step 2: Write `0001-consume-cloud-cml-as-fork-submodule.md`**

```markdown
# 0001: Consume cloud-cml as a fork pinned as a git submodule

Status: accepted, 2026-09-02

## Context

CiscoDevNet/cloud-cml is the supported way to run CML in Azure. Its Azure
module creates its own VNet, subnet, and public IP, uses a Standard_LRS OS
disk, has no data disk, no spot support, no IP forwarding, and a one hour
SAS window for the image copy. Every one of those needs to change for an
on-demand lab with persistence and routed connectivity. Upstream moves,
and we want its fixes for new CML releases.

## Decision

Fork cloud-cml on GitHub, keep every change on a branch named `azure-lab`
as one small commit per concern, and pin the fork into this repo as a git
submodule at `vendor/cloud-cml`. New behaviour is driven by keys under
`azure:` in the config file, read with `try()` where a default exists, so
upstream's own config still validates. The AWS path is not touched.

Upstream updates: `git fetch upstream && git merge <tag>` on the fork,
resolve conflicts patch by patch, push, then bump the submodule pointer
here. The tooling merge always precedes a CML software rebuild.

## Consequences

- Patches stay reviewable and mergeable because each is a few lines with a
  comment naming this ADR.
- The module keeps upstream's structure: it does its own data-source lookups
  rather than receiving IDs. Accepted deviation from terraform-patterns to
  keep merges small.
- Anything that lands under `vendor/` requires a human, per CLAUDE.md.
- The fork is public. It carries no secrets by construction.

## Options considered

1. **Use upstream unchanged and wrap it.** Cannot work: the module creates
   the VNet and public IP itself, and the persistence hook needs a file in
   its provisioning data directory.
2. **Vendor a copy of the module into this repo.** Loses the upstream
   history; merging a new CML release becomes a manual diff exercise.
3. **Fork plus submodule.** Chosen. Small diff, upstream history kept,
   explicit pin.
```

- [ ] **Step 3: Write `0002-three-terraform-roots-by-lifetime.md`**

```markdown
# 0002: Three Terraform roots split by lifetime

Status: accepted, 2026-09-02

## Context

The CML VM is rebuilt per session. The refplat images, the lab exports, the
static public IP, the SSH key, the VNet, and the Terraform state itself must
not be rebuilt. One root with `prevent_destroy` on the precious resources is
tempting but a single `terraform destroy` still tries, and a state mishap
takes everything with it.

## Decision

Three roots, each with the lifetime of what it holds:

| Root | State | Holds | Destroyed |
|---|---|---|---|
| `terraform/bootstrap` | local | `rg-cml-lab-tfstate`, the state storage account | never |
| `terraform/persistent` | blob, in the bootstrap account | everything under `rg-cml-lab` that survives | never |
| `vendor/cloud-cml` | local, inside the submodule | the CML VM, NIC, NSG, disk attachment | every session |

Region `eastus2`, subscription from `ARM_SUBSCRIPTION_ID`, never committed.
`prevent_destroy` on the state storage account and the data disk. No script
in this repo runs destroy against the first two roots.

## Consequences

- `scripts/40-down.sh` can only ever destroy the CML root.
- The bootstrap root's local state file is the one precious local file. It
  holds a random suffix and nothing secret; back it up by keeping the repo
  folder intact.
- Two applies run before the CML build on a clean subscription, which
  `scripts/20-up.sh` sequences.
- The 512 GB Premium disk bills from creation regardless of the VM, about
  75 USD a month. It is the price of not copying 30 GB of images per build.

## Options considered

1. **One root.** Rejected: destroy semantics are all or nothing.
2. **Two roots, persistent plus CML.** Rejected: the persistent root needs
   remote state, and something has to create that storage first.
3. **Three roots.** Chosen.
```

- [ ] **Step 4: Write `0003-routed-lab-connectivity.md`**

```markdown
# 0003: Routed connectivity between lab nodes and the VNet, no NAT

Status: accepted, 2026-09-02

## Context

ISE and FTD will run as Azure VMs in the same VNet as the CML host. TrustSec
needs ISE to see each switch at its own address and to send Change of
Authorization back to it. Through NAT every switch looks like the CML host
and CoA has no return path. Bridging is impossible: the Azure fabric only
delivers frames to the IP and MAC pairs registered on a NIC.

## Decision

The CML host is a layer 3 hop. Lab nodes sit on a transit network on a
local bridge on the host, `10.100.0.0/24`, host at `10.100.0.1`. A C8000v
lab edge at `10.100.0.2` routes the rest of `10.100.0.0/16`. In Azure:

- The CML NIC has IP forwarding on and a static private IP, `10.20.1.10`.
- A route table on the apps subnet sends `10.100.0.0/16` to `10.20.1.10`
  as a virtual appliance next hop. Azure's fabric, not the guest routing
  table, makes this decision, so it must be a UDR.
- An NSG rule on the CML NIC allows the apps subnet to the lab summary on
  any port.

Claude Code runs on the Mac only and reaches the controller API on the
static public IP through cml-mcp. Reaching ISE and FTD is by SSH forwards
through the CML host on port 1122, which doubles as the jump host.

This spec reserves the addresses and creates the route and NSG rule. The
bridge, the sysctl, and the C8000v are lab content for the TrustSec spec.

## Consequences

- No NAT anywhere in the path. CoA works, per-device identity works.
- Inline SGT tagging cannot cross the VNet. External FTD enforces on
  SGT-to-IP mappings from ISE via pxGrid or SXP, which is the normal cloud
  firewall pattern.
- The public IP is a persistent resource so the MCP config never changes.
- Port 1122 is the host shell on a CML machine, 22 is the console server.
  Every script uses 1122.

## Options considered

1. **NAT mode, upstream default.** Rejected: breaks CoA and per-device identity.
2. **Bridge mode.** Rejected: Azure does not deliver frames to unknown MACs.
3. **Routed with a UDR.** Chosen. Two routes total, one in Azure, one on the host.
4. **Overlay tunnel, C8000v to C8000v.** Kept as a documented fallback.
```

- [ ] **Step 5: Write `0004-secrets-via-random-password-and-tfvars.md`**

```markdown
# 0004: Secrets from random_password and a gitignored tfvars file

Status: accepted, 2026-09-02

## Context

Three secrets exist: the CML admin password, the sysadmin password, and
the Smart License token. cloud-cml supports Vault, Conjur, or a dummy
manager that takes raw values from its config file. This is a one-person
lab; the cost of a secret store is real and the benefit is small.

## Decision

- The two passwords are `random_password` resources in the persistent root,
  16 characters, no specials, so they match cloud-cml's dummy manager and
  need no YAML escaping. They live in blob state and are read back with
  `terraform output -raw`.
- The license token lives only in `config/cml.tfvars`, gitignored.
- `scripts/20-up.sh` renders both into `config/cml.yml`, gitignored, mode
  600, with a Python step. Terraform never sees this repo's files.
- cml-mcp credentials are written to `config/mcp-env/cml.env`, in a
  self-ignoring directory, and read by `scripts/mcp-cml.sh`.
- gitleaks runs in pre-commit with custom rules for the token and for
  Azure storage keys.

## Consequences

- The blob state container holds the passwords. It is private, Azure AD
  authenticated, versioned, and soft deleted. Acceptable for a lab.
- Rotating a password means tainting the resource and rebuilding the CML
  VM, since cloud-cml sets it at install time.
- A stranded token is the main risk; `scripts/40-down.sh` refuses to
  destroy while the license is registered.

## Options considered

1. **Azure Key Vault.** Rejected for now: more resources, RBAC, and a
   provider dependency for three values. Revisit if a second person joins.
2. **HashiCorp Vault or Conjur via cloud-cml.** Rejected: nothing to run it on.
3. **random_password plus gitignored tfvars.** Chosen.
```

- [ ] **Step 6: Run the gate, commit**

Run: `pre-commit run --all-files`. Expected: passes (gitleaks allowlists `docs/`).

```bash
git add docs/decisions/
git commit -m "docs: add ADRs 0001 to 0004"
```

---

### Task 20: Status, lessons, README, and prerequisites sync

**Files:**
- Create: `docs/STATUS.md`
- Create: `docs/LESSONS-LEARNED.md`
- Modify: `README.md` (expand)
- Modify: `docs/PREREQUISITES.md` (section 5 now reflects what exists)

**Interfaces:**
- Consumes: everything built in Tasks 1 to 19.
- Produces: the handoff a fresh session reads first.

- [ ] **Step 1: Write `docs/STATUS.md`**

```markdown
# Status

Dated handoff. Newest entry first. Read this before doing anything.

## 2026-09-DD (fill in the date this task runs)

### Where things stand

Repo skeleton, both durable Terraform roots, the fork with ten patches, and
all six operator scripts exist and pass `tests/run.sh` and pre-commit.
Bootstrap has been applied (Task 5). Persistent has been planned, not
applied. No CML VM has ever been built from this repo.

### Done

- CLAUDE.md, settings allowlist, pre-commit, gitleaks with custom rules
- `terraform/bootstrap` applied, `terraform/persistent` validated and planned
- Fork `itsAmeMario0o/cloud-cml` branch `azure-lab`, patches 0 to 10, pinned
- Scripts 00, 10, 20, 30, 40, 50, 90 with dry-run tests
- ADRs 0001 to 0004

### Deferred on purpose

- Persistent apply: waits for images and quota, because the disk bills from creation
- The first real CML build and the seven verification steps (plan Task 21)
- Lab topologies, ISE, FTD, the host bridge and C8000v edge: later specs

### Watch out for

- Quota in eastus2 for Edsv5 was 0 on 2026-09-02. Preflight fails until the request is approved.
- `config/refplat.txt` names images from the June 2025 ISO. Update from the newer ISO before uploading.
- azurerm is pinned to 4.x in all three roots. Do not let init pick 5.x.

### Next

1. Human: license, token, downloads into `software/`, quota, `ARM_SUBSCRIPTION_ID`.
2. `scripts/00-preflight.sh` until green except blobs.
3. `scripts/20-up.sh` through the persistent apply, then `scripts/10-upload-images.sh`.
4. `scripts/00-preflight.sh` fully green, then `scripts/20-up.sh` to the CML build.
5. Plan Task 21.
```

- [ ] **Step 2: Write `docs/LESSONS-LEARNED.md`**

```markdown
# Lessons learned

Symptom, cause, fix. Add an entry the moment something bites, before the
fix is forgotten. Entries from the design phase are here so they are not
learned twice.

## SSH to the CML host on port 22 gives a console menu, not a shell

- Symptom: `ssh sysadmin@host` connects but shows the CML console server.
- Cause: on a CML host, port 22 is the breakout console server. The system
  shell listens on 1122.
- Fix: every script uses `-p 1122`. cloud-cml's own `del.sh` hint says so.

## Image copy fails partway with an authentication error

- Symptom: cloud-init log shows azcopy 403 midway through the refplat copy.
- Cause: the SAS token cloud-cml builds at plan time expires. Upstream gives
  one hour.
- Fix: fork patch 6, `azure.sas_validity`, default 4h. Preflight estimates
  the copy time and warns. Keep `config/refplat.txt` small.

## A large file in the repo folder becomes unreadable

- Symptom: `hdiutil attach` or `azcopy` fails on the ISO with a short read.
- Cause: the repo lives under OneDrive, which can replace a synced file with
  an on-demand placeholder.
- Fix: right-click the file in Finder, choose "Always Keep on This Device".
  `software/README.md` says the same.

## terraform init selects azurerm 5.x and validate breaks

- Symptom: unknown argument errors in the fork or a root after a fresh init.
- Cause: upstream's `>= 3.82.0` bound. azurerm 5.0 shipped in 2026.
- Fix: `~> 4.0` in all three roots (fork patch 0). Root lock files are committed.

## First boot copies every image again even though /data has them

- Symptom: second build takes as long as the first.
- Cause: a symlinked images directory looks empty to `find` in cml.sh, and
  the disk attachment races cloud-init.
- Fix: `05-persist.sh pre` waits for LUN 0, bind-mounts, and empties the
  image list. See plan deviations 1 to 3.
```

- [ ] **Step 3: Expand `README.md`**

Replace the file with:

```markdown
# cml-phoenix

An on-demand Cisco Modeling Labs instance in Azure that is built and
destroyed per session. Reference platform images and lab exports survive on
a persistent data disk and blob storage, so a rebuild costs minutes.

## How it fits together

Three Terraform roots by lifetime: bootstrap (state storage, never
destroyed), persistent (network, static IP, 512 GB data disk, blob
containers, never destroyed), and the CML VM itself from a lightly patched
fork of [CiscoDevNet/cloud-cml](https://github.com/CiscoDevNet/cloud-cml),
destroyed at the end of every session. Bash scripts on the Mac sequence the
three and talk to the host over SSH. Claude Code drives the controller
through [cml-mcp](https://github.com/xorrkaz/cml-mcp).

## Daily use

    scripts/00-preflight.sh      # green before anything else
    scripts/20-up.sh             # build, prompts before each apply
    scripts/90-smoke-test.sh     # prove it
    ...work...
    scripts/40-down.sh           # export labs, release license, destroy VM

## Read next

- `docs/PREREQUISITES.md`: what only you can provide
- `docs/STATUS.md`: where things stand today
- `CLAUDE.md`: rules for working in this repo
- `docs/superpowers/specs/`: the design
- `docs/decisions/`: why it is built this way
```

- [ ] **Step 4: Sync `docs/PREREQUISITES.md` section 5**

Replace the body of section 5 with the current truth: the repo is built, bootstrap applied, persistent held, and the CML build waits on sections 1 and 2. Keep the checklist in section 6.

- [ ] **Step 5: Run the full gate and commit**

```bash
tests/run.sh && pre-commit run --all-files
git add docs/STATUS.md docs/LESSONS-LEARNED.md README.md docs/PREREQUISITES.md
git commit -m "docs: add status handoff, lessons learned, expand README"
git push
```

---

### Task 21: Live verification, the seven spec steps

Gated on `docs/PREREQUISITES.md` sections 1 and 2 being complete. Every apply prompts. A human is present for this task. Anything that bites goes into `docs/LESSONS-LEARNED.md` before the task is marked done.

**Files:**
- Modify: `docs/STATUS.md`, `docs/LESSONS-LEARNED.md`

- [ ] **Step 1: Spec step 1, preflight passes**

```bash
export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
scripts/00-preflight.sh
```
Expected: 0 FAIL. Blob checks WARN until step 3 below.

- [ ] **Step 2: Persistent apply and image upload**

```bash
scripts/20-up.sh       # answer y to bootstrap (already applied, skipped) and persistent; answer n at the CML prompt
scripts/10-upload-images.sh --dry-run
scripts/10-upload-images.sh
scripts/00-preflight.sh
```
Expected: persistent apply 19 added. Upload completes. Preflight fully green and writes `.preflight-ok`.

- [ ] **Step 3: Spec step 2, full build**

```bash
scripts/20-up.sh
```
Expected: CML apply completes in 15 to 30 minutes; the readiness module waits for the API. The script prints the URL, IP, and del.sh command, and writes `config/mcp-env/cml.env`.

- [ ] **Step 4: Spec step 3, smoke test and cml-mcp**

```bash
curl -sk https://IP/api/v0/licensing | jq .registration.status
scripts/90-smoke-test.sh
```
Record the raw `registration.status` value in `docs/LESSONS-LEARNED.md` (see
"License registration status string is unverified"), then run the smoke
test. Expected: 0 FAIL, including `cml-mcp get_cml_labs answered`. In Claude
Code, `/mcp` shows server `cml` connected.

- [ ] **Step 5: Spec step 4, a throwaway lab exported**

Create a lab with two alpine nodes through cml-mcp (`create_empty_lab`, `add_node_to_cml_lab`) or the UI. Then:

```bash
scripts/30-export-labs.sh
ls exports/*/
az storage blob list --auth-mode login --account-name "$(terraform -chdir=terraform/persistent output -raw storage_account_name)" -c exports -o table
```
Expected: one YAML per lab locally and in the container.

- [ ] **Step 6: Spec step 5, down with license released**

```bash
scripts/40-down.sh
az vm list -g rg-cml-lab -o table
az disk show -g rg-cml-lab -n disk-cml-lab-data --query diskState -o tsv
```
Expected: no VM listed, disk state `Unattached`, script reported the license `NOT_REGISTERED`.

- [ ] **Step 7: Spec step 6, second build reuses images**

```bash
scripts/00-preflight.sh && scripts/20-up.sh
ssh -p 1122 -i keys/cml-lab sysadmin@"$(terraform -chdir=terraform/persistent output -raw public_ip_address)" cat /var/log/provision/05-persist-pre.log
scripts/90-smoke-test.sh
```
Expected: the pre log says `reusing N image files` and `partition already formatted as ext4`. Build time noticeably shorter. Reimport one exported YAML through cml-mcp `create_full_lab_topology` and start it.

- [ ] **Step 8: Spec step 7, persistent shows zero diff**

```bash
terraform -chdir=terraform/persistent plan -detailed-exitcode; echo "exit $?"
```
Expected: `No changes.` and exit 0. Run this after step 4 and again now.

- [ ] **Step 9: Record and commit**

Update `docs/STATUS.md` with a new dated entry (build times, sizes used, anything deferred) and add every surprise to `docs/LESSONS-LEARNED.md`.

```bash
git add docs/STATUS.md docs/LESSONS-LEARNED.md
git commit -m "docs: record first full build and verification"
git push
```

---

## Self-review notes

Spec coverage, section by section:

- Section 1 success steps 1 to 7: Task 21 steps 1 to 8, with the scripts from Tasks 12 to 18.
- Section 2 decisions: ADRs in Task 19; region and subscription in Tasks 3, 4, and the `ARM_SUBSCRIPTION_ID` checks.
- Section 3.1 tiers and names: Tasks 3 and 4 use the spec names verbatim; the CML tier naming stays upstream's (`cml-nic-<rand>`, `cml-sg-<rand>`).
- Section 3.2 repo layout: file structure table above. Additions beyond the spec, all small: `tests/`, `scripts/lib/`, `scripts/10-upload-images.sh`, `scripts/mcp-cml.sh`, `.mcp.json`, `config/refplat.txt`, `config/tunnels.conf.example`, `exports/`, `keys/.gitignore`.
- Section 4 roots: Tasks 3, 4, 5, 6.
- Section 5 fork changes 1 to 10: Tasks 6, 7, 8. Items 9 and 10 changed shape, see deviations 1 to 3.
- Section 6 config and secrets flow: Task 9 and Task 14.
- Section 7 scripts: Tasks 12 to 18. Refusal conditions implemented as `die` calls with remediation text.
- Section 8 conventions: Task 1 and Task 19.
- Section 9 error handling: `die` with remediation everywhere; `05-persist.sh` exits nonzero and logs; preflight SAS warning; `prevent_destroy` in Tasks 3 and 4; `40-down.sh` license gate.
- Section 10 verification: Task 21.
- Section 11 out of scope: nothing in this plan builds ISE, FTD, the bridge, the edge router, a topology, Key Vault, CI, Bastion, or clusters.

Name consistency checked: `tf_out`, `cml_ip`, `cml_ssh`, `confirm`, `die`, `pass`, `warn`, `miss`, `summary_and_exit` match between Task 2 and every consumer. Persistent output names match between Task 4 outputs, Task 14 `--set` lines, and Task 18. Template placeholder names match between Task 9's template and renderer. `cml-remote.sh` subcommands match between Task 10 and Tasks 15, 16, 18. Fork config keys match between Task 7 and Task 9's template.
