# 0003: Routed connectivity between lab nodes and the VNet, no NAT

Status: accepted, 2026-09-02

## Context

ISE and FTD will run as Azure VMs in the same VNet as the CML host. TrustSec
needs ISE to see each switch at its own address and to send Change of
Authorization back to it. Through NAT every switch looks like the CML host
and CoA has no return path. Bridging is impossible: the Azure fabric only
delivers frames to the IP and MAC pairs registered on a NIC.

## Decision

The CML host is a layer 3 hop. Lab nodes sit on a transit network on a
local bridge on the host, `10.100.0.0/24`, host at `10.100.0.1`. A C8000v
lab edge at `10.100.0.2` routes the rest of `10.100.0.0/16`. In Azure:

- The CML NIC has IP forwarding on and a static private IP, `10.20.1.10`.
- A route table on the apps subnet sends `10.100.0.0/16` to `10.20.1.10`
  as a virtual appliance next hop. Azure's fabric, not the guest routing
  table, makes this decision, so it must be a UDR.
- An NSG rule on the CML NIC allows the apps subnet to the lab summary on
  any port.
- Its mirror allows the lab summary out to the apps subnet. See the
  amendment below for why the default rules do not cover it.

Claude Code runs on the Mac only and reaches the controller API on the
static public IP through cml-mcp. Reaching ISE and FTD is by SSH forwards
through the CML host on port 1122, which doubles as the jump host.

This spec reserves the addresses and creates the route and NSG rule. The
bridge, the sysctl, and the C8000v are lab content for the TrustSec spec.

## Consequences

- No NAT anywhere in the path. CoA works, per-device identity works.
- Inline SGT tagging cannot cross the VNet. External FTD enforces on
  SGT-to-IP mappings from ISE via pxGrid or SXP, which is the normal cloud
  firewall pattern.
- The public IP is a persistent resource so the MCP config never changes.
- Port 1122 is the host shell on a CML machine, 22 is the console server.
  Every script uses 1122.

## Options considered

1. NAT mode, the upstream default. Rejected. It breaks CoA and collapses
   every switch into one identity.
2. Bridge mode. Rejected. Azure does not deliver frames to MACs it does not
   know about, and no amount of NIC configuration changes that.
3. Routed with a UDR. Chosen. Two routes in total, one in Azure and one on
   the host.
4. An overlay tunnel, C8000v to C8000v. Kept as a documented fallback in
   case the routed path surprises us.

## Amendment, 2026-09-17: the outbound rule, and what the host side became

The decision stands. Two things it did not foresee, both found on the
first live RADIUS test.

The NSG needs a rule in each direction. Azure's `VirtualNetwork` service
tag expands per NIC from that NIC's effective routes. The apps subnet has
the UDR for the lab summary, so ISE's NIC treats `10.100.0.0/16` as
VirtualNetwork and its default rules allow the reply. The CML subnet has
no such route, so on the CML NIC a forwarded packet with a lab source
matches neither `AllowVnetOutBound` nor `AllowInternetOutBound`, and
`DenyAllOutBound` drops it without ICMP or a log entry. The request was
visible leaving `eth0` and never reached ISE. `lab-transit-out` (lab
summary to the apps subnet, priority 410) sits beside `lab-transit-in` in
the fork's `modules/deploy/azure/main.tf`, under the same
`apps_subnet_cidr` condition. Inline SGT tagging still cannot cross the
VNet; that consequence is unchanged.

"A local bridge on the host" became a libvirt network in routed mode,
`transit` on `bridge1`, built by the fork's `06-transit.sh`. The name is
forced by the controller's connector scan, and libvirt is what gets the
bridge past firewalld on the host. The fork's `AZURE-LAB.md` documents all
four required pieces together; `docs/LESSONS-LEARNED.md` has the
diagnosis of each failure.
