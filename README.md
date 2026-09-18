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
    scripts/20-up.sh
    # wait a minute: the controller's API is not ready the moment the script ends
    scripts/50-tunnels.sh up
    scripts/90-smoke-test.sh                # summary: 13 OK, 0 WARN, 0 FAIL
    scripts/24-ad-up.sh
    # ISE: the portal form, then log in once at https://localhost:8443 and set the password
    scripts/25-ise-up.sh --post-deploy
    # then docs/ISE-AD-BUILD.md Part 3: the join and the groups

## Use

    scripts/60-import-lab.sh labs/<x>.yaml  # or re-import the last export, BUILD-FROM-SCRATCH phase 6
    scripts/70-users.sh
    scripts/80-verify-lab.sh <scenario>

## Stop

    scripts/40-down.sh
    scripts/45-ise-down.sh
    scripts/46-ad-down.sh

Every apply asks first. The bootstrap and persistent roots carry
`prevent_destroy` on the state storage account and the data disk, and no
script in this repository runs `destroy` against either root. The test for
that (`tests/test_down_dry_run.sh`) only checks that the text of
`40-down.sh` never names those roots next to the word "destroy"; it does
not exercise Terraform.

## Read next

1. `docs/BUILD-FROM-SCRATCH.md`: the whole build, in order, with a check after each step.
2. `docs/STATUS.md`: where the build stands today.
3. `docs/ISE-AD-BUILD.md`: the directory, the ISE portal form, and the join.
4. `docs/ACCESS.md`: the web UI by name, with a real certificate.
5. `docs/ARCHITECTURE-REVIEW.md`: what still needs fixing, in order.
