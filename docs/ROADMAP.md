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
3. Textual as the UI framework. This is the implementation choice for
   items 1 and 2, not a separate deliverable. Recorded here so a future
   engineer does not reopen the question. The ADR is written when the UI
   spec is approved.
4. Lab calculator. Given a desired topology, or a lab YAML, add up the
   vCPU and RAM each node definition asks for, compare against the
   running controller, and say whether it fits, how many boot waves it
   needs, and which VM size would fit if it does not. The node definitions
   already carry the numbers and cml-mcp can read them. A later step is
   picking the VM size in tfvars from the answer, which makes it a small
   resource scheduler.

## Access and trust

5. A trusted certificate for the web UI, at no cost. Two shapes, both
   free. Let's Encrypt through the Cloudflare DNS challenge, with the
   cert cached on the Mac and the data disk and installed on the
   controller after each build. Or a Cloudflare Tunnel from the
   controller, which gives a valid cert and an Access login with no
   inbound rule at all, at the price of Cloudflare sitting in the browser
   path. The scripts, cml-mcp, and the smoke test keep talking to the IP
   either way. Decide in the spec. See STATUS 2026-09-05 for the
   discussion.
6. Lab repositories. CML pulls lab YAML from a git repo. A personal
   topology repo registered on every build through the API, so labs
   import on day one. Public repo to avoid a credential on the
   controller. Pairs with the export to blob at teardown.

## Images and scenarios

7. Nexus 9300v on the server. Add `nxosv9000` to `config/refplat.txt`,
   upload, rebuild. Two vCPU and 10 GB each. Six of them plus four
   Ubuntu fit the current size with RAM to spare; boot them in two waves.
8. Scenario topologies under `labs/`. One YAML per scenario. Empty today.

## From the design spec, still deferred

9. The lab edge router and the host's local bridge.
10. ISE and FTD virtual machines with their own persistent disks.
11. Key Vault and a managed identity for the secrets that are tfvars
    today.
12. CI, Bastion, and CML clusters.

## Other clouds

13. AWS port. Lowest priority. Upstream cloud-cml already supports AWS,
    so the fork patches and the persistent root are the real work: a
    persistent root for the VPC, EBS data disk, and S3 bucket that
    mirrors the Azure one, an S3 upload path in the image script, and
    provider selection in preflight and the up and down scripts. Out of
    scope until it has a spec, same as ISE and FTD.

## Done

Nothing yet.
