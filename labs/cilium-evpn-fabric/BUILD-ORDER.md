# Building the fabric, ground up

`README.md` in this directory documents the design and gives a
verification command for every layer, in build order, once the fabric
is already up. This file is the companion piece: why each layer goes in
before the next one, and what breaks if you skip ahead. Read it once
before you push the first `.cfg` file, then use `README.md`'s
"Verifying, in build order" section as the checklist while you go.

None of this is invented for this document. Every design decision below
is already in the `.cfg` files; this just explains the dependency chain
that makes the order matter.

## Why order matters here

EVPN over VXLAN is three layers stacked on top of each other, and each
one is a precondition for the next:

1. A routed IP underlay has to exist before any BGP session can come up
   on it.
2. The underlay's multicast tree has to exist before VXLAN can flood
   BUM traffic (ARP, unknown unicast, broadcast) across the fabric,
   because this design replicates BUM the old way, with PIM and an
   anycast RP, not ingress replication.
3. The EVPN overlay session (BGP address-family l2vpn evpn) rides over
   the underlay's reachability, so it can't come up until the underlay
   is stable.
4. NVE and the VNIs depend on the overlay to exchange the MAC and IP
   routes that make the VXLAN tunnels useful; NVE will show "up" with
   an empty routing table if you bring it up before the overlay is
   working.

Skip a layer and the symptom shows up one or two layers later, further
from the actual cause. An NVE peer that never appears is usually a dead
overlay BGP session, not an NVE problem. Build bottom-up and each layer
proves itself with `show` commands before you move on, and there is
only ever one place to look when something is wrong.

## Step 0: nodes and push order

Spines before leaves, both directions. Boot order: spines first (they
have no leaf-facing dependency), then leaves. Config push order:
spines first too, because leaves peer to spine loopbacks that must
already exist and be reachable, and multicast RP addresses that must
already be configured before a leaf's PIM neighbor relationship can
form.

Every file in this directory is idempotent; pasting one twice does
nothing the second time. That is deliberate, so a partial push after an
interrupted console session is safe to repeat from the top rather than
requiring you to work out what already landed.

Push mechanism: through cml-mcp, `send_cli_command` with
`config_command` set takes a whole file at once (the `!` lines are
comments and are skipped). That is how the 2026-09-10 build went in,
and it is the same mechanism this repo's pyATS layer uses to read state
back afterward, just in the opposite direction: `send_cli_command`
configures, `device.parse()` in `verify/cilium-evpn/verify.py` reads.

## Step 1: features

Every capability used below is gated behind a NX-OS feature flag,
disabled by default. Leaves need six: `bgp`, `pim`,
`interface-vlan`, `vn-segment-vlan-based`, `nv overlay`,
`fabric forwarding`, plus the `nv overlay evpn` line that turns on
EVPN control-plane learning for NVE. Spines need only `bgp` and `pim`,
plus the same `nv overlay evpn` line, since a spine forwards VXLAN
traffic but never terminates a VTEP.

A feature that isn't enabled doesn't error when you paste a command
that depends on it; NX-OS silently drops the line. That makes this the
easiest layer to get wrong invisibly, and the reason `README.md`'s
verification puts it first: `show feature | include enabled` before
anything else, every time.

## Step 2: cabling, the routed point-to-point links

Eight physical links, `links.md` in this directory has the full map:
each leaf runs one link to each spine over a `/30`, MTU 9216 (VXLAN
adds 50 bytes of overhead per packet; a fabric-wide MTU of 1500 silently
fragments or drops VXLAN-encapsulated traffic later, so this has to be
right before anything rides on top of it). No switchport config here;
these are routed interfaces (`no switchport`) from the first line.

Verify before configuring a single routing protocol: CDP sees the
expected neighbor on the expected port, the interface is up with the
right MTU, and a ping across the `/30` succeeds. Getting this wrong
looks identical to a BGP misconfiguration two steps later, so ruling it
out here is worth the extra two minutes.

## Step 3: the underlay, eBGP IPv4 unicast

Every switch advertises its own loopback0 (`network` statement, not
redistribution) and peers eBGP to its directly connected neighbors over
the `/30` links from step 2. Spine AS is 65010, every leaf shares AS
65000. That's a departure from the usual "unique AS per leaf" EVPN
design, and it needs two extra knobs to work:

- Spines set `disable-peer-as-check`, or they refuse to re-advertise
  leaf1's underlay routes to leaf2, since a normal eBGP speaker won't
  send a route back into the AS it came from.
- Leaves set `allowas-in`, or they refuse to accept a route that
  already carries their own AS in the path, for the same reason in
  reverse.

The underlay's only job is to get every loopback0 and loopback1
reachable from every other switch. Nothing about VXLAN or EVPN belongs
in this layer; it's plain IP routing, and it should be provably working
end to end (ping loopback to loopback across the fabric) before layer 4
touches it.

