# TrustSec Phase 2: SNMP inventory first, then tags and enforcement

Status: draft for operator review, 2026-09-17, second revision. Nothing
here is built yet.

Phase 1 (`2026-09-12-trustsec-phase1-routed-ise-design.md`) promised a
routed, no-NAT path to an external ISE with working CoA. That is now
proven end to end (STATUS, 2026-09-17). Phase 2 builds the demo on top of
it. The background, the dead ends, and the live findings that shaped this
design are in `2026-09-16-trustsec-phase2-cat9kv-profiling-plan.md`; this
document is the design itself.

## Goal

One lab, `labs/trustsec-phase2.yaml`, told in two acts, for Cisco and for
a customer moving off ForeScout and Arista.

**Act 1, the same inventory job, natively in ISE.** The operator's
five-step procedure, exactly as pitched: no authentication changes on the
switches, no cloud services, standard SNMP. The switch is defined in ISE
with SNMP settings only, RADIUS untouched, and ISE builds a continuous
endpoint inventory from polling and traps. This act needs the switch and
the endpoints and nothing else, so it can be built, demonstrated, and
judged on its own.

**Act 2, what the same platform does next.** Once the customer is ready
to touch authentication: an endpoint gets a Security Group Tag from ISE
by who or what it is, the access switch enforces east-west with SGACLs,
and a firewall enforces north-south by source tag. Two firewalls can play
that part, one at a time: ASAv, driven from its own CLI, and Threat
Defense, driven from cdFMC. Kali
and the employee PC send the same traffic to the same server, the
firewall drops one and passes the other, and the only difference between
them is the tag ISE assigned.

Act 1 is the pitch. Act 2 is the reason to consolidate on one platform,
the "one system to keep, not two" on the slide.

## What is already proven, and what is not

Proven live on 2026-09-17, so the design leans on it freely:

- `cat9000v-uadp` accepts every command this design needs: access
  switchports, `mab`, dot1x authenticator, `cts role-based enforcement`,
  static SGT maps, `cts manual` with `propagate sgt`, SXP, device-sensor,
  DHCP snooping, device tracking, `snmp-server community`. Licensed
  `network-advantage` and `dna-advantage`.
- A switch at 10.100.0.3 on `bridge1` reaches ISE with RADIUS at its own
  address, MAB authorizes an endpoint on the first frame, and ISE's CoA
  reaches the switch and is ACKed. ISE can therefore also reach the
  switch on UDP 161; the same NSG rule covers it.
- 802.1X works end to end, with the method the design uses. An Ubuntu
  node running `wpa_supplicant` on a `sw1` access port authorized with
  PEAP and MSCHAPv2 against an ISE internal user, ISE's self-signed
  certificate not validated: ISE recorded passed, method dot1x, protocol
  PEAP (EAP-MSCHAPv2), 126 ms. EAPOL was captured on CML's link both
  ways, so the usual virtual-lab failure, a Linux bridge dropping EAPOL,
  does not apply to CML's fabric. The supplicant got its package over a
  second interface on the NAT connector, which is how `emp-pc` will be
  built.
- FTDv 10.0.0 registers to cdFMC when the key is generated after boot
  (LESSONS-LEARNED). Kali 2026.2 runs with its own node definition.

Not proven. Each is a gate in the build order, with a fallback, because
nearly every untested assumption in this lab has turned out wrong so far:

| Unknown | Act | Fallback |
|---|---|---|
| What ISE creates from SNMP alone. Polling is documented to read interfaces, CDP and LLDP neighbors, and ARP, but whether an endpoint record appears from polling alone or only after a trap names its MAC is not something to assume | 1 | Traps become required, not optional; say so in the comparison |
| The virtual switch emits link and MAC-notification traps. The slide itself says to verify trap support per platform | 1 | Polling only, with a shorter interval; record the latency cost |
| ISE's profiler probes (SNMPQUERY, SNMPTRAP) can be switched on through an API | 1 | One documented GUI step per ISE deploy |
| The virtual switch enforces SGACLs in its software data plane (Cisco lists only basic L2, OSPF, SVIs, and VLANs as tested, at about 250 Kbps) | 2 | Show classification and the matrix; enforce everything on FTD |
| The switch downloads SGTs and SGACLs from ISE | 2 | Static `cts role-based permissions` on the switch |
| `cts manual` on the virtual switch puts the tag on the wire, and a firewall on KVM reads it from a frame arriving on virtio. Tested on ASAv first, where a capture on the CML link and `show cts` on the ASA answer it in minutes | 2 | SXP from the switch to the firewall for IP-to-SGT mappings |

