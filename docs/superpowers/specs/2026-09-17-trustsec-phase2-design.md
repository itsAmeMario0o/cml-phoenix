# TrustSec Phase 2: access switch, SGTs, FTD enforcement, and profiling

Status: draft for operator review, 2026-09-17. Nothing here is built yet.

Phase 1 (`2026-09-12-trustsec-phase1-routed-ise-design.md`) promised a
routed, no-NAT path to an external ISE with working CoA. That is now
proven end to end (STATUS, 2026-09-17). Phase 2 builds the demo on top of
it. The background, the dead ends, and the live findings that shaped this
design are in `2026-09-16-trustsec-phase2-cat9kv-profiling-plan.md`; this
document is the design itself.

## Goal

One lab, `labs/trustsec-phase2.yaml`, that demonstrates three things to
Cisco and to a customer moving off ForeScout and Arista:

1. **Identity to tag.** A wired endpoint gets a Security Group Tag from
   ISE by who or what it is: an employee by 802.1X, an agentless device by
   MAB plus profiling.
2. **Tag to enforcement, in two places.** The access switch enforces
   east-west between endpoints with SGACLs. A Threat Defense firewall
   enforces north-south toward a server by source SGT. Same tags, two
   enforcement points, no IP-based rules for the endpoints.
3. **Profiling as inventory.** ISE's view of an agentless endpoint,
   collected without an agent, set beside the operator's ForeScout sample
   and their five-step SNMP procedure.

Success is a repeatable demo: Kali and the employee PC send the same
traffic to the same server, the firewall drops one and passes the other,
and the only difference between them is the tag ISE assigned.

## What is already proven, and what is not

Proven live on 2026-09-17, so the design leans on it freely:

- `cat9000v-uadp` accepts every command this design needs: access
  switchports, `mab`, dot1x authenticator, `cts role-based enforcement`,
  static SGT maps, `cts manual` with `propagate sgt`, SXP, device-sensor,
  DHCP snooping, device tracking. Licensed `network-advantage` and
  `dna-advantage`.
- A switch at 10.100.0.3 on `bridge1` reaches ISE with RADIUS at its own
  address, MAB authorizes an endpoint on the first frame, and ISE's CoA
  reaches the switch and is ACKed.
- FTDv 10.0.0 registers to cdFMC when the key is generated after boot
  (LESSONS-LEARNED). Kali 2026.2 runs with its own node definition.

Not proven, and each is a gate in the build order below, with a fallback:

| Unknown | Why it matters | Fallback |
|---|---|---|
| The virtual Cat9000v enforces SGACLs in its software data plane. Cisco's page lists only basic L2, OSPF, SVIs, and VLANs as tested, at about 250 Kbps | East-west enforcement | Show classification and the matrix on the switch and in ISE; enforce everything on FTD |
| The switch downloads SGTs and SGACLs from ISE (CTS credentials, environment data) | Policy from ISE, not typed on the switch | Static `cts role-based permissions` on the switch |
| FTDv on KVM reads the inline SGT from a frame arriving on a virtio interface | North-south enforcement by tag | SXP from the switch to FTD for IP-to-SGT mappings |
| ISE's profiler probes can be switched on through an API | Policy as code | One documented GUI step per ISE deploy |

## Topology

```
ISE 10.20.2.20 (Azure, apps subnet)
      |  UDR, lab-transit-in and -out, no NAT
CML host, bridge1 10.100.0.1/24
      |
      |  Gi1/0/24, VLAN 100, SVI 10.100.0.3: RADIUS, CoA, SNMP
    sw1  cat9000v-uadp, the access switch and the only RADIUS client
      |  Gi1/0/1  emp-pc   ubuntu   802.1X    SGT 10 Employees
      |  Gi1/0/2  iot-dev  alpine   MAB       SGT 20 IoT
      |  Gi1/0/3  kali     kali     MAB       SGT 40 Unknown
      |
      |  Gi1/0/23, VLAN 10 untagged, cts manual, propagate sgt
    ftd1 FTDv, routed, cdFMC managed
      |    Gi0/0 inside  10.100.10.1/24, gateway for VLAN 10, DHCP server
      |    Gi0/1 servers 10.100.20.1/24
      |    Management0/0 on the NAT connector, 192.168.255.81, to cdFMC
      |
    srv  ubuntu 10.100.20.10, a web server and an SSH server
```

