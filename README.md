# cml-phoenix

A Cisco Modeling Labs server in Azure that you build when you need it and
tear down when you are done. The parts that are slow or expensive to
recreate, meaning the reference platform images, the lab exports, and the
static IP, live on a persistent disk and in blob storage that never get
destroyed. A rebuild takes minutes instead of an afternoon, and an idle
month costs you a disk, not a VM.

The name is the point. The VM dies every session and comes back from its
own ashes with everything it needs already on the disk.

## How it fits together

Three Terraform roots, one per lifetime. `terraform/bootstrap` creates the
storage account that holds everyone else's state and is never destroyed.
`terraform/persistent` owns the network, the static public IP, the 512 GB
data disk, and the blob containers, and is never destroyed either. The CML
VM itself comes from a lightly patched fork of
[CiscoDevNet/cloud-cml](https://github.com/CiscoDevNet/cloud-cml) pinned as
a submodule, and that one is destroyed at the end of every session.

Bash scripts on the Mac run the three roots in order and talk to the host
over SSH. Claude Code drives the controller through
[cml-mcp](https://github.com/xorrkaz/cml-mcp).

## Daily use

    scripts/00-preflight.sh      # green before anything else
    scripts/20-up.sh             # build, prompts before each apply
    scripts/90-smoke-test.sh     # prove it
    ...work...
    scripts/40-down.sh           # export labs, release license, destroy VM

Every apply asks first. Nothing in this repo can destroy the first two
roots. That is enforced with `prevent_destroy` and checked by a test, not
just promised in a comment.

## Read next

Start with `docs/PREREQUISITES.md`. It lists what only you can provide: a
license, two downloads, and a quota increase. `docs/STATUS.md` says where
things stand today. `CLAUDE.md` has the rules for working in the repo,
`docs/superpowers/specs/` has the design, and `docs/decisions/` explains
why it is built this way.
