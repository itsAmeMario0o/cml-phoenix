# Roadmap

Ideas that have been agreed on but have no spec yet. Nothing here is in
scope until it has one. Order inside each section is rough priority. When
an item gets a spec, link it and move the item to the bottom under Done.

## Operator experience

1. Terminal UI for up and down. A Textual app that wraps the existing
   operator scripts so another engineer can bring a lab up, export it,
   and tear it down without knowing the script numbering. The scripts
   stay the source of truth. The UI calls them and streams their `[OK]`
   `[WARN]` `[FAIL]` lines into a log pane. Preflight results become a
   checklist view. Needs its own spec before any code. It changes the
   Python rule in CLAUDE.md, which is stdlib only today, so Textual is a
   deliberate exception that needs an ADR.
2. Guided credential setup. A first-run wizard in the same UI that walks
   a new user through the prerequisites: Azure CLI login, subscription
   selection and the `ARM_SUBSCRIPTION_ID` export, the Smart License
   token, the Cisco downloads into `software/`, and quota checks. It
   reuses the preflight checks as the validation step after each screen.
   The wizard never asks for a secret in a way that lands in a tracked
   file. Rendered config and `mcp-env/` stay gitignored.
3. Something to watch while a build runs. Up and down take 20 to 30
   minutes. The UI should show progress from the script output and
   give the operator something to look at meanwhile, in the spirit of
   the dinosaur game Chrome shows when it is offline. A small ASCII
   animation or a tiny game in a side pane, dismissable, and it must
   never cover a `[FAIL]`. It belongs inside the UI spec rather than
   getting one of its own.
4. Textual as the UI framework. This is the implementation choice for
   items 1 to 3 rather than a deliverable of its own. It is recorded
   here so a future engineer does not reopen the question. The ADR is written when the UI
   spec is approved.
5. Lab calculator. Given a desired topology, or a lab YAML, add up the
   vCPU and RAM each node definition asks for, compare against the
   running controller, and say whether it fits, how many boot waves it
   needs, and which VM size would fit if it does not. The node definitions
   already carry the numbers and cml-mcp can read them. A later step is
   picking the VM size in tfvars from the answer, which makes it a small
   resource scheduler.

## Access and trust

6. Automate the Cloudflare Tunnel connector as a post-build step.
   Decided 2026-09-05: the front door is a Cloudflare Tunnel, and the
   connector is the Debian package as a systemd unit rather than a
   container, because CML owns the Docker daemon on the host. The manual procedure
   is `docs/ACCESS.md`. What remains is a script that runs after the
   readiness wait in `20-up.sh`, reads the token from the gitignored env
   file, and installs the connector over SSH, so a rebuild needs no hands.
   It needs a spec and an ADR but no fork patch.
7. Lab repositories. CML pulls lab YAML from a git repo. A personal
   topology repo registered on every build through the API, so labs
   import on day one. Public repo to avoid a credential on the
   controller. Pairs with the export to blob at teardown.

## Images and scenarios

8. Nexus 9300v on the server. The image is in blob and on the refplat
   list since 2026-09-05, and it lands on the host at the next build. Two
   vCPU and 10 GB each. Six of them plus four Ubuntu fit the current size
   with RAM to spare, if you boot them in two waves.
9. Scenario topologies under `labs/`. One YAML per scenario. Empty today.
10. Image library as a product, not a chore. The blob container is
    already a shared library: one upload per deployment, none per
    engineer, and preflight checks it. What is not portable is the
    upload script itself. It mounts the ISO with a macOS tool and calls
    azcopy directly. Replace the mount with bsdtar extraction of only
    the selected paths, which works on Linux and macOS without root, and
    put the copy behind one small storage layer with an Azure
    implementation now and S3 later. End state is one command, or one
    screen in the Terminal UI, that finds the Cisco downloads, verifies
    the checksums, and pushes only what the library lacks. The refplat
    selection stays the single input. The persistence hook's successor,
    an `azcopy sync` from the library onto the data disk at build time,
    belongs to the same item.

## From the design spec, still deferred

11. The lab edge router and the host's local bridge.
12. ISE and FTD virtual machines with their own persistent disks.
13. Key Vault and a managed identity for the secrets that are tfvars
    today.
14. CI, Bastion, and CML clusters.

## Other clouds

15. AWS port. Lowest priority. Upstream cloud-cml already supports AWS,
    so the fork patches and the persistent root are the real work: a
    persistent root for the VPC, EBS data disk, and S3 bucket that
    mirrors the Azure one, an S3 upload path in the image script, and
    provider selection in preflight and the up and down scripts. Out of
    scope until it has a spec, same as ISE and FTD.

## Done

Nothing yet.
