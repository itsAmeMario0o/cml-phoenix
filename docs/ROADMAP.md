# Roadmap

This is the backlog of ideas that have been agreed on but do not yet have a
spec. Nothing here is in scope until it does. Items are numbered in the
order they were added, and a number is never reused or reassigned, because
other documents and a code comment cite items by number. So the numbers run in order within a section but not across
sections. Within each section the order reflects rough priority, and once
an item has shipped it moves to the Done section at the bottom under its
number.

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

6. Post-build configuration: the tunnel connector, users, lab repositories.
   Decided 2026-09-05: the front door is a Cloudflare Tunnel, and the
   connector is the Debian package as a systemd unit rather than a
   container, because CML owns the Docker daemon on the host. The manual procedure
   is `docs/ACCESS.md`. What remains is a script that runs after the
   readiness wait in `20-up.sh`, reads the token from the gitignored env
   file, and installs the connector over SSH, so a rebuild needs no hands.
   The users half landed 2026-09-10 as `scripts/70-users.sh` (ADR
   0007): a CSV in the self-ignoring mcp-env directory, generated
   passwords written to a private sheet, a `class` subcommand for ten
   students at a time, create-if-missing so it reruns after every
   build. The connector half was done by hand over one SSH session the
   same day, with the sysadmin password and the token on stdin, which
   is the shape the script should take. Lab rights for a group are
   still set in the UI or by a PATCH on the lab's associations. Item 7 belongs here as well.
   It needs a spec and an ADR but no fork patch. Upstream cloud-cml also
   ships a Let's Encrypt hook, `03-letsencrypt.sh`, unused here. If a real
   certificate on the box ever matters, for the API through the name,
   start there rather than from scratch.
7. Lab repositories. CML pulls lab YAML from a git repo. A personal
   topology repo registered on every build through the API, so labs
   import on day one. Public repo to avoid a credential on the
   controller. Pairs with the export to blob at teardown.
16. Reclaim cloud-manager licenses at teardown. Near-term priority.
    Labs register devices against cloud-delivered managers, and the
    manager holds the license until the device record is deleted.
    Today that is manual: the IPS lab's FTDs show unregistered after a
    rebuild, but cloud-delivered FMC still lists them, so the license is
    not freed until each record is deleted by hand. A teardown step
    should release those records over the manager's API before the CML
    VM is destroyed, so the next build starts with the seats back. First
    target is cloud-delivered FMC through Security Cloud Control: a
    stdlib Python client in `scripts/lib/` that reads the tenant and API
    token from a gitignored env file and deletes the lab's device
    records, with a fake API server for the test, matching the kit's
    existing patterns. The same shape extends to the other cloud
    managers the labs depend on, which is why it is worth building once
    and reusing. Needs a short spec before any code.
17. Azure Bastion for browser-based access. Optional. It lets an
    operator open a lab VM's SSH or RDP session from the Azure portal,
    and reach any other port with `az network bastion tunnel`, without
    the CML host jump and without giving that VM its own public IP.
    Access is controlled by RBAC on the Bastion resource rather than an
    IP allow-list. It is a persistent resource that bills whether or
    not anyone connects, and it needs its own `/26` subnet named
    `AzureBastionSubnet` in the persistent VNet. Not needed while the
    CML host jump remains the access path (ADR 0003, ADR 0008).
18. Cisco ISE configuration as code with the official `cisco.ise` Ansible
    collection, as the default ISE config layer. It manages the full
    TrustSec object set over the ERS and OpenAPI: network devices, policy
    sets, authorization rules, SGTs, SGACLs, and the egress matrix, which
    is far more than the hand-rolled `scripts/lib/ise_config.py` covers.
    Decided 2026-09-13 to adopt it, later. It is another non-stdlib
    dependency, so it follows the same shape as the pyATS verification
    layer: its own venv and an ADR for the exception. Once in, it
    supersedes or shrinks `ise_config.py`, and the per-session policy is
    reapplied as idempotent playbooks. `1homas/ISE_Ansible_Sandbox` is the
    reference for patterns built on this collection.
19. Ephemeral ISE with the ISE Eternal Evaluation (ISEEE) approach.
    Superseded 2026-09-18 by item 24. It was here because a per-session
    portal deploy of ISE (ADR 0008, `docs/ISE-AD-BUILD.md` Part 2) was too
    much friction to repeat every session; the answer is to stop
    redeploying it and deallocate it between sessions instead. ISEEE
    (`1homas/ISE_Ansible_Sandbox`) stays a reference for item 18.
