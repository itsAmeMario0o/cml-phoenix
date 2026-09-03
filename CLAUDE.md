# cml-azure-lab

A Cisco Modeling Labs server in Azure that is built and destroyed per
session. Whatever must survive a rebuild lives in a separate Terraform root
that is never destroyed. Claude Code runs on the Mac and drives CML through
the cml-mcp server and SSH.

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
