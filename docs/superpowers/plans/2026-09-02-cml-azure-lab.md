# cml-azure-lab: repo skeleton and CML tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the repo, the two durable Terraform roots, the cloud-cml fork patches, and the six operator scripts so a CML instance can be built and destroyed per session with its images and lab exports surviving on a persistent data disk.

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
  # The persistent root authenticates to this account with Azure AD
  # (use_azuread_auth in backend.tf), so shared keys are not needed.
  shared_access_key_enabled = false
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
Expected: 20 to add (resource group, random string, storage account, 2 containers, role assignment, SSH key, public IP, managed disk, VNet, 5 subnets, route table, route table association, 2 passwords), 0 to change, 0 to destroy. Do not apply yet: the 512 GB Premium disk bills from creation. `20-up.sh` applies it when the images are ready.

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
