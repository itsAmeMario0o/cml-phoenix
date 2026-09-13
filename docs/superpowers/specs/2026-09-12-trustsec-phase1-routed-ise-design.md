# TrustSec Phase 1: the routed path and a disposable ISE

> **Partly superseded, 2026-09-13.** The ISE deploy method in this spec has
> since evolved twice: the `terraform/ise` root it describes was dropped for a
> `az deployment group create` deploy (ADR 0008), which was then itself retired
> when ISE terminally failed Azure OS provisioning. ISE is now deployed by hand
> through the portal (ADR 0008 amendment; `docs/ISE-MARKETPLACE-DEPLOY.md`).
> The routed-path design (the transit bridge, the C8000v edge, the no-NAT
> requirement) still stands; only the ISE deploy mechanism changed.

Status: draft, 2026-09-12.

This is the first of two specs for a Cisco TrustSec lab. Phase 1 builds
the foundation: an external ISE that the CML switches can reach for RADIUS
with per-device identity and a working Change of Authorization return
path. Phase 2, a separate spec, builds the TrustSec topology and policy on
top (Catalyst 9000v fabric, SGT classification, SGACL enforcement, and an
FTD fed by SXP or pxGrid).

## Context

TrustSec needs ISE to see each switch at its own source address and to
send Change of Authorization back to that address. Network Address
Translation breaks both: every switch collapses into the CML host's
address and CoA has no return path. ADR 0003 settled this in the design
phase and chose a routed path with no NAT. The Azure half of that path is
already built in the persistent root; this spec builds the rest and adds
ISE.

The operator wants ISE run externally, on the apps subnet, from the Azure
Marketplace image, and rebuilt per session rather than kept running. The
environment being modelled is an automated Catalyst VXLAN EVPN fabric with
no controller, so ISE policy is treated as code and reapplied on each
build, which is also what makes a disposable ISE practical.

## Goal and scope

In scope for Phase 1:

- The host transit bridge and routing that carry lab traffic to and from
  the VNet without NAT.
- A CML external connector that places lab nodes on that bridge, and a
  C8000v lab edge that routes the transit network.
- ISE as a disposable Azure VM on the apps subnet, in its own Terraform
  root, brought up and torn down with the session.
- Proof that a lab node reaches ISE, ISE reaches the node, and a test
  RADIUS authentication with CoA completes.

Out of scope, deferred to Phase 2:

- The Catalyst 9000v fabric, endpoints, and the FTD.
- SGT classification, the SGACL matrix, SXP, and pxGrid.
- The full ISE policy. Phase 1 configures only enough of ISE to prove the
  path: one network device (a NAD) and one authentication that returns a
  result with CoA.

## Architecture

### The Azure side, already built

The persistent root already provides everything on the Azure side, so
Phase 1 adds nothing here and only depends on it:

- The CML NIC has IP forwarding enabled and a static private address,
  `10.20.1.10`.
- A route table on the apps subnet sends the lab summary `10.100.0.0/16`
  to `10.20.1.10` as a virtual-appliance next hop. Azure's fabric makes
  this decision, so it must be a user-defined route, not a guest route.
- An NSG rule on the CML NIC allows the apps subnet to reach the lab
  summary on any port.

### The host transit bridge, new

On the CML host, a Linux bridge named `br-transit` carries lab traffic at
`10.100.0.1/24`. It is deliberately not attached to the VNet NIC, because
Azure will not deliver frames to MAC addresses it does not know, which is
why bridge mode was rejected in ADR 0003. Instead the host acts as a layer
3 hop:

- `net.ipv4.ip_forward` is on.
- Traffic from a switch to ISE leaves as the switch's real address:
  switch to `br-transit` to the host, then out the VNet NIC to the apps
  subnet. No masquerade rule sits on this path, so ISE sees per-device
  source addresses.
- The return path is the user-defined route, which sends
  `10.100.0.0/16` back to the host, which forwards it onto `br-transit`.

The host is rebuilt every session, so the bridge, the sysctl, and the
absence of a masquerade rule must be recreated by the build. That is a
customize script in the cloud-cml fork under `vendor/`, which is a
stop-and-ask change when Phase 1 is implemented. The script is small: it
creates the bridge, sets the sysctl, and confirms nftables does not NAT
the transit range.