24. Persistent ISE and directory, three commands to start. In progress.
    Spec: `docs/specs/2026-09-18-persistent-ise-dc-and-script-consolidation-design.md`,
    approved 2026-09-18, not built. ISE and the DC will be built once and deallocated
    between sessions; the ten hand touches of the 2026-09-18 start fold
    into `20-up.sh`, `24-ad-up.sh`, and `25-ise-up.sh`; no orchestrator,
    no state file. Order of work, one PR each:
    1. Redeploy ISE onto 300 GB Standard SSD, by hand in the portal, once.
    2. `45-ise-down.sh` and `46-ad-down.sh` deallocate by default.
    3. `24-ad-up.sh` and `25-ise-up.sh` start a deallocated server.
    4. `ise_config.py` does the join, the groups, and the NADs from data.
    5. `20-up.sh` does the rescan, cloudflared, the reimport, users, and
       the ready wait.
    6. Docs: the deploy guide, the build guide, ADR 0008 amendment, STATUS.
    Owed beside it, not in the spec: the rotation of the two CML
    passwords, declined by the operator on 2026-09-18 and open since the
    2026-09-17 leak (`docs/STATUS.md`, next steps).

21. Python first, with proof. Tabled by the operator the same day it was
    raised: functional labs come first, and this waits until they work as
    intended. Do not start it unasked. Operator direction, 2026-09-17: the kit has
    grown to thirteen bash scripts and six Python modules, about 3,200
    lines, and nearly every latent bug found in the 09-16 and 09-17
    sessions lived in bash that had only ever been dry-run tested (a
    doubled curl status read as ready, a filename a regex skipped, SSH
    swallowing a heredoc, a tag query a newer az rejects). Revisit the
    architecture, standardize as aggressively as is sensible on Python,
    and put it under a real test framework so that behavior is proven,
    not inferred. Needs its own spec before any code: which scripts stay
    thin bash wrappers around terraform and az and which move, whether
    the stdlib-only rule (CLAUDE.md code style) still holds or pytest
    and a small dependency set earn an ADR, how live checks (smoke,
    readiness, the pyATS layer) fit beside unit tests, and an order of
    migration that never leaves the kit unable to build. The 2026-09-17
    architecture review's "Stack verdicts" gives the order when this is
    picked up: fix the test seam first (run the scripts with dry run off
    against stub `az`, `ssh`, `curl`, and `terraform`), then move only
    `25-ise-up.sh`, `45-ise-down.sh`, `00-preflight.sh`, and
    `60-import-lab.sh`; the rest stays thin bash.
22. ISE as policy as code. Operator direction, 2026-09-17: drive ISE from
    declared policy, built out from the API calls already proven live
    (ERS network devices and internal users, OpenAPI policy sets and
    authorization rules, the monitoring API for verification), not from
    one-off calls. `ise_config.py` is the seed: idempotent, tested
    against a fake API, shapes confirmed against real ISE 3.5. The
    Phase 2 spec (`2026-09-17-trustsec-phase2-design.md`) needs device
    groups, SNMP settings, SGTs, SGACLs, the egress matrix, identity
    groups, and profiler probes on top. The open design question is the
    shape: policy declared as data files that a Python engine applies,
    which fits item 21, or the `cisco.ise` Ansible collection of item 18.
    Decide that in the spec; the two should not both grow.

23. Containers as lab endpoints. Operator direction, 2026-09-17: wanted,
    no action yet. CML 2.10 runs Docker containers as nodes and this
    host already has the docker shim running, but the 2.10 reference ISO
    carries only `xrd`; Cisco moved the rest to GitHub releases
    (`CiscoLearning/cml-docker-containers`, releases labelled CML 2.10.0,
    three small ISOs: services, browser, splunk). The operator's picks,
    in order of interest: a custom `debian-slim` image with
    `wpasupplicant`, `lldpd`, and a DHCP client, as an 802.1X, MAB, and
    LLDP endpoint in about 70 MB against a 2 GB Ubuntu VM, which is what
    makes a diversity of endpoints affordable; Cisco's `splunk` node, for
    ISE syslog analytics; then the services set (`radius`, `tacplus`,
    `dnsmasq`, `syslog`, `nginx`, `frr`, `net-tools`, `snort`), the
    browsers for guest portal demos, a Kali image with its tools baked in
    (the official image ships bare and lab nodes have no internet), and
    Juice Shop as a maintained vulnerable target. Accepted limits:
    containers cannot send 802.1Q tagged frames, and the node count
    against the license is not a concern for now. To test before relying
    on any of it, the way VM endpoints were tested on 09-17: whether
    EAPOL and LLDP reach a container's interface, which no document
    says, and whether Cisco's ISO import works on Azure, where there is
    no CD drive to attach. Needs a short spec first.

## Images and scenarios

8. Nexus 9300v and the SD-WAN set on the server. In Done below.
9. Scenario topologies under `labs/`. One YAML per scenario. The first
   one landed 2026-09-10: the Cilium EVPN fabric, blank edition, with
   placeholders rendered at import (ADR 0006). Still to come in that
   family: the built edition, where the six switch configs carry the
   whole eBGP EVPN fabric from the source lab's Nexus Dashboard data
   model, so the Cilium work starts on a working fabric. Tabled until
   the blank one has been built by hand at least once. Both editions
   should come from one node-and-link definition so they never drift.
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
    selection stays the single input, but it should learn which ISO each
    image comes from, because FTDv, FMCv, and the SD-WAN set live on the
    supplemental ISO and item 12 will need them. The persistence hook's successor,
    an `azcopy sync` from the library onto the data disk at build time,
    belongs to the same item. The other way to retire the hook's copy
    logic is upstream: a skip-existing option on cloud-cml's copy
    routine, off by default, offered as a pull request to CiscoDevNet.
    Slow, and the only option that makes the fork smaller.
