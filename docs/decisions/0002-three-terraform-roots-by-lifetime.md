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
