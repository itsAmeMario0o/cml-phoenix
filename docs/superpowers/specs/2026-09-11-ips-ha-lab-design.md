# Inline IPS with a Threat Defense HA pair

Status: draft, 2026-09-11. Replaces the FTDv cluster lab of the day
before, which stopped at a design limit: a Threat Defense Virtual
cluster cannot run inline sets, and the operator wants an IPS lab.

## Goal

Two Threat Defense Virtual nodes as a high availability pair, each
with an inline set bridging an inside segment to an outside segment,
managed by the cloud-delivered Firewall Management Center in the
operator's Security Cloud Control tenant. A Kali box on the inside
attacks targets on the outside through the active unit; intrusion
events land in cdFMC; pulling the active unit fails over. A Nexus 9300v
is the switch. No vPC, no cluster, no FMCv.

## What the platform allows

- Inline sets are supported on Threat Defense Virtual in routed mode,
  and in high availability. They are not supported in a cluster, which
  is why the cluster lab was retired.
- In an HA pair only the active unit forwards through its inline set.
  The standby keeps its inline interfaces down, which is what stops the
  two bridges from forming a loop through the switch.
- The failover link is a dedicated interface between the two units. The
  stateful failover link can share it.
- Management stays on the management interface, on the NAT network,
  with outbound 443 and 8305 to the tenant.
- Custom images: CML takes any qcow2 through the dropfolder and the
  definitions API. Kali's official QEMU image has no cloud-init and
  boots with kali / kali asking for DHCP.

## Topology

```
                                       outside-switch
   edge  Gi3 203.0.113.1/24  ------------+----------+
   cat8000v                              |          |
   Lo0 198.51.100.1                   extsrv      esrv
     |                               .101        .251
   Gi2 10.10.0.1/24, DHCP for VLAN 10
     |
   e1/5 (VLAN 20)
 +-------------------------------- n9k1 -----------------------------------+
 | e1/1 v10   e1/2 v20        e1/3 v10   e1/4 v20        e1/6 v10   e1/7 v10 |
 +----|---------|-----------------|---------|----------------|---------|------+
   Gi0/1     Gi0/2             Gi0/1     Gi0/2            kali     insrv
 +---------------+             +---------------+          DHCP    10.10.0.10
 |     ftd1      |  Gi0/0      |     ftd2      |
 |  inline set   |---failover--|  inline set   |
 +---------------+             +---------------+
      Mgmt0/0                       Mgmt0/0
          \                            /
           +------- mgmt-switch ------+------ NAT 192.168.255.0/24
             n9k1 mgmt0, edge Gi1 too
```

VLAN 10 and VLAN 20 are the two halves of one IP subnet, 10.10.0.0/24.
The only path between them is through an inline set. The edge's Gi2
sits in VLAN 20 and is the gateway and DHCP server for everything in
VLAN 10, so Kali and insrv reach the outside servers only through the
active firewall. The standby's inline interfaces are down.

## Address plan

| Segment | Prefix | Addresses |
|---|---|---|
| Management (NAT) | 192.168.255.0/24, gw .1 | n9k1 .71, edge .73, ftd1 .81, ftd2 .82 |
| Inside, VLAN 10 and 20 | 10.10.0.0/24 | edge Gi2 .1, insrv .10, Kali by DHCP from .100 |
| Failover link | 10.99.0.0/24 | ftd1 .1, ftd2 .2, set in cdFMC |
| Outside LAN | 203.0.113.0/24 | edge Gi3 .1, extsrv .101, esrv .251 |
| Edge loopback | 198.51.100.1/32 | stands in for the internet |

Nexus ports: 1/1 and 1/2 ftd1 inside and outside, 1/3 and 1/4 ftd2
inside and outside, 1/5 edge, 1/6 Kali, 1/7 insrv. All access ports,
spanning-tree edge. FTDv: Management0/0 to the mgmt switch, slot 1
unconnected, GigabitEthernet0/0 failover, 0/1 inline inside, 0/2
inline outside.

## What is in the topology file and what is not

`labs/ips-ha.yaml` carries complete day-0 for every node this time,
since the switch and the router are scenery here: n9k1 boots with its
VLANs and ports, the edge with its addresses and DHCP scope, the hosts
addressed. The FTDv day-0 registers each node with cdFMC from the
same env values as before, with `__FTD_ADMIN_PASSWORD__` for the admin
user. Kali has no day-0 and takes DHCP.

Built in cdFMC after both nodes register: the HA pair (Devices, Add
High Availability, failover link on GigabitEthernet0/0), then on the
pair the inline set from 0/1 and 0/2, an access control policy that
allows all with an intrusion policy, and deploy. Order matters: pair
first, inline set second, or both standalone units bridge the segments
at once.

## Sizing

| Node | Count | vCPU | RAM |
|---|---|---|---|
| nxosv9000 | 1 | 2 | 12 GB |
| cat8000v | 1 | 1 | 4 GB |
| ftdv | 2 | 8 | 16 GB |
| kali | 1 | 2 | 4 GB |
| ubuntu | 3 | 3 | 6 GB |
| total | 8 | 16 | 42 GB |

## Open points

- The inside has no route to the real internet, only to the edge's
  loopback and the outside servers. Kali cannot update packages in
  this lab. A NAT on the edge toward its management interface would
  give it one; deferred.
- Kali's virtual disk size decides the node definition's boot disk
  size; checked with qemu-img before the image is registered.
- The 7z unpacker went onto the CML host with apt. It dies with the
  VM, and the extracted qcow2 goes to blob so the next build does not
  need it.
