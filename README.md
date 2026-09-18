# cml-azure-lab

> **Have an account? Read [Getting into the Lab](https://itsamemario0o.github.io/cml-phoenix/) to log in.**
> The same guide is in [`docs/USER-GUIDE.md`](docs/USER-GUIDE.md).

cml-azure-lab is a Cisco Modeling Labs server on Azure, with a Windows
domain controller and a Cisco ISE beside it, that you build when you need
it and tear down when you are done. Everything slow or expensive to
rebuild, the node images, the lab exports, and the static public IP, lives
in a Terraform root that is never destroyed, so a rebuild takes minutes.
Bash scripts on a Mac drive the build, and Claude Code drives the
controller through [cml-mcp](https://github.com/xorrkaz/cml-mcp). The
GitHub repository is named `cml-phoenix`.

| Path | What it holds |
|---|---|
| `terraform/bootstrap`, `terraform/persistent` | State storage, network, public IP, data disk, blob. Never destroyed |
| `vendor/cloud-cml` | The CML VM, from a pinned fork of CiscoDevNet/cloud-cml. Rebuilt per session |
| `terraform/ad` | The domain controller `dc1`. Rebuilt per session |
| `scripts/` | The numbered scripts below. ISE is deployed in the Azure portal and finished by `25-ise-up.sh` |
| `labs/`, `verify/` | Lab topologies and their pyATS checks |
| `docs/` | Guides, ADRs, specs, plans, status |

## Build

    scripts/00-preflight.sh
    scripts/20-up.sh                        # first time on a subscription: BUILD-FROM-SCRATCH phases 0 and 1 come first
    # wait a minute: the controller's API is not ready the moment the script ends
    scripts/50-tunnels.sh up                # needs config/tunnels.conf, copied from its .example
    scripts/90-smoke-test.sh                # summary: 13 OK, 0 WARN, 0 FAIL
    # by hand until the spec lands: connector rescan, cloudflared, lab re-import (BUILD-FROM-SCRATCH phases 2 and 6)
    scripts/70-users.sh                     # accounts die with the VM; rerun after every import
    scripts/24-ad-up.sh
    # ISE: the portal form (docs/ISE-AD-BUILD.md Part 2), then log in once at
    # https://localhost:8443 and set the password to ISE_ADMIN_PASSWORD from config/mcp-env/ise.env
    scripts/25-ise-up.sh --post-deploy
    # then docs/ISE-AD-BUILD.md Part 3: the join and the groups

## Use

    scripts/60-import-lab.sh labs/<x>.yaml  # imports stopped; start it in the CML UI
    scripts/70-users.sh                     # grant the new lab to everyone
    scripts/80-verify-lab.sh <scenario>     # the lab must be running

## Stop

    scripts/40-down.sh
    scripts/45-ise-down.sh
    scripts/46-ad-down.sh

Every apply asks first. No script in this repository runs `destroy` against
the bootstrap or persistent root, and both carry `prevent_destroy` on their
most precious resource. A test checks the scripts' text, not Terraform.

## Read next

1. `docs/BUILD-FROM-SCRATCH.md`: the whole build, in order, with a check after each step.
2. `docs/STATUS.md`: where the build stands today.
3. `docs/ISE-AD-BUILD.md`: the directory, the ISE portal form, and the join.
4. `docs/ACCESS.md`: the web UI by name, with a real certificate.
5. `docs/ARCHITECTURE-REVIEW.md`: what still needs fixing, in order.