Eight nodes: the `bridge1` and NAT connectors, `sw1`, `ftd1`, and four
hosts. The three endpoints share VLAN 10 on purpose, so that traffic
between them never leaves the switch and only an SGACL can stop it.

Two choices worth stating:

- **No C8000v edge.** Phase 1 needed it as the RADIUS client. Here the
  switch sits on `bridge1` itself, the way `sw1` was proven today, and
  nothing in this lab needs routing beyond the transit /24: ISE talks to
  the switch, never to the endpoints. The host's route for the rest of
  10.100.0.0/16 via 10.100.0.2 stays in place and unused. The edge comes
  back when a second site or an SXP peer needs it.
- **ISE and the firewall never meet in v1.** FTD learns the tag from the
  frame, not from ISE. That keeps cdFMC-to-ISE pxGrid, which has to cross
  the internet to reach a cloud manager, out of the critical path. It is
  the first thing to add afterward.

## Address plan

| Segment | Prefix | Members |
|---|---|---|
| Transit, `bridge1` | 10.100.0.0/24 | host .1, `sw1` Vlan100 .3 |
| Endpoints, VLAN 10 | 10.100.10.0/24 | `ftd1` inside .1, DHCP pool .100 to .199 |
| Servers | 10.100.20.0/24 | `ftd1` servers .1, `srv` .10 |
| FTD management | 192.168.255.0/24 | NAT connector .1, `ftd1` .81 |

## Tags and policy

| SGT | Name | Assigned by |
|---|---|---|
| 10 | Employees | 802.1X, ISE internal user in group Employees |
| 20 | IoT | MAB, endpoint profiled into the IoT logical group |
| 40 | Unknown | MAB, no profile match. The default for anything agentless |
| 30 | Servers | Not assigned to an endpoint; named for the matrix and for v2 |

East-west on the switch, the SGACL matrix: Employees to IoT permit,
IoT to Employees deny, Unknown to anything deny, IoT to IoT deny.

North-south on FTD, access control rules by source SGT toward the server
network object: Employees allow HTTP and SSH, IoT allow HTTP only, Unknown
block with logging, default block. Destination stays a network object in
v1, because a destination SGT needs an IP-to-SGT mapping the firewall can
only get from SXP or pxGrid.

FTD needs to know the tag numbers to write those rules. Without ISE
integration, cdFMC takes them as custom Security Group Tag objects, three
objects created once in the manager. The inside interface gets "Propagate
Security Group Tag" enabled. Both are manager-side steps the runbook
section of the lab README will list, like the HA pair and inline set were
for the IPS lab.

Employee authentication is PEAP-MSCHAPv2 against an ISE internal user,
with the supplicant not validating ISE's self-signed certificate. That is
a lab shortcut and the README will say so. Active Directory and a real
certificate chain have their own draft spec
(`2026-09-13-active-directory-session-design.md`) and slot in later by
swapping the identity store; nothing in this design blocks on them.

## Profiling

Three feeds, all from the switch, none needing an agent or a span port:

- **RADIUS probe.** On by default. MAC, NAS port, and the MAB request
  itself.
- **Device sensor.** The switch gleans DHCP, CDP, and LLDP from the
  endpoint and sends them to ISE inside RADIUS accounting. This is Cisco's
  native answer to the inventory job, and it is why no DHCP relay toward
  ISE is needed even though the firewall is the DHCP server.
- **SNMP query probe.** ISE polls `sw1` at 10.100.0.3 for its MAC and
  interface tables, which maps onto the operator's five-step SNMP
  procedure. The existing `lab-transit-in` rule already allows it.

The demo artifact is ISE's endpoint record for `iot-dev` and for Kali,
read from Context Visibility or the ERS endpoint API, set beside the
ForeScout sample the operator already has. The honest expectation is most
of the identity and network attributes and none of the ones that need
credentials on the endpoint; the comparison table is a deliverable, not a
foregone conclusion. `iot-dev` is an alpine node with a DHCP hostname and
vendor class chosen to look like a device class ISE profiles out of the
box; Kali is left as it is, because "ISE does not know what this is, so it
gets Unknown" is the point.

## ISE policy as code

`scripts/lib/ise_config.py` grows to apply Phase 2 on every ISE deploy,
idempotent like the rest: the three endpoint SGTs plus Servers, the
SGACLs and the egress matrix cells, the Employees identity group with one
demo user, the `sw1` network device with its TrustSec and SNMP settings,
and the authorization rules that return a security group instead of
`PermitAccess`. The throwaway `trustsec-verify` identity the pyATS run
needs joins it, so the verification works on a fresh ISE without a manual
call. Each new object type gets its shape confirmed against the live node
before the code is written and a fake-API test after, the way the first
two were. The Phase 1 rules (`trustsec-poc`, `trustsec-poc-sw1`) are
replaced, not kept beside the new ones.