## Step 4: multicast underlay

This design floods BUM traffic with PIM sparse mode and an anycast RP
at 10.254.254.1, shared between both spines (`ip pim anycast-rp` on
each spine, pointing at the other's loopback0). PIM runs on every
fabric-facing interface and on the loopbacks. This has to be in place
before NVE joins any multicast group in step 6, or the join has nowhere
to go and NVE reports "up" while carrying no BUM traffic at all, a
silent failure that looks fine until two hosts in the same VLAN can't
ARP for each other.

Verify PIM neighbors form on every link and both spines see each other
as anycast-RP members before moving on. `show ip mroute` stays empty at
this stage; that's expected; there's no VNI to generate a join yet.

## Step 5: the overlay, EVPN over eBGP

A second, independent BGP session, address-family l2vpn evpn, leaf
loopback0 to spine loopback0, `ebgp-multihop 5` because these are
loopback-to-loopback sessions riding over the underlay rather than
directly connected. Spines are pure route reflectors for this address
family: `retain route-target all` (without it, a spine drops every
EVPN route since it holds no VRF of its own to match a route target
against) and a route-map that leaves the next hop unchanged, so a
route from leaf1 still points at leaf1's VTEP when leaf3 receives it,
never at the spine.

This session depends entirely on step 3's underlay working, since it's
just another eBGP session riding the same reachable loopbacks. If it
won't come up, the underlay is the first thing to recheck, not this
layer.

## Step 6: VXLAN and the VRFs

Only now does NVE come up: source loopback1, host-reachability via
BGP (not the older flood-and-learn), members for both L2VNIs (30000,
30001, each with its own multicast group for BUM) and both L3VNIs
(50000, 50001, one per VRF). The two VRFs, red and blue, exist purely
to keep the two Cilium-facing networks apart on the wire; nothing about
them is EVPN-specific beyond the L3VNI they're bound to.

The anycast gateway (one MAC, `1234.5678.9000`, shared by every leaf so
a host's default gateway is reachable no matter which leaf it's
attached to) and the `tag 12345` on both gateway SVIs, matched by
`route-map REDIST-SUBNETS`, are what turns the attached subnet into an
EVPN Type-5 route other leaves can route to. Without the tag, the
subnet stays local to the leaf it's configured on.

This is the layer `verify/cilium-evpn/verify.py` actually checks:
`show nve vni` state up, on every switch. It's downstream of every
layer above it, which is exactly why a failure here is rarely an NVE
problem; work back up the stack.

## Step 7: prove it end to end

Start red-endpoint and blue-endpoint. Each should reach its anycast
gateway immediately; if it doesn't, the SVI or the VRF binding is
wrong, not the fabric. Then confirm the endpoint's MAC and ARP entry
show up locally and its Type-2 route propagates to every other leaf
(`show l2route evpn mac-ip all` on a leaf that never saw the endpoint
directly). red-endpoint and blue-endpoint should not be able to reach
each other; they sit in separate VRFs on purpose, which is the whole
point of keeping two private networks for the Cilium step that follows.

## What pyATS verifies, and what it doesn't

`scripts/80-verify-lab.sh cilium-evpn` checks two things, both against
Genie-parsed output, not raw text: every l2vpn evpn BGP neighbor
(step 5) is Established, and every VNI (step 6) is up. That's it. It
connects over CML's console, so it needs nothing from the management
plane, and it changes nothing on the devices; if a check fails, the fix
happens by hand or through `send_cli_command`, then the script runs
again.

It does not check the underlay, PIM, or the endpoint-level proof in
step 7 on its own. Those are still worth confirming by hand from
`README.md`'s verification commands, at least the first time through,
since a passing overlay/VNI check can still sit on top of an underlay
that's one link away from being broken.

## Next: Cilium as a BGP neighbor

Everything above builds the fabric these `.cfg` files describe, and
stops at the leaf. The Cilium-facing pieces, BGP unnumbered on
Ethernet1/6 toward the kind host, an EVPN session to each kind node's
own loopback, and the next-hop route-maps that make it work, are
deliberately left out of these files; they're the next layer, not this
one, and they need Cilium actually running (Cilium Enterprise, per
`labs/README.md`, since open-source Cilium peers BGP but doesn't speak
EVPN).

The dependency chain doesn't change shape: a BGP unnumbered session
from a leaf to a kind node is still just another underlay-adjacent eBGP
peering, and it still needs the leaf side of the fabric, steps 1
through 6 above, fully up first. Confirm the fabric passes both pyATS
checks before wiring up the Cilium side; a failure after that point is
then reliably on the Cilium/kind side of the peering, not a fabric
regression hiding underneath it.