The 802.1X question was settled on 2026-09-17 on the running probe lab,
as step 0 of the build order, first with a Cisco supplicant and EAP-MD5
and then with the real thing, PEAP from Linux. It is in the proven list
above.

## Topology

```
ISE 10.20.2.20 (Azure, apps subnet)
      |  UDR, lab-transit-in and -out, no NAT
CML host, bridge1 10.100.0.1/24
      |
      |  Gi1/0/24, VLAN 100, SVI 10.100.0.3: SNMP, and in Act 2 RADIUS and CoA
    sw1  cat9000v-uadp: access switch, VLAN 10 gateway 10.100.10.1, DHCP server
      |  Gi1/0/1  emp-pc   ubuntu   Act 2: 802.1X   SGT 10 Employees
      |  Gi1/0/2  iot-dev  alpine   Act 2: MAB      SGT 20 IoT
      |  Gi1/0/3  kali     kali     Act 2: MAB      SGT 40 Unknown
      |
      |  VLAN 11, SVI 10.100.11.1/29, the firewall segment. Act 2 only
      |  Gi1/0/22 and Gi1/0/23, access VLAN 11, cts manual, propagate sgt
      |
      +-- asa1 ASAv, routed, local CLI            } one of the two runs
      |     Gi0/0 inside  10.100.11.2             } at a time; they hold
      |     Gi0/1 servers 10.100.20.1             } the same addresses
      +-- ftd1 FTDv, routed, cdFMC managed        }
      |     Gi0/0 inside  10.100.11.2
      |     Gi0/1 servers 10.100.20.1
      |     Management0/0 on the NAT connector, 192.168.255.81, to cdFMC
      |
    srv  ubuntu 10.100.20.10 behind an unmanaged switch both firewalls
         reach: a web server and an SSH server
```

Ten nodes: the `bridge1` and NAT connectors, `sw1`, `asa1`, `ftd1`, an
unmanaged switch in front of `srv`, and four hosts. Act 1 needs only `sw1`
and the three endpoints; the firewalls and server can stay stopped.

Three choices worth stating:

- **The switch is the VLAN 10 gateway, not the firewall.** The first
  draft had it the other way round. Step 3 of the procedure reads ARP to
  bind an IP to a MAC, and a pure layer 2 switch holds no ARP entries for
  its endpoints, so the inventory would have come back without addresses.
  Routed access is also the honest model: the customer's real fabric is
  VXLAN EVPN on IOS XE, which this lab does not build, and a routed
  access layer is its nearest plain equivalent. The operator's direction
  is to bias toward routed access and still be able to show switched
  access. The lab does both from one topology: `sw1` routes VLAN 10 by
  default, and the switched variant is the same switch with the SVI
  removed and the VLAN carried to the firewall, a day-0 option rather
  than a second lab. The inventory job is against the switches in either
  case. The three endpoints still share one VLAN on purpose: traffic
  between them never leaves the switch, so only an SGACL can stop it.
- **Two firewalls, same addresses, one running.** ASAv and FTDv both sit on
  VLAN 11 as 10.100.11.2 and both own 10.100.20.1 toward the server.
  Swapping the enforcement point is stopping one node and starting the
  other; the switch's route and the server's gateway never change. They
  must never run together, and the lab README will say so first. ASAv is
  there because it is the shortest path to proving the tag reaches a
  firewall: about 2 GB against 8, a local CLI that a day-0 file and pyATS
  can drive, and rules that take a tag number directly
  (`security-group tag 10`), so it needs neither a cloud manager nor any
  ISE integration. FTDv is there because it is what a Firepower customer
  runs. `asav-9-24-1` is on the base refplat ISO and joins
  `config/refplat.txt` the way the Catalyst 9000v images did.
