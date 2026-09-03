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
