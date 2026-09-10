# FTDv cluster lab, fabric configuration

Day-1 configuration for the Nexus pair and the edge in
`labs/ftdv-cluster.yaml`, one file per device. No usernames or
passwords; day-0 already set those. The FTDv nodes are not here: their
day-0 registers them with cdFMC, and the cluster, interfaces, and
policy are built in cdFMC. Design and address plan:
`docs/superpowers/specs/2026-09-10-ftdv-cluster-lab-design.md`.

## Order

1. n9k1 and n9k2. The vPC forms once both have the peer link and the
   keepalive; `show vpc` should read peer adjacency formed ok and
   Po10 up before the rest matters.
2. edge. `show bgp ipv4 unicast summary` on each Nexus then shows one
   Established session, and `show ip route` a default route from BGP.
3. inside-host. `show port-channel summary` on either Nexus shows Po20
   with one member up, and `show vpc` lists vPC 20 up.
4. ftd1 and ftd2, last. They register with cdFMC over the NAT network.
   In cdFMC: add the cluster, cluster control link on
   GigabitEthernet0/0 in 10.99.0.0/24, inside on 0/1 with the pool
   10.10.0.11 to .12 and outside on 0/2 with 10.20.0.11 to .12,
   default route 10.20.0.1, then deploy.

## Traffic check

From inside-host, `ping 10.10.0.1` (HSRP), then `ping 198.51.100.1`
(through a cluster node to the edge), then `ping 203.0.113.100`.
On a Nexus, `show ip route vrf INSIDE 0.0.0.0` shows two next hops.
In cdFMC, the cluster's connection events show which node owns each
flow; flows that return through the other node are the cluster
control link at work.

## Through cml-mcp

`send_cli_command` with `config_command` set takes each file whole,
minus the `!` comment lines. The edge file is IOS XE and runs the same
way. Save with `copy running-config startup-config` on the Nexus and
`write memory` on the edge.