- **No C8000v edge.** Phase 1 needed it as the RADIUS client. Here the
  switch sits on `bridge1` itself, as proven today, and ISE talks to the
  switch, never to the endpoints. The host's route for the rest of
  10.100.0.0/16 via 10.100.0.2 stays in place and unused. The edge comes
  back when a second site or an SXP peer needs it.
- **ISE and the firewall never meet in v1.** Either firewall learns the tag
  from the frame, not from ISE. That keeps cdFMC-to-ISE pxGrid, which has to cross
  the internet to reach a cloud manager, off the critical path. It is the
  first thing to add afterward.

## Address plan

| Segment | Prefix | Members |
|---|---|---|
| Transit, `bridge1` | 10.100.0.0/24 | host .1, `sw1` Vlan100 .3 |
| Endpoints, VLAN 10 | 10.100.10.0/24 | `sw1` Vlan10 .1, DHCP pool .100 to .199 |
| Switch to firewall, VLAN 11 | 10.100.11.0/29 | `sw1` Vlan11 .1, the running firewall's inside .2 |
| Servers | 10.100.20.0/24 | the running firewall's servers .1, `srv` .10 |
| FTD management | 192.168.255.0/24 | NAT connector .1, `ftd1` .81 |

## Act 1: the inventory job, step by step

The slide's five steps, and what each is in this lab.

| Step | In the lab |
|---|---|
| 1. Define the switches | `sw1` as an ISE network device with SNMP settings only: version, community, polling interval, link and MAC trap queries on. No RADIUS shared secret in Act 1; that absence is the point |
| 2. Group the estate | A network device group, `Location#All Locations#Lab` and a device type for access switches, with `sw1` in it, so policy and reports scope to exactly these switches |
| 3. Poll: SNMP Query | ISE's SNMPQUERY probe to 10.100.0.3 on UDP 161: system, interface state, VLANs, CDP and LLDP neighbors, ARP. The existing `lab-transit-in` rule already allows it |
| 4. Listen: SNMP Trap | ISE's SNMPTRAP probe. On `sw1`: link up and down traps, MAC notification on the three endpoint ports, `snmp-server host` pointing at ISE. Needs one new rule on `ise-nsg`, UDP 162 from 10.100.0.0/16 |
| 5. Read and publish | Context Visibility as the live inventory; the ERS endpoint API read by a script as the "feed it onward" proof. Syslog and pxGrid are named as options, not built |

The lab uses SNMP v2c with a community from `config/mcp-env/labs.env`
(`SNMP_COMMUNITY`, a placeholder in the tracked topology per ADR 0006).
The customer's estate may need v3; that changes the network device
settings and the switch lines, not the design.

Endpoints matter as much as the switch here. `iot-dev` is an alpine node
given a DHCP hostname and vendor class that look like a device class ISE
profiles out of the box, and an LLDP daemon if the image carries one, so
that the neighbor tables have something to say. Kali is left as it is,
because "ISE does not know what this is" is a result worth showing.

**The deliverable is a comparison table**, ISE's endpoint record beside
the operator's ForeScout sample, attribute by attribute: collected,
collected differently, not collected. The slide's honesty box stays in
it: ISE does not replicate SPAN-based traffic analysis, and if a flow map
is required that is Secure Network Analytics fed by flow telemetry, not
this. The table is a finding, not a foregone conclusion, and an empty
cell is a legitimate result.

## Act 2: tags and policy

Act 2 adds a RADIUS shared secret, TrustSec settings, and CoA to the same
network device Act 1 defined. Nothing from Act 1 is removed; SNMP keeps
feeding the profiler, and device sensor joins it, carrying DHCP, CDP, and
LLDP to ISE inside RADIUS accounting.

| SGT | Name | Assigned by |
|---|---|---|
| 10 | Employees | 802.1X, ISE internal user in group Employees |
| 20 | IoT | MAB, endpoint profiled into the IoT logical group |
| 40 | Unknown | MAB, no profile match. The default for anything agentless |
| 30 | Servers | Not assigned to an endpoint; named for the matrix and for v2 |

