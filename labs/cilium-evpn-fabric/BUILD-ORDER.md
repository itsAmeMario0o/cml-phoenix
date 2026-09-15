# Building the fabric, ground up

`README.md` in this directory documents the design and gives a
verification command for every layer, in build order, once the fabric
is already up. This file is the companion piece: the actual commands
for each layer, grouped by device, in the order they have to go in, with
why each layer depends on the one before it. Read the "Why order
matters" section once, then use the per-device blocks below as the
paste-in sequence, and `README.md`'s "Verifying, in build order"
section as the checklist after each one.

Every block below is lifted from the tracked `.cfg` files, split by
layer instead of by device. Nothing here is invented; a few lines
appear in a different step than where they sit in the file, when their
real dependency is elsewhere, and each of those is called out
explicitly.

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

## Where spine and leaf actually differ

Short version, since it's easy to over-assume symmetry in a fabric like
this: spines and leaves diverge from the first line (spines never
terminate a VTEP, so they skip every VXLAN/VRF feature and command).
Within the four leaves, though, almost nothing differs. All four carry
byte-identical VLAN, VRF, VNI, NVE, and EVPN configuration, because the
anycast gateway design means any leaf can serve either private network,
whether or not a host happens to be plugged into it. The one real
per-leaf difference in this whole build is a single access-port stanza
in step 7: leaf1 gets a port in VLAN 100 (red), leaf2 gets one in VLAN
200 (blue), and leaf3/leaf4 get neither, since nothing is cabled to
them. That's it, that's the entire "red vs. blue" distinction at the
device level. Everywhere else, "leaf" means all four, identically.

## Step 0: nodes and push order

Spines before leaves, both directions. Boot order: spines first (they
have no leaf-facing dependency), then leaves. Config push order:
spines first too, because leaves peer to spine loopbacks that must
already exist and be reachable, and multicast RP addresses that must
already be configured before a leaf's PIM neighbor relationship can
form.

Every block below is idempotent; pasting one twice does nothing the
second time. That is deliberate, so a partial push after an interrupted
console session is safe to repeat from the top of the current step
rather than requiring you to work out what already landed.