## Verification

`verify/trustsec-phase2/verify.py`, same layer as the two scenarios that
exist (ADR 0009), run by `scripts/80-verify-lab.sh trustsec-phase2`:

1. `sw1` shows the ISE RADIUS server up and `test aaa` returns
   Access-Accept.
2. Gi1/0/1 session: Authorized, method dot1x, SGT 10.
3. Gi1/0/2 and Gi1/0/3 sessions: Authorized, method mab, SGT 20 and 40.
4. `show cts role-based permissions` holds the matrix, and the deny
   counter moves when IoT pings Employees.
5. CoA: `show aaa clients` reads `CoA: requests` of at least 1 after the
   job asks ISE to reauthenticate one session through the monitoring API.
   This is the CoA check moved from the Phase 1 edge, where it can never
   pass, to the device where it can.
6. From the hosts: employee to `srv` on HTTP succeeds, Kali to `srv` on
   HTTP fails, both by the hosts' own `curl` exit codes.

ISE-side reads in the job use the monitoring API already used by hand
today (`AuthStatus/MACAddress`, `Session/ActiveList`). Firewall-side
evidence, connection events by SGT, stays a manual look in cdFMC.

## Sizing

| Node | Count | vCPU | RAM |
|---|---|---|---|
| cat9000v-uadp | 1 | 4 | 18 GB |
| ftdv | 1 | 4 | 8 GB |
| kali | 1 | 2 | 4 GB |
| ubuntu | 2 | 2 | 4 GB |
| alpine | 1 | 1 | 0.5 GB |
| total | 6 | 13 | about 35 GB |

The host has 20 vCPU and 157 GB, 133 GB free with today's two small labs
running. It does not fit beside the Cilium fabric's 84 GB comfortably;
run one or the other.

## Build order

Each step ends in a live check. A step whose unknown fails takes its
fallback from the table above and the build continues; nothing later
assumes an unproven step worked.

1. Topology file with day-0 for the switch and hosts, FTD booting
   unregistered. Gate: `sw1` answers `test aaa`, as today.
2. Sessions and tags. MAB for `iot-dev` and Kali, 802.1X for `emp-pc`,
   ISE returning SGTs. Gate: the three sessions show their tags.
3. Switch enforcement. CTS credentials and policy download, then the
   matrix. Gate: the IoT to Employees deny counter moves.
4. Firewall. Register to cdFMC, routed interfaces, DHCP, an allow-all
   baseline. Gate: all three endpoints reach `srv`.
5. Firewall by tag. Propagate SGT, the three tag objects, the rules.
   Gate: employee passes, Kali is blocked, and the event shows the tag.
6. Profiling. Device sensor and the SNMP probe. Gate: `iot-dev`'s ISE
   record carries DHCP and switch-port attributes; the comparison table
   gets filled in.
7. `ise_config.py` and the pyATS scenario catch up with what steps 2 to 6
   settled by hand, then one clean rebuild of ISE proves the code alone
   reproduces it.

## Out of scope

Active Directory and certificates (own spec). pxGrid or SXP between ISE
and the firewall, FTD high availability, the C8000v edge, a second site.
SD-Access. Anything in `terraform/`: Phase 2 is lab content and ISE
policy; the Azure side is finished as of today.

## Open points

- The switch needs an ADR when this is built (CLAUDE.md, definition of
  done): the Catalyst 9000v as the lab's access layer and FTDv inside CML
  as the tag enforcement point. ADR 0003's consequence still holds,
  inline tagging cannot cross the VNet; this design does not contradict
  it, it puts the firewall on the lab side of the VNet where the tag
  never has to cross.
- Which ISE profile `iot-dev` should imitate. A printer or an IP phone
  profiles cleanly from DHCP attributes alone; the operator's real
  environment may suggest a better one.
- The ForeScout sample and the five-step procedure exist as images in a
  past session only. They need to live in the repo, or be restated in
  text, before the comparison table can be written against them.
- cdFMC work is the operator's by hand, as with the IPS lab: device
  registration, interfaces, the three tag objects, the policy. The README
  section will list it in order.