East-west on the switch, the SGACL matrix: Employees to IoT permit, IoT
to Employees deny, Unknown to anything deny, IoT to IoT deny.

North-south on the firewall, rules by source SGT toward the server
network object, the same policy on either one: Employees allow HTTP and SSH, IoT allow HTTP only, Unknown
block with logging, default block. Destination stays a network object in
v1, because a destination SGT needs an IP-to-SGT mapping the firewall can
only get from SXP or pxGrid.

On ASAv the policy is a few lines of ACL with `security-group tag`
matches and `cts manual` on the inside interface, all of it in the day-0
file, which makes ASAv the one enforcement point this lab can express
entirely as code and verify from its own counters. FTD needs the tag
numbers to write its rules. Without ISE integration, cdFMC takes them as
custom Security Group Tag objects, three objects
created once in the manager, and the inside interface gets "Propagate
Security Group Tag" enabled. Both are manager-side steps the lab README
will list in order, like the HA pair and inline set were for the IPS lab.

Employee authentication is PEAP-MSCHAPv2 against an ISE internal user,
with the supplicant not validating ISE's self-signed certificate. That is
a lab shortcut and the README will say so. Active Directory and a real
certificate chain have their own draft spec
(`2026-09-13-active-directory-session-design.md`) and slot in later by
swapping the identity store; nothing here blocks on them.

## ISE policy as code

`scripts/lib/ise_config.py` grows in two stages that match the acts, both
idempotent like the rest, and selectable so an Act 1 demo can run on an
ISE that has never heard of RADIUS for this switch:

- **Act 1**: the network device group, `sw1` with SNMP settings only, and
  the profiler probes if the API allows it.
- **Act 2**: the RADIUS secret and TrustSec settings on the same device,
  the four SGTs, the SGACLs and egress matrix cells, the Employees group
  with one demo user, the authorization rules that return a security
  group, and the throwaway `trustsec-verify` identity the pyATS run needs.

Each new object type gets its shape confirmed against the live node
before the code is written and a fake-API test after, the way the first
two were. The Phase 1 rules (`trustsec-poc`, `trustsec-poc-sw1`) are
replaced, not kept beside the new ones. `scripts/25-ise-up.sh` gains the
UDP 162 rule on `ise-nsg`.

## Verification

`verify/trustsec-phase2/verify.py`, same layer as the scenarios that
exist (ADR 0009), run by `scripts/80-verify-lab.sh trustsec-phase2`.

Act 1:

1. `sw1` answers SNMP from the host's side of the path, and its config
   carries the community, the trap host, and MAC notification on the
   three ports.
2. ISE holds an endpoint record for each of the three MACs, read through
   the ERS endpoint API, with a switch port and an IP address on it.
3. A port bounce on `sw1` shows up as a trap received by ISE.

Act 2:

4. `test aaa` from `sw1` returns Access-Accept.
5. Gi1/0/1 session: Authorized, method dot1x, SGT 10. Gi1/0/2 and
   Gi1/0/3: Authorized, method mab, SGT 20 and 40.
6. `show cts role-based permissions` holds the matrix, and the deny
   counter moves when IoT pings Employees.
7. CoA: `show aaa clients` reads `CoA: requests` of at least 1 after the
   job asks ISE to reauthenticate one session through the monitoring API.
   This is the CoA check moved from the Phase 1 edge, where it can never
   pass, to the device where it can.
8. From the hosts: employee to `srv` on HTTP succeeds, Kali to `srv` on
   HTTP fails, both by the hosts' own `curl` exit codes.

With ASAv running, the job also reads the firewall: the deny rule's hit
count moves when Kali tries, and the permit rule's when the employee does.

ISE-side reads use the APIs already used by hand today
(`AuthStatus/MACAddress`, `Session/ActiveList`, ERS). Firewall-side
evidence, connection events by SGT, stays a manual look in cdFMC.

## Sizing

