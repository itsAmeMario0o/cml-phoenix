# 0001: Consume cloud-cml as a fork pinned as a git submodule

Status: accepted, 2026-09-02

## Context

CiscoDevNet/cloud-cml is the supported way to run CML in Azure. Its Azure
module creates its own VNet, subnet, and public IP, uses a Standard_LRS OS
disk, has no data disk, no spot support, no IP forwarding, and a one hour
SAS window for the image copy. Every one of those has to change for a lab
that is rebuilt per session and routes to the VNet. At the same time,
upstream keeps moving, and every new CML release lands there first. We want
those fixes without re-deriving our patches each time.

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

1. Use upstream unchanged and wrap it. This cannot work. The module
   creates the VNet and public IP itself, and the persistence hook needs a
   file inside its provisioning data directory.
2. Vendor a copy of the module into this repo. This loses the upstream
   history, so every new CML release becomes a manual diff exercise.
3. Fork plus submodule. Chosen. The diff stays small, the upstream history
   stays intact, and the pin is explicit.
