# cml-phoenix

> **Have an account? Read [Getting into the Lab](https://itsamemario0o.github.io/cml-phoenix/) to log in.**
> The same guide is in [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md).

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
    scripts/60-import-lab.sh labs/<scenario>.yaml   # load a topology
    scripts/70-users.sh          # create users from the CSV, grant every lab, passwords to a sheet
    ...work...
    scripts/40-down.sh           # export labs, release license, destroy VM

Every apply asks first. Nothing in this repo can destroy the first two
roots. That is enforced with `prevent_destroy` and checked by a test, not
just promised in a comment.

## Read next

Start with `docs/PREREQUISITES.md`. It lists what only you can provide,
mostly a license and two Cisco downloads. `docs/STATUS.md` says where
things stand today. `CLAUDE.md` has the rules for working in the repo,
`docs/superpowers/specs/` has the design, and `docs/decisions/` explains
why it is built this way. `docs/ACCESS.md` is optional: a name and a
trusted certificate for the web UI through a zero trust front door.
`docs/USER-GUIDE.md` is the page to hand someone you have given an
account. `docs/ROADMAP.md` lists what is agreed but not yet specified.