| Node | Count | vCPU | RAM | Act |
|---|---|---|---|---|
| cat9000v-uadp | 1 | 4 | 18 GB | 1 |
| kali | 1 | 2 | 4 GB | 1 |
| ubuntu (`emp-pc`) | 1 | 1 | 2 GB | 1 |
| alpine | 1 | 1 | 0.5 GB | 1 |
| asav | 1 | 1 | 2 GB | 2 |
| ftdv | 1 | 4 | 8 GB | 2, instead of asav |
| ubuntu (`srv`) | 1 | 1 | 2 GB | 2 |
| total, FTDv running | 6 | 13 | about 35 GB | |
| total, ASAv running | 6 | 10 | about 29 GB | |

Act 1 alone is about 25 GB and 8 vCPU. The host has 20 vCPU and 157 GB.
The full lab does not fit comfortably beside the Cilium fabric's 84 GB;
run one or the other.

## Build order

Each step ends in a live check. A step whose unknown fails takes its
fallback from the table above and the build continues; nothing later
assumes an unproven step worked.

0. Done, 2026-09-17: 802.1X on the running probe lab. EAPOL passes, and
   PEAP from a Linux supplicant authorizes against ISE.
1. Topology file with day-0 for the switch and hosts, FTD present but
   stopped. Gate: endpoints get DHCP leases from `sw1` and `sw1` holds
   ARP entries for them.
2. Act 1, steps 1 to 3: the device group, `sw1` with SNMP only, the query
   probe. Gate: what ISE shows for the three endpoints from polling
   alone, written down whatever it is.
3. Act 1, step 4: traps on the switch, the probe in ISE, the NSG rule.
   Gate: a port bounce and a new MAC reach ISE.
4. Act 1, step 5: the ERS read and the comparison table against the
   ForeScout sample. Gate: the table is filled in, empty cells included.
   Act 1 is demonstrable here.
5. Act 2, sessions and tags: RADIUS and TrustSec added to the device, MAB
   for `iot-dev` and Kali, 802.1X with PEAP for `emp-pc`. Gate: three
   sessions with their tags.
6. Act 2, switch enforcement: CTS credentials, policy download, the
   matrix. Gate: the IoT to Employees deny counter moves.
7. Act 2, firewall by tag on ASAv: day-0 with the interfaces, `cts
   manual`, and the tag ACL. Gate: a capture on the CML link shows the tag
   in the frame, employee passes, Kali is blocked, and the ACL's hit
   counts say why.
8. Act 2, the same on FTDv, with ASAv stopped: register to cdFMC, routed
   interfaces, an allow-all baseline, then Propagate SGT, the tag objects,
   and the rules. Gate: the same two results, and the connection event
   shows the tag.
9. `ise_config.py` and the pyATS scenario catch up with what steps 2 to 8
   settled by hand, then one clean rebuild of ISE proves the code alone
   reproduces both acts.

## Out of scope

Active Directory and certificates (own spec). pxGrid or SXP between ISE
and the firewall, FTD high availability, the C8000v edge, a second site.
SNMP v3. Secure Network Analytics and any flow telemetry. SD-Access.
Nothing in `terraform/persistent` changes; the one Azure-side change is
the UDP 162 rule that `25-ise-up.sh` adds to the NSG it already owns.

## Open points

- This needs an ADR when it is built (CLAUDE.md, definition of done): the
  Catalyst 9000v as the lab's access layer and FTDv inside CML as the tag
  enforcement point. ADR 0003's consequence still holds, inline tagging
  cannot cross the VNet; this design does not contradict it, it puts the
  firewall on the lab side of the VNet where the tag never has to cross.
- Which ISE profile `iot-dev` should imitate. A printer or an IP phone
  profiles cleanly from DHCP attributes alone; the operator's real
  environment may suggest a better one.
- The five-step slide is restated in this document. The ForeScout sample
  still exists only as an image in a past session; it needs to live in
  the repo, or be restated in text, before the comparison table can be
  written against it.
- The customer's SNMP version and whether their Arista-to-Cisco cutover
  keeps the same communities or credentials. It does not change the lab,
  it changes what the demo can claim.
- cdFMC work is the operator's by hand, as with the IPS lab: device
  registration, interfaces, the three tag objects, the policy. ASAv needs
  none of it.
- ASAv's Smart Licensing. Unlicensed, ASAv runs rate limited, which does
  not matter at this lab's traffic levels, but the limit should be checked
  against 9.24 before relying on it.
