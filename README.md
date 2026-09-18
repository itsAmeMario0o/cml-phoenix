# cml-azure-lab

> **Have an account? Read [Getting into the Lab](https://itsamemario0o.github.io/cml-phoenix/) to log in.**
> The same guide is in [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md).

cml-azure-lab is an on-demand Cisco Modeling Labs environment on Azure,
with an Active Directory domain controller and a Cisco ISE beside it. You
stand it up when you need it and tear it down when you are finished, so an
idle month costs you a disk rather than a running VM. The GitHub repository
is named `cml-phoenix`; everything inside it uses this name.

Everything that is slow or expensive to rebuild, namely the reference
platform images, the lab exports, and the static public IP, lives on a
persistent disk and in blob storage that are never destroyed. A CML rebuild
therefore takes minutes rather than an afternoon, and the server returns
each session with everything it needs already in place.

## How it fits together

The design uses four Terraform roots, one for each lifetime. The bootstrap
root (`terraform/bootstrap`) creates the storage account that holds the
persistent state, and it is never destroyed. The persistent root
(`terraform/persistent`) owns the network, the static public IP, the 512 GB
data disk, and the blob containers, and it is never destroyed either. The
other two are disposable: the CML VM comes from a lightly patched fork of
[CiscoDevNet/cloud-cml](https://github.com/CiscoDevNet/cloud-cml), pinned
as a submodule, and the domain controller comes from `terraform/ad` (ADR
0010). Both are torn down at the end of every session. ISE is deployed by
hand through the Azure Marketplace portal (ADR 0008) and deleted by tag.

On the operator side, Bash scripts on the Mac run the roots in order and
reach the hosts over SSH, while Claude Code drives the controller through
[cml-mcp](https://github.com/xorrkaz/cml-mcp).

## Daily use

In build order:

    scripts/00-preflight.sh                 # read-only readiness check
    scripts/10-upload-images.sh --dry-run   # what would be uploaded
    scripts/20-up.sh                        # bootstrap, persistent, CML
    scripts/24-ad-up.sh                     # the domain controller, before ISE
    scripts/25-ise-up.sh --post-deploy      # ISE NSG, tagging, readiness, policy
    scripts/50-tunnels.sh up|down|status    # SSH forwards through the CML host
    scripts/60-import-lab.sh labs/<x>.yaml  # render and import a topology
    scripts/70-users.sh                     # create CML users, grant every lab
    scripts/80-verify-lab.sh <scenario>     # pyATS verification of a running lab
    scripts/90-smoke-test.sh                # post-build checks
    ...work...
    scripts/30-export-labs.sh               # every lab to YAML, to blob
    scripts/40-down.sh                      # export, deregister, destroy CML only
    scripts/45-ise-down.sh                  # delete everything tagged role=ise
    scripts/46-ad-down.sh                   # destroy the domain controller, after ISE

Every apply prompts for confirmation first. The bootstrap and persistent
roots carry `prevent_destroy` on the state storage account and the data
disk, and no script in this repository runs `destroy` against either root.
The test for that (`tests/test_down_dry_run.sh`) only checks that the text
of `40-down.sh` never names those roots next to the word "destroy"; it does
not exercise Terraform.

## Read next

Start with `docs/BUILD-FROM-SCRATCH.md`, the whole build in order from an
empty subscription to CML, the directory, and ISE joined to it. Then
`docs/STATUS.md`, which records where the build stands today, and
`docs/PREREQUISITES.md`, which lists what only you can provide, chiefly a
license and two Cisco downloads. For how the project is meant to be worked
in, `CLAUDE.md` holds the working rules, `docs/specs/` holds
the designs, and `docs/decisions/` explains the reasoning behind each
choice. `docs/ARCHITECTURE-REVIEW.md` is a 2026-09-17 self-audit with an
ordered list of what to fix. Two further guides depend on your goal:
`docs/ACCESS.md` covers reaching the web UI by name with a trusted
certificate through a zero trust front door, and `docs/USER-GUIDE.md` is
the page to hand anyone you have given an account. `docs/ROADMAP.md`
collects what has been agreed but not yet specified.