20. NX-OS to IOS-XR data center interconnect lab. An NX-OS BGP EVPN VXLAN
    fabric, spine and leaves, handing off to an IOS-XR node that acts as the
    data center interconnect and terminates internet and WAN routes. In CML
    the fabric is `nexus9300v` and the interconnect is `xrv9k`, both of which
    do EVPN, so the topology is buildable. The handoff has two forms: a
    VRF-lite or L3 handoff at a border leaf, which is reliable on the CML
    images and is the one to build first; and full EVPN VXLAN-to-MPLS or SR
    stitching on the XR gateway, which is real on ASR 9000 and NCS hardware
    but whose support on the CML `xrv9k` image must be confirmed before it is
    trusted, with VRF-lite as the fallback. The constraint is resources:
    `xrv9k` is about 4 vCPU and 16 GB and each `nexus9300v` about 2 vCPU and
    12 GB, so a spine, two leaves, the interconnect, and a WAN or internet
    simulator need sizing against the host or boot waves, which ties to the
    lab calculator, item 5. Needs its own spec.
25. Blue-green network infrastructure on NX-OS, with the pipeline that
    makes it real. Operator idea, 2026-09-18: explore what a blue-green
    deployment looks like for network infrastructure, with two parallel
    fabrics carrying different versions of the configuration (and of the
    code that renders it), a cutover between them, and a rollback that is
    a switch back rather than a repair. The interesting parts are the ones
    ForeScout-style labs never touch: the CI/CD pipeline that validates a
    version before it is allowed near the green side (render, lint, deploy
    to CML, pyATS against it), the automation that moves traffic (an
    upstream router or the EVPN control plane preferring one fabric), and
    what "state" means when the fabric is meant to be replaced rather than
    edited. Builds on item 20's NX-OS fabric and on the pyATS layer, and
    would be the first lab where the repo's own CI (item 14) is part of
    the story rather than the plumbing. Needs its own spec; mutable versus
    immutable is the first question it has to settle.

## From the design spec, still deferred

13. Key Vault and a managed identity for the secrets that are tfvars
    today. ADR 0004 defers it until a second operator joins, and ADR 0011
    names that as the exit condition for keeping the repository's secrets
    where they are.
14. CI and CML clusters. Bastion is item 17. CI would be one small job
    running `tests/run.sh` and gitleaks, and it is the operator's to
    approve since `CLAUDE.md` excludes it. Clusters are not a scope line
    to lift: the routed path of ADR 0003 is one layer 3 hop, one route
    next hop, and one bridge on one host, so a cluster means redesigning
    that ADR first.

## Other clouds

15. AWS port. Lowest priority. Upstream cloud-cml already supports AWS,
    so the fork patches and the persistent root are the real work: a
    persistent root for the VPC, EBS data disk, and S3 bucket that
    mirrors the Azure one, an S3 upload path in the image script, and
    provider selection in preflight and the up and down scripts. Out of
    scope until it has a spec, same as ISE and FTD.

## Done

- 11, the lab edge router and the host's local bridge, 2026-09-17. The
  fork's `06-transit.sh` builds `bridge1` and the `transit` libvirt
  network on the CML host, the C8000v in `labs/trustsec-phase1.yaml` is
  the edge at 10.100.0.2, and the path was proven with RADIUS and CoA
  (ADR 0003 and its amendment, `docs/STATUS.md`).
- 12, ISE and FTD virtual machines, in a different shape than the spec
  drew. ISE is a per-session Marketplace deploy (ADR 0008 and its
  amendment) and FTDv runs inside CML from the persistent data disk
  (`labs/ips-ha.yaml`). Neither has a persistent disk of its own; the
  operator rejected a second monthly disk when the same question came up
  for the domain controller (ADR 0010). Item 24 reverses that for ISE and
  the DC as of 2026-09-18.
- 8, Nexus 9300v on the server, 2026-09-07. Two vCPU and 12 GB each by the
  node definition in this refplat. With
  it came the Catalyst SD-WAN Manager, Validator, Controller, and edge
  from the supplemental ISO, uploaded with the `REFPLAT_ISO` override.
  The Manager wants 8 vCPU and 32 GB and carries a 256 GB thin data
  volume on the OS disk; watch that on long labs. vEdge, FTDv, FMCv,
  the wireless controller, and Meraki vMX were left off on purpose.
  FTDv 10.0.0 joined the list on 2026-09-10 for the firewall cluster
  lab; FMCv stays off, since management is cloud-delivered.
