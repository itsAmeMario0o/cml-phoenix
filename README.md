# cml-phoenix

> **Have an account? Read [Getting into the Lab](https://itsamemario0o.github.io/cml-phoenix/) to log in.**
> The same guide is in [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md).

cml-phoenix is an on-demand Cisco Modeling Labs environment on Azure. You
stand it up when you need it and tear it down when you are finished, so an
idle month costs you a disk rather than a running VM.

Everything that is slow or expensive to rebuild, namely the reference
platform images, the lab exports, and the static public IP, lives on a
persistent disk and in blob storage that are never destroyed. A rebuild
therefore takes minutes rather than an afternoon, and the server returns
each session with everything it needs already in place. That is where the
name comes from.

## How it fits together

The design uses three Terraform roots, one for each lifetime. The bootstrap
root (`terraform/bootstrap`) creates the storage account that holds all
other state, and it is never destroyed. The persistent root
(`terraform/persistent`) owns the network, the static public IP, the 512 GB
data disk, and the blob containers, and it is never destroyed either. Only
the CML VM is disposable: it comes from a lightly patched fork of
[CiscoDevNet/cloud-cml](https://github.com/CiscoDevNet/cloud-cml), pinned as
a submodule, and it is torn down at the end of every session.

On the operator side, Bash scripts on the Mac run the three roots in order
and reach the host over SSH, while Claude Code drives the controller through
[cml-mcp](https://github.com/xorrkaz/cml-mcp).

## Daily use

    scripts/00-preflight.sh      # green before anything else
    scripts/20-up.sh             # build, prompts before each apply
    scripts/90-smoke-test.sh     # prove it
    scripts/60-import-lab.sh labs/<scenario>.yaml   # load a topology
    scripts/70-users.sh          # create users from the CSV, grant every lab, passwords to a sheet
    ...work...
    scripts/40-down.sh           # export labs, release license, destroy VM

Every apply prompts for confirmation first, and nothing in this repo can
destroy the first two roots. That guarantee is enforced with
`prevent_destroy` and verified by a test, rather than left to a comment.

## Read next

Begin with `docs/PREREQUISITES.md`, which lists what only you can provide,
chiefly a license and two Cisco downloads, and `docs/STATUS.md`, which
records where the build stands today. For how the project is meant to be
worked in, `CLAUDE.md` holds the working rules, `docs/superpowers/specs/`
holds the design, and `docs/decisions/` explains the reasoning behind each
choice. Two further guides are optional depending on your goal:
`docs/ACCESS.md` covers reaching the web UI by name with a trusted
certificate through a zero trust front door, and `docs/USER-GUIDE.md` is
the page to hand anyone you have given an account. Finally,
`docs/ROADMAP.md` collects what has been agreed but not yet specified.
