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

On a spine after both spines are done and the leaves are in:

    show bgp ipv4 unicast summary
    show bgp l2vpn evpn summary
    show ip pim rp

Each spine should show four underlay and four overlay sessions, one
per leaf. Each leaf should show two of each, one per spine, all
Established. On a leaf:

    show nve peers
    show bgp l2vpn evpn
    show ip route vrf red

`show nve peers` lists the other three VTEPs once a host is learned on
each. With the endpoints started, red-endpoint at 10.0.100.10 pings
its gateway, and blue-endpoint at 10.0.200.10 pings 10.0.200.1.
