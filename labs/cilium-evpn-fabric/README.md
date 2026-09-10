# Cilium EVPN fabric, reference configuration

Day-1 configuration for the six switches in `labs/cilium-evpn-blank.yaml`,
one file per device. This is the fabric the source lab built through
Nexus Dashboard, written out as plain NX-OS so it can be pasted at a
console, pushed through cml-mcp, or used as the answer key while you
build the blank lab by hand. No usernames or passwords in here; the
switches already have those from day-0.

The Cilium-facing pieces (BGP unnumbered on Ethernet1/6, the EVPN
session to each kind node's loopback, the next-hop route-maps) are not
in these files. They come with the Cilium step.

## Design

eBGP VXLAN EVPN, same AS on every leaf.

| Item | Value |
|---|---|
| Spine AS | 65010 |
| Leaf AS | 65000 |
| Underlay | eBGP ipv4 unicast over /30 point to point links, MTU 9216 |
| Overlay | eBGP l2vpn evpn, leaf loopback0 to spine loopback0, multihop 5 |
| Spines | route servers: `retain route-target all`, next hop unchanged |
| BUM replication | multicast, anycast RP 10.254.254.1 on both spines |
| VTEP source | loopback1 on each leaf |
| Anycast gateway MAC | 1234.5678.9000 |

Same AS on every leaf needs two knobs. Spines set `disable-peer-as-check`
so they will send leaf1's routes to leaf2. Leaves set `allowas-in` so
they accept a path that already carries 65000.

## Addresses

| Device | loopback0 | loopback1 (VTEP) |
|---|---|---|
| spine1 | 10.2.0.1 | |
| spine2 | 10.2.0.2 | |
| leaf1 | 10.2.0.11 | 10.3.0.11 |
| leaf2 | 10.2.0.12 | 10.3.0.12 |
| leaf3 | 10.2.0.13 | 10.3.0.13 |
| leaf4 | 10.2.0.14 | 10.3.0.14 |

Point to point links are in `links.md`: leafN Ethernet1/1 goes to spine1
Ethernet1/N and leafN Ethernet1/2 to spine2 Ethernet1/N, spine side .1,
leaf side .2, from 10.4.0.0/30 upward.

## Overlay

| Name | VLAN | VNI | Type | Gateway | Multicast group |
|---|---|---|---|---|---|
| red | 2000 | 50000 | L3VNI, VRF red | | |
| blue | 2001 | 50001 | L3VNI, VRF blue | | |
| Net-Red | 100 | 30000 | L2VNI in red | 10.0.100.1/24 | 239.1.1.1 |
| Net-Blue | 200 | 30001 | L2VNI in blue | 10.0.200.1/24 | 239.1.1.2 |

Route targets are `auto` on both VRFs and VNIs, which resolves to
65000:VNI on every leaf. `ip proxy-arp` on the two gateway SVIs is the
fix the source lab needed for Cilium's unnumbered peer to resolve
endpoint addresses. Every SVI gateway carries tag 12345 so the subnet
goes out as an EVPN Type-5 route.

leaf1 Ethernet1/7 is an access port in VLAN 100 for red-endpoint.
leaf2 Ethernet1/7 is the same in VLAN 200 for blue-endpoint.

## Applying it

Spines first, then leaves, in configuration mode. Each file is idempotent
and can be pasted more than once. Through cml-mcp, `send_cli_command`
with `config_command` set takes a whole file at once, minus the `!`
comment lines; that is how the first deployment went in on 2026-09-10.

## Verifying, in build order

Same order as the configuration goes in. Each step assumes the one
before it passed. Commands run on a leaf unless a spine is named.

### 1. Features

    show feature | include enabled
    show running-config | include ^feature|^nv overlay

Leaves: bgp, pim, interface-vlan, vn-segment-vlan-based, nv overlay,
fabric forwarding, plus the `nv overlay evpn` line. Spines: bgp and pim
only, plus `nv overlay evpn`. A missing feature shows up later as a
command that was silently dropped, so check this first.

### 2. Cabling and point to point links

    show cdp neighbors
    show interface brief | include Eth1/[12]
    show ip interface brief
    show interface Ethernet1/1 | include MTU|line protocol

CDP should name the far end exactly as `links.md` does: leaf1
Ethernet1/1 sees spine1 Ethernet1/1, Ethernet1/2 sees spine2
Ethernet1/1. Both links up, addressed from the table, MTU 9216. Then
ping the far end of each link: from leaf1, `ping 10.4.0.1` and
`ping 10.4.0.5`.

### 3. Underlay BGP

    show bgp ipv4 unicast summary
    show bgp ipv4 unicast neighbors 10.4.0.1 | include AS|state
    show ip route bgp
    show ip route 10.3.0.12

A leaf holds two sessions, AS 65010, Established, with prefixes
received. The routing table carries every other device's loopback0,
the three other VTEP loopback1 addresses, and the RP address, each
learned from both spines, so the last command shows two next hops.
Prove reachability the way the overlay will use it, loopback to
loopback: `ping 10.2.0.12 source 10.2.0.11` and
`ping 10.3.0.12 source 10.3.0.11`. On a spine the summary shows four
sessions, AS 65000, and `show ip route bgp` has all four VTEPs.

### 4. Multicast underlay

    show ip pim interface brief
    show ip pim neighbor
    show ip pim rp

PIM sparse mode on both fabric links and the loopbacks, one PIM
neighbor per link, and the RP 10.254.254.1 learned statically for
239.1.1.0/25. On a spine, `show ip pim rp` also lists both spines
as anycast-RP members. `show ip mroute` stays empty until the NVE
joins its groups in step 6.

### 5. Overlay BGP EVPN

    show bgp l2vpn evpn summary
    show bgp l2vpn evpn neighbors 10.2.0.1 | include multihop|Established|community|allowas

Two sessions per leaf to the spine loopbacks, Established, multihop
5, both communities sent, allowas-in on. On a spine, four sessions and
`show bgp l2vpn evpn` shows routes from every leaf with the leaf's own
loopback1 as next hop, which is the route-map doing its job. Also on
the spine, `show running-config bgp | include retain` must show
`retain route-target all`, or the spine drops every EVPN route it has
no VRF for, which on a spine is all of them.

### 6. VXLAN and the VRFs

    show nve interface nve1 detail
    show nve vni
    show nve peers
    show vlan id 100
    show vrf red detail
    show ip route vrf red
    show interface vlan100 brief

nve1 up, source loopback1, host reachability BGP. Four VNIs up: 30000
and 30001 with their multicast groups, 50000 and 50001 as L3 bound to
red and blue. Three NVE peers, one per other leaf, once routes are
exchanged. VLAN 100 maps to segment 30000. VRF red carries VNI 50000
and its route table has 10.0.100.0/24 attached. Vlan100 is up in VRF
red with the anycast gateway address. `show ip mroute` now has a
(*, 239.1.1.1) and (*, 239.1.1.2) entry.

    show bgp l2vpn evpn route-type 5

Type-5 routes for 10.0.100.0/24 and 10.0.200.0/24 from every leaf.
That is the `tag 12345` on the SVIs and the redistribute route-map.

### 7. Endpoints on the overlay

Start red-endpoint and blue-endpoint. red-endpoint at 10.0.100.10
pings its gateway 10.0.100.1; blue-endpoint at 10.0.200.10 pings
10.0.200.1. Then on leaf1 and leaf2:

    show mac address-table vlan 100
    show ip arp vrf red
    show l2route evpn mac-ip all
    show bgp l2vpn evpn route-type 2

The endpoint's MAC learned on Ethernet1/7, its ARP entry in the VRF,
and a Type-2 route for it that every other leaf receives; on leaf3,
`show l2route evpn mac all` lists the MAC with leaf1's VTEP as next
hop. red-endpoint cannot reach blue-endpoint, since they sit in
different VRFs, which is the point of the two private networks the
Cilium step attaches to.