### The CML side

A CML external connector maps lab nodes onto `br-transit`. A C8000v lab
edge at `10.100.0.2` routes the rest of `10.100.0.0/16` to the fabric, so
the transit segment stays a small `/24` and the fabric addressing lives
behind the edge. In Phase 1 the "fabric" is a single test switch or even
the edge itself; the real fabric is Phase 2.

### ISE, disposable, on Azure

ISE runs from Cisco's Azure Marketplace image on the apps subnet, for
example at `10.20.2.20`, in its own disposable Terraform root
(`terraform/ise`) with blob state, created and destroyed with the session
in the same spirit as the CML VM. It uses the persistent apps subnet and
the persistent VNet, so it never recreates durable network resources.

- Sizing follows Cisco's Azure ISE guidance. The evaluation profile is the
  target; the VM size and disk come from that guidance and are pinned in
  the spec once confirmed against the Marketplace offer.
- A fresh deployment starts a fresh 90-day evaluation, which suits a
  disposable node and avoids Smart Licensing re-registration each session.
- The admin password is a `random_password` in the ISE root, read back
  with `terraform output -raw`, never committed, in line with ADR 0004.
- Marketplace image terms are accepted once per subscription with
  `az vm image terms accept`; the preflight checks this like it checks
  quota.

Policy is code. On each build, after ISE reports ready, the TrustSec
configuration is applied through ISE's REST API or the `cisco.ise` Ansible
collection. Phase 1 applies only a minimal policy to prove the path; the
full policy belongs to Phase 2. This is what makes disposable ISE workable
and matches the automated, no-controller environment being modelled.

### Operator flow

New numbered scripts bring ISE up and down around the existing CML build:

- A build step applies the `terraform/ise` root after the CML host is up
  and the transit bridge exists, then waits for ISE to report ready.
- A teardown step destroys the ISE root before the CML VM, so the apps
  subnet is clean.

The ISE ready wait is the long pole, roughly 30 to 45 minutes, so it runs
as a background step with clear progress, not a blocking foreground call.

## Secrets

- ISE admin password: `random_password` in the ISE root, gitignored state.
- ISE license: evaluation by default, so no token. If a Smart License is
  used later, it follows the `config/cml.tfvars` pattern, gitignored.
- No secret is written to a tracked file, per CLAUDE.md.

## Verification

1. `az` shows the ISE VM running on the apps subnet.
2. From the C8000v edge or a test switch on the transit bridge,
   `ping 10.20.2.20` reaches ISE, and a `test aaa` against ISE returns a
   result.
3. From ISE, the switch is reachable at its transit address, confirming
   the return path and per-device identity, not a single NATed address.
4. A test authentication produces a RADIUS Access-Accept and a CoA can be
   pushed from ISE to the switch.
5. `terraform -chdir=terraform/persistent plan` still shows no changes,
   proving Phase 1 touched only disposable roots and the fork.

## Risks and fallback

- The routed path is unproven. ADR 0003 kept a C8000v-to-C8000v overlay
  tunnel as the documented fallback if the host routing surprises us.
- ISE boot time dominates a session. If it becomes a burden, the
  documented alternative is a persistent ISE that is deallocated when
  idle, which trades ongoing disk cost for a fast start. The design keeps
  ISE in its own root so switching models later changes one root, not the
  kit.
- ISE on Azure has a supported size list. If the evaluation profile is not
  offered at a size that fits the subscription's quota, the spec pins the
  smallest supported size and notes the quota needed.

## Open questions

- The exact Marketplace offer, plan, and supported VM size for ISE 3.x on
  Azure, confirmed against the live Marketplace before implementation.
- Whether the transit bridge is best created by a fork customize script or
  by a post-build operator script over SSH. The fork keeps it hands-free
  across rebuilds; a script keeps the fork smaller. Decided at
  implementation, noted here as a fork stop-and-ask either way.
- The minimal ISE policy for Phase 1: one NAD plus one authorization rule,
  applied by REST or Ansible, is the working assumption.
