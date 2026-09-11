# FTDv cluster behind a Nexus vPC pair

Status: draft, 2026-09-10. The `ftdv-10-0-0` image is on the data disk
and registered with the controller; no rebuild is needed.

## Goal

A lab where two Threat Defense Virtual nodes form a cluster managed by
the cloud-delivered Firewall Management Center in the operator's
Security Cloud Control tenant, sitting between an inside network and an
edge router, on a Nexus 9300v vPC pair with routed uplinks. The point is
to exercise vPC, ECMP toward a cluster in individual interface mode,
and cluster behaviour under asymmetric flows. No FMCv.

## What the platform allows

From Cisco's "Clustering for Threat Defense Virtual in a Private Cloud"
for the cloud-delivered management center:

- KVM is supported, which is what CML runs. Routed mode only.
- Data interfaces are individual interfaces. Spanned EtherChannel is
  not supported on virtual, and Threat Defense Virtual has no
  EtherChannel or redundant interface at all. So one node cannot be
  dual-homed at layer 2. The redundancy is the pair: node 1 on Nexus 1,
  node 2 on Nexus 2, inside VLANs that span the vPC peer link.
- The cluster control link is a dedicated interface on one subnet,
  carrying VXLAN, with MTU 154 bytes above the data interfaces.
- Every node runs the same version and performance tier. Management
  traffic uses the management interface only.
- Onboarding is by CLI registration key; the FTDv day-0 JSON has
  fields for the manager host, registration key, and NAT ID, so the
  registration happens at first boot. The node needs outbound 443 and
  8305 to the tenant, which the NAT connector provides.

The guide asks for CPU pinning on KVM. CML does not pin. For a lab
this is a performance note; start the two FTDv nodes last.

## Topology

```
                     +-----------+  Gi4  203.0.113.0/24  +--------------+
                     |   edge    |-----------------------| outside-host |
                     | cat8000v  |  Lo0 198.51.100.1     +--------------+
                     |  AS 65100 |
                     +-----------+
                 Gi2 /             \ Gi3
        10.0.1.0/30 /               \ 10.0.1.4/30
                   /                 \
     +----------------+  Po10 vPC   +----------------+
     |     n9k1       |=============|     n9k2       |   AS 65020
     |  VLAN 10, 20   |  peer-link  |  VLAN 10, 20   |   keepalive on mgmt0
     +----------------+             +----------------+
      e1/10  e1/11  e1/12            e1/10  e1/11  e1/12
        |      |      \                |      |      /
        |      |       \ vPC 20 bond  |      |     /
        |      |        +-------------+------+----+
        |      |        |     inside-host 10.10.0.100
        |      |
    Gi0/1   Gi0/2                  Gi0/1   Gi0/2
     +--------------+               +--------------+
     |    ftd1      |    Gi0/0      |    ftd2      |
     | 10.10.0.11   |----CCL--------| 10.10.0.12   |   ccl-switch, 10.99.0.0/24
     | 10.20.0.11   |               | 10.20.0.12   |
     +--------------+               +--------------+
          Mgmt0/0                        Mgmt0/0
              \                             /
               +------ mgmt-switch --------+------ NAT (192.168.255.0/24)
                 n9k1, n9k2, edge mgmt too
```

## Traffic path

VLAN 10 is inside. Its SVI lives in VRF INSIDE on both Nexus with an
HSRP gateway at 10.10.0.1, which is the host's default route. VRF
INSIDE's default route is two static routes, to 10.10.0.11 and
10.10.0.12, so the Nexus ECMP-hashes each flow to one cluster node.

VLAN 20 is outside. Its SVI lives in the default VRF, HSRP at
10.20.0.1, which is each FTDv's default route. The default VRF reaches
10.10.0.0/24 by two static routes, to 10.20.0.11 and 10.20.0.12,
redistributed into BGP so the edge learns it. The default VRF's own
default route comes from the edge over eBGP on the routed uplinks.

Forward and return can land on different nodes. That is deliberate:
the cluster redirects the return flow to its owner across the cluster
control link, which is the behaviour worth watching.

## Address plan

| Segment | Prefix | Addresses |
|---|---|---|
| Management (NAT) | 192.168.255.0/24, gw .1 | n9k1 .71, n9k2 .72, edge .73, ftd1 .81, ftd2 .82 |
| n9k1 to edge | 10.0.1.0/30 | n9k1 .1, edge .2 |
| n9k2 to edge | 10.0.1.4/30 | n9k2 .5, edge .6 |
| VLAN 10 inside, VRF INSIDE | 10.10.0.0/24 | HSRP .1, n9k1 .2, n9k2 .3, ftd1 .11, ftd2 .12, host .100 |
| VLAN 20 outside | 10.20.0.0/24 | HSRP .1, n9k1 .2, n9k2 .3, ftd1 .11, ftd2 .12 |
| Cluster control link | 10.99.0.0/24 | ftd1 .11, ftd2 .12 |
| Edge LAN | 203.0.113.0/24 | edge .1, outside-host .100 |
| Edge loopback | 198.51.100.1/32 | stands in for the internet |

The Cilium lab uses 192.168.255.5 and .50 to .60 on the same NAT
network, so these management addresses do not overlap if both labs
are ever up together.

Ports on each Nexus: Ethernet1/1 and 1/2 are the vPC peer link, 1/3
the routed uplink, 1/10 the FTDv inside, 1/11 the FTDv outside, 1/12
the host bond. vPC domain 10, peer keepalive between the mgmt0
addresses.

FTDv interfaces in CML: Management0/0 to the mgmt switch, slot 1 is
the node definition's placeholder and stays unconnected,
GigabitEthernet0/0 is the cluster control link, 0/1 inside, 0/2
outside.

## What is in the topology file and what is not

`labs/ftdv-cluster.yaml` follows the blank pattern of the Cilium lab:
the Nexus pair and the edge boot with hostname, admin user, and
management address only. The FTDv day-0 JSON is complete: hostname,
admin password, management address, DNS, routed mode, and the cdFMC
registration rendered from `config/mcp-env/labs.env`: `__CDFMC_HOST__`
shared, and a registration key and NAT ID per node, since Security
Cloud Control issues one key per onboarded device. The hosts boot addressed.

The switch and router configuration that makes the diagram work is
in `labs/ftdv-cluster-fabric/`, one file per device, for pasting or
pushing through cml-mcp. The cluster itself is built in cdFMC once
both nodes have registered: add the cluster, pick the CCL interface
and subnet, assign the interface address pools, deploy.

## Sizing

| Node | Count | vCPU | RAM |
|---|---|---|---|
| nxosv9000 | 2 | 4 | 24 GB |
| cat8000v | 1 | 1 | 4 GB |
| ftdv | 2 | 8 | 16 GB |
| ubuntu | 2 | 2 | 4 GB |
| total | 7 | 15 | 48 GB |

Fits the E16ds_v6 with the Cilium lab stopped. Not alongside it.

## Open points

- The tenant must hold FTDv entitlements and accept version 10.0.0.
- FTD enforces password complexity on the admin password, including a
  special character. A day-0 password that fails it is accepted for
  login but the node then forces a change before it will apply any
  configuration, registration included. Seen 2026-09-10; the topology
  now carries `__FTD_ADMIN_PASSWORD__` for the FTDv nodes.
- The unmanaged switch carrying the CCL must pass the larger MTU. CML's
  unmanaged switch has passed jumbo frames in the past; confirm with a
  ping of size 1600 across the CCL once the cluster is up.
- The day-0 registration fields have not been exercised against cdFMC
  from this kit. If they do not take, the fallback is the
  `configure manager add` line at each console.