Push mechanism: through cml-mcp, `send_cli_command` with
`config_command` set takes a whole block at once. Through a console
(`docs/ACCESS.md`, or `open /Cilium EVPN fabric (blank)/<node>/0` on
CML's console-server SSH), enter `configure terminal` first, paste, then
`end`. That is how the 2026-09-10 build went in, and it is the same
mechanism this repo's pyATS layer uses to read state back afterward,
just in the opposite direction: config in, `device.parse()` in
`verify/cilium-evpn/verify.py` reads out.

## Step 1: features

Every capability used below is gated behind an NX-OS feature flag,
disabled by default. A feature that isn't enabled doesn't error when
you paste a command that depends on it; NX-OS silently drops the line.
That makes this the easiest layer to get wrong invisibly, and the
reason `README.md`'s verification puts it first: `show feature |
include enabled` before anything else, every time.

**Both spines** (identical):

```
nv overlay evpn
feature bgp
feature pim
```

**All four leaves** (identical):

```
nv overlay evpn
feature bgp
feature pim
feature interface-vlan
feature vn-segment-vlan-based
feature nv overlay
feature fabric forwarding
```

Spines skip `interface-vlan`, `vn-segment-vlan-based`, and
`fabric forwarding`, since none of that means anything on a device that
never terminates a VTEP or hosts a VRF.

## Step 2: cabling, the routed point-to-point links and loopbacks

Eight physical links, `links.md` in this directory has the full map:
each leaf runs one link to each spine over a `/30`, MTU 9216 (VXLAN
adds 50 bytes of overhead per packet; a fabric-wide MTU of 1500 silently
fragments or drops VXLAN-encapsulated traffic later, so this has to be
right before anything rides on top of it). No switchport config here;
these are routed interfaces (`no switchport`) from the first line.

Both loopbacks go in now too, even though loopback1 (the VTEP source)
does nothing until step 6. It still needs to be underlay-reachable, so
its address has to exist before step 3 advertises it. Every interface
below already carries `ip pim sparse-mode`; that line is inert until
step 4 turns PIM on, typed once here rather than revisited later,
matching how the tracked `.cfg` files write it.

**spine1**:

```
interface loopback0
  description underlay router-id and EVPN peering
  ip address 10.2.0.1/32
  ip pim sparse-mode
!
interface Ethernet1/1
  description to leaf1 Ethernet1/1
  no switchport
  mtu 9216
  ip address 10.4.0.1/30
  ip pim sparse-mode
  no shutdown
!
interface Ethernet1/2
  description to leaf2 Ethernet1/1
  no switchport
  mtu 9216
  ip address 10.4.0.9/30
  ip pim sparse-mode
  no shutdown
!
interface Ethernet1/3
  description to leaf3 Ethernet1/1
  no switchport
  mtu 9216
  ip address 10.4.0.17/30
  ip pim sparse-mode
  no shutdown
!
interface Ethernet1/4
  description to leaf4 Ethernet1/1
  no switchport
  mtu 9216
  ip address 10.4.0.25/30
  ip pim sparse-mode
  no shutdown
```

**spine2** (same pattern, its own loopback and links):

```
interface loopback0
  description underlay router-id and EVPN peering
  ip address 10.2.0.2/32
  ip pim sparse-mode
!
interface Ethernet1/1
  description to leaf1 Ethernet1/2
  no switchport
  mtu 9216
  ip address 10.4.0.5/30
  ip pim sparse-mode
  no shutdown
!
interface Ethernet1/2
  description to leaf2 Ethernet1/2
  no switchport
  mtu 9216
  ip address 10.4.0.13/30
  ip pim sparse-mode
  no shutdown
!
interface Ethernet1/3
  description to leaf3 Ethernet1/2
  no switchport
  mtu 9216
  ip address 10.4.0.21/30
  ip pim sparse-mode
  no shutdown
!
interface Ethernet1/4
  description to leaf4 Ethernet1/2
  no switchport
  mtu 9216
  ip address 10.4.0.29/30
  ip pim sparse-mode
  no shutdown
```

**leaf1**:

```
interface loopback0
  description underlay router-id and EVPN peering
  ip address 10.2.0.11/32
  ip pim sparse-mode
!
interface loopback1
  description VTEP source
  ip address 10.3.0.11/32
  ip pim sparse-mode
!
interface Ethernet1/1
  description to spine1 Ethernet1/1
  no switchport
  mtu 9216
  ip address 10.4.0.2/30
  ip pim sparse-mode
  no shutdown
!
interface Ethernet1/2
  description to spine2 Ethernet1/1
  no switchport
  mtu 9216
  ip address 10.4.0.6/30
  ip pim sparse-mode
  no shutdown
```

**leaf2**:

```
interface loopback0
  description underlay router-id and EVPN peering
  ip address 10.2.0.12/32
  ip pim sparse-mode
!
interface loopback1
  description VTEP source
  ip address 10.3.0.12/32
  ip pim sparse-mode
!
interface Ethernet1/1
  description to spine1 Ethernet1/2
  no switchport
  mtu 9216
  ip address 10.4.0.10/30
  ip pim sparse-mode
  no shutdown
!
interface Ethernet1/2
  description to spine2 Ethernet1/2
  no switchport
  mtu 9216
  ip address 10.4.0.14/30
  ip pim sparse-mode
  no shutdown
```

**leaf3**:

```
interface loopback0
  description underlay router-id and EVPN peering
  ip address 10.2.0.13/32
  ip pim sparse-mode
!
interface loopback1
  description VTEP source
  ip address 10.3.0.13/32
  ip pim sparse-mode
!
interface Ethernet1/1
  description to spine1 Ethernet1/3
  no switchport
  mtu 9216
  ip address 10.4.0.18/30
  ip pim sparse-mode
  no shutdown
!
interface Ethernet1/2
  description to spine2 Ethernet1/3
  no switchport
  mtu 9216
  ip address 10.4.0.22/30
  ip pim sparse-mode
  no shutdown
```

**leaf4**:

```
interface loopback0
  description underlay router-id and EVPN peering
  ip address 10.2.0.14/32
  ip pim sparse-mode
!
interface loopback1
  description VTEP source
  ip address 10.3.0.14/32
  ip pim sparse-mode
!
interface Ethernet1/1
  description to spine1 Ethernet1/4
  no switchport
  mtu 9216
  ip address 10.4.0.26/30
  ip pim sparse-mode
  no shutdown
!
interface Ethernet1/2
  description to spine2 Ethernet1/4
  no switchport
  mtu 9216
  ip address 10.4.0.30/30
  ip pim sparse-mode
  no shutdown
```

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

**spine1**:

```
router bgp 65010
  router-id 10.2.0.1
  log-neighbor-changes
  address-family ipv4 unicast
    network 10.2.0.1/32
    network 10.254.254.1/32
    maximum-paths 4
  neighbor 10.4.0.2
    description leaf1 underlay
    remote-as 65000
    address-family ipv4 unicast
      disable-peer-as-check
  neighbor 10.4.0.10
    description leaf2 underlay
    remote-as 65000
    address-family ipv4 unicast
      disable-peer-as-check
  neighbor 10.4.0.18
    description leaf3 underlay
    remote-as 65000
    address-family ipv4 unicast
      disable-peer-as-check
  neighbor 10.4.0.26
    description leaf4 underlay
    remote-as 65000
    address-family ipv4 unicast
      disable-peer-as-check
```

The `network 10.254.254.1/32` line won't actually advertise anything
yet; that prefix is the anycast RP loopback, and it doesn't exist until
step 4. BGP doesn't error on a network statement with no matching route
in the RIB, it just has nothing to advertise. Typing it now, next to
the other network statement, matches the tracked file and saves a
second trip back into this block later.

**spine2**:

```
router bgp 65010
  router-id 10.2.0.2
  log-neighbor-changes
  address-family ipv4 unicast
    network 10.2.0.2/32
    network 10.254.254.1/32
    maximum-paths 4
  neighbor 10.4.0.6
    description leaf1 underlay
    remote-as 65000
    address-family ipv4 unicast
      disable-peer-as-check
  neighbor 10.4.0.14
    description leaf2 underlay
    remote-as 65000
    address-family ipv4 unicast
      disable-peer-as-check
  neighbor 10.4.0.22
    description leaf3 underlay
    remote-as 65000
    address-family ipv4 unicast
      disable-peer-as-check
  neighbor 10.4.0.30
    description leaf4 underlay
    remote-as 65000
    address-family ipv4 unicast
      disable-peer-as-check
```

**leaf1**:

```
router bgp 65000
  router-id 10.2.0.11
  log-neighbor-changes
  address-family ipv4 unicast
    network 10.2.0.11/32
    network 10.3.0.11/32
    maximum-paths 4
  neighbor 10.4.0.1
    description spine1 underlay
    remote-as 65010
    address-family ipv4 unicast
      allowas-in
  neighbor 10.4.0.5
    description spine2 underlay
    remote-as 65010
    address-family ipv4 unicast
      allowas-in
```

**leaf2**:

```
router bgp 65000
  router-id 10.2.0.12
  log-neighbor-changes
  address-family ipv4 unicast
    network 10.2.0.12/32
    network 10.3.0.12/32
    maximum-paths 4
  neighbor 10.4.0.9
    description spine1 underlay
    remote-as 65010
    address-family ipv4 unicast
      allowas-in
  neighbor 10.4.0.13
    description spine2 underlay
    remote-as 65010
    address-family ipv4 unicast
      allowas-in
```

**leaf3**:

```
router bgp 65000
  router-id 10.2.0.13
  log-neighbor-changes
  address-family ipv4 unicast
    network 10.2.0.13/32
    network 10.3.0.13/32
    maximum-paths 4
  neighbor 10.4.0.17
    description spine1 underlay
    remote-as 65010
    address-family ipv4 unicast
      allowas-in
  neighbor 10.4.0.21
    description spine2 underlay
    remote-as 65010
    address-family ipv4 unicast
      allowas-in
```

**leaf4**:

```
router bgp 65000
  router-id 10.2.0.14
  log-neighbor-changes
  address-family ipv4 unicast
    network 10.2.0.14/32
    network 10.3.0.14/32
    maximum-paths 4
  neighbor 10.4.0.25
    description spine1 underlay
    remote-as 65010
    address-family ipv4 unicast
      allowas-in
  neighbor 10.4.0.29
    description spine2 underlay
    remote-as 65010
    address-family ipv4 unicast
      allowas-in
```

The underlay's only job is to get every loopback0 and loopback1
reachable from every other switch. Nothing about VXLAN or EVPN belongs
in this layer; it's plain IP routing, and it should be provably working
end to end (ping loopback to loopback across the fabric) before layer 4
touches it.

## Step 4: multicast underlay

This design floods BUM traffic with PIM sparse mode and an anycast RP
at 10.254.254.1, shared between both spines. PIM already runs on every
fabric-facing interface and both loopbacks from step 2; what's missing
is telling every device where the RP is, and standing the RP itself up
on both spines.

**All four leaves** (identical, one line):

```
ip pim rp-address 10.254.254.1 group-list 239.1.1.0/25
```

**spine1**:

```
ip pim rp-address 10.254.254.1 group-list 239.1.1.0/25
ip pim anycast-rp 10.254.254.1 10.2.0.1
ip pim anycast-rp 10.254.254.1 10.2.0.2
!
interface loopback254
  description anycast RP
  ip address 10.254.254.1/32
  ip pim sparse-mode
```

**spine2** (same anycast-rp pair, same RP loopback address; that
shared address on both spines is what makes it anycast):

```
ip pim rp-address 10.254.254.1 group-list 239.1.1.0/25
ip pim anycast-rp 10.254.254.1 10.2.0.1
ip pim anycast-rp 10.254.254.1 10.2.0.2
!
interface loopback254
  description anycast RP
  ip address 10.254.254.1/32
  ip pim sparse-mode
```

The moment `loopback254` exists on both spines, the `network
10.254.254.1/32` statement from each spine's step 3 BGP block starts
advertising for real, with no further action; a concrete example of a
line typed in one step only doing something once a later step catches
up to it.

Verify PIM neighbors form on every link and both spines see each other
as anycast-RP members before moving on. `show ip mroute` stays empty at
this stage; that's expected, there's no VNI to generate a join yet.

## Step 5: the overlay, EVPN over eBGP

A second, independent BGP session, address-family l2vpn evpn, leaf
loopback0 to spine loopback0, `ebgp-multihop 5` because these are
loopback-to-loopback sessions riding over the underlay rather than
directly connected. This is an addition to the same `router bgp` block
from step 3, not a new one.

**spine1** (route reflector for this address family: `retain
route-target all`, since a spine holds no VRF of its own to match a
route target against and would otherwise drop every EVPN route; the
route-map leaves the next hop unchanged, so a route from leaf1 still
points at leaf1's VTEP when leaf3 receives it, never at the spine):

```
route-map NEXT-HOP-UNCHANGED permit 10
  set ip next-hop unchanged
!
router bgp 65010
  address-family l2vpn evpn
    retain route-target all
  neighbor 10.2.0.11
    description leaf1 overlay
    remote-as 65000
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      disable-peer-as-check
      send-community
      send-community extended
      route-map NEXT-HOP-UNCHANGED out
  neighbor 10.2.0.12
    description leaf2 overlay
    remote-as 65000
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      disable-peer-as-check
      send-community
      send-community extended
      route-map NEXT-HOP-UNCHANGED out
  neighbor 10.2.0.13
    description leaf3 overlay
    remote-as 65000
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      disable-peer-as-check
      send-community
      send-community extended
      route-map NEXT-HOP-UNCHANGED out
  neighbor 10.2.0.14
    description leaf4 overlay
    remote-as 65000
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      disable-peer-as-check
      send-community
      send-community extended
      route-map NEXT-HOP-UNCHANGED out
```

**spine2** (identical pattern, its own loopback0 as the session
source):

```
route-map NEXT-HOP-UNCHANGED permit 10
  set ip next-hop unchanged
!
router bgp 65010
  address-family l2vpn evpn
    retain route-target all
  neighbor 10.2.0.11
    description leaf1 overlay
    remote-as 65000
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      disable-peer-as-check
      send-community
      send-community extended
      route-map NEXT-HOP-UNCHANGED out
  neighbor 10.2.0.12
    description leaf2 overlay
    remote-as 65000
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      disable-peer-as-check
      send-community
      send-community extended
      route-map NEXT-HOP-UNCHANGED out
  neighbor 10.2.0.13
    description leaf3 overlay
    remote-as 65000
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      disable-peer-as-check
      send-community
      send-community extended
      route-map NEXT-HOP-UNCHANGED out
  neighbor 10.2.0.14
    description leaf4 overlay
    remote-as 65000
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      disable-peer-as-check
      send-community
      send-community extended
      route-map NEXT-HOP-UNCHANGED out
```

**leaf1** (two overlay neighbors, one per spine loopback0):

```
router bgp 65000
  neighbor 10.2.0.1
    description spine1 overlay
    remote-as 65010
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      allowas-in
      send-community
      send-community extended
  neighbor 10.2.0.2
    description spine2 overlay
    remote-as 65010
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      allowas-in
      send-community
      send-community extended
```

**leaf2, leaf3, leaf4** (identical to leaf1's block above; the overlay
neighbors are always the two spine loopbacks, 10.2.0.1 and 10.2.0.2, no
matter which leaf is configuring them):

```
router bgp 65000
  neighbor 10.2.0.1
    description spine1 overlay
    remote-as 65010
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      allowas-in
      send-community
      send-community extended
  neighbor 10.2.0.2
    description spine2 overlay
    remote-as 65010
    update-source loopback0
    ebgp-multihop 5
    address-family l2vpn evpn
      allowas-in
      send-community
      send-community extended
```

This session depends entirely on step 3's underlay working, since it's
just another eBGP session riding the same reachable loopbacks. If it
won't come up, the underlay is the first thing to recheck, not this
layer.

## Step 6: VXLAN and the VRFs

Only now does NVE come up: source loopback1, host-reachability via BGP
(not the older flood-and-learn), members for both L2VNIs (30000, 30001,
each with its own multicast group for BUM) and both L3VNIs (50000,
50001, one per VRF). Spines have nothing to configure here; they
forward VXLAN traffic without terminating a VTEP or holding a VRF.

**All four leaves** (byte-identical; this is the block from "Where
spine and leaf actually differ" above, copy it unchanged onto leaf1,
leaf2, leaf3, and leaf4):

```
fabric forwarding anycast-gateway-mac 1234.5678.9000
!
vlan 100
  name Net-Red
  vn-segment 30000
vlan 200
  name Net-Blue
  vn-segment 30001
vlan 2000
  name red-l3vni
  vn-segment 50000
vlan 2001
  name blue-l3vni
  vn-segment 50001
!
vrf context red
  vni 50000
  rd auto
  address-family ipv4 unicast
    route-target both auto
    route-target both auto evpn
vrf context blue
  vni 50001
  rd auto
  address-family ipv4 unicast
    route-target both auto
    route-target both auto evpn
!
route-map REDIST-SUBNETS permit 10
  match tag 12345
!
interface Vlan100
  description Net-Red anycast gateway
  no shutdown
  vrf member red
  no ip redirects
  ip address 10.0.100.1/24 tag 12345
  ip proxy-arp
  fabric forwarding mode anycast-gateway
!
interface Vlan200
  description Net-Blue anycast gateway
  no shutdown
  vrf member blue
  no ip redirects
  ip address 10.0.200.1/24 tag 12345
  ip proxy-arp
  fabric forwarding mode anycast-gateway
!
interface Vlan2000
  description red L3VNI
  no shutdown
  mtu 9216
  vrf member red
  no ip redirects
  ip forward
!
interface Vlan2001
  description blue L3VNI
  no shutdown
  mtu 9216
  vrf member blue
  no ip redirects
  ip forward
!
interface nve1
  no shutdown
  host-reachability protocol bgp
  source-interface loopback1
  member vni 30000
    mcast-group 239.1.1.1
  member vni 30001
    mcast-group 239.1.1.2
  member vni 50000 associate-vrf
  member vni 50001 associate-vrf
!
evpn
  vni 30000 l2
    rd auto
    route-target import auto
    route-target export auto
  vni 30001 l2
    rd auto
    route-target import auto
    route-target export auto
!
router bgp 65000
  vrf red
    address-family ipv4 unicast
      advertise l2vpn evpn
      redistribute direct route-map REDIST-SUBNETS
      maximum-paths 4
  vrf blue
    address-family ipv4 unicast
      advertise l2vpn evpn
      redistribute direct route-map REDIST-SUBNETS
      maximum-paths 4
```

The anycast gateway (one MAC, shared by every leaf, so a host's default
gateway is reachable no matter which leaf it's attached to) and the
`tag 12345` on both gateway SVIs, matched by `route-map
REDIST-SUBNETS`, are what turns the attached subnet into an EVPN
Type-5 route other leaves can route to. Without the tag, the subnet
stays local to the leaf it's configured on.

This is the layer `verify/cilium-evpn/verify.py` actually checks: `show
nve vni` state up, on every switch. It's downstream of every layer
above it, which is exactly why a failure here is rarely an NVE problem;
work back up the stack.

## Step 7: the one place red and blue actually diverge

Everything through step 6 is identical on every leaf. This step is the
only device-level difference in the whole build: which leaf has an
access port plugged into which endpoint.

**leaf1** (red-endpoint, VLAN 100, VRF red):

```
interface Ethernet1/7
  description red-endpoint
  switchport
  switchport mode access
  switchport access vlan 100
  spanning-tree port type edge
  no shutdown
```

**leaf2** (blue-endpoint, VLAN 200, VRF blue):

```
interface Ethernet1/7
  description blue-endpoint
  switchport
  switchport mode access
  switchport access vlan 200
  spanning-tree port type edge
  no shutdown
```

**leaf3, leaf4**: nothing to add. Neither has an endpoint cabled to it
in this topology; they carry the full VRF/VNI fabric from step 6 and
could serve either color if something were plugged in, but nothing is.

Start red-endpoint and blue-endpoint. Each should reach its anycast
gateway immediately; if it doesn't, the SVI or the VRF binding on
whichever leaf it's attached to is wrong, not the fabric. Then confirm
the endpoint's MAC and ARP entry show up locally and its Type-2 route
propagates to every other leaf (`show l2route evpn mac-ip all` on a
leaf that never saw the endpoint directly). red-endpoint and
blue-endpoint should not be able to reach each other; they sit in
separate VRFs on purpose, which is the whole point of keeping two
private networks for the Cilium step that follows.

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
