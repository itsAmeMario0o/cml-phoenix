# The inventory job: ForeScout's output against ISE's, in this lab

TrustSec Phase 2, Act 1 (`docs/specs/2026-09-17-trustsec-phase2-design.md`).
The question the customer is asking: can ISE, from SNMP against the
switches and nothing else on the endpoints, produce the inventory ForeScout
produces today? This document holds the three things needed to answer it:
the ForeScout sample as the customer gave it, the operator's field by field
mapping to ISE, and what the lab produced on the dates shown. Cells that
say "not yet" are not yet, and stay that way until the lab shows otherwise.

## The ForeScout sample

Two hosts from the customer's environment, anonymised as received.

Host A, a Windows server:

    Operating System: Windows Server 2016
    Function: Server
    IPv4 Address: xx.xx.xx.xx
    DNS Name: abcd.net
    Windows Domain Member: No
    MAC Address: abcd
    NIC Vendor: HEWLETT PACKARD ENTERPRISE
    Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/5...
    Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) WindowsPowerShell/5.1...
    Open Ports: 1xx/TCP, 4xx/TCP
    NIC Vendor: VMWARE, INC.
    OS Class (Obsolete): Windows Machine
    OS Fingerprint: Windows Machine
    Matched Classification Profiles: Windows Server 2016

Host B, a Linux host on VMware:

    Classification
    Function: Computer
    Operating System: Linux
    Vendor and Model: VMware
    Class Vendor: VMware
    IPv4 Address: xx.xx.xx.xx
    Admission: Host Connected to a Switch Port
    DNS Name: abc.net
    MAC Address: asdcfvggg
    Macintosh Manageable (SecureConnector): No
    OS Fingerprint: 22/tcp OpenSSH 7.6p1 Ubuntu 4ubuntu0.7 Ubuntu Linux
    Windows SecureConnector Deployment Type: None
    Service Banner: 22/TCP: OpenSSH 7.6p1 Ubuntu 4ubuntu0...
    Windows Manageable SecureConnector: No
    Network Function: Linux Desktop/Server
    Number of Hosts on Port: 2
    Switch IP/FQDN: xx.xx.xx.xx
    Switch IP/FQDN and Port Name: xx.xx.xx.xx:Gia/b/c
    Switch Port ACL: (empty)
    Switch Port Action: (empty)
    Switch Port Alias: **** Port description ***
    Switch Port Configurations: <<port configuration>>

## The mapping

The operator's analysis, field by field against the ISE 3.5 administrator
guide, with the parity verdict as they scored it. The last column is the
lab's, and is filled only from what was observed.

| # | ForeScout field | ForeScout collects it by | ISE mechanism (admin guide) | Verdict | Lab, 2026-09-18 |
|---|---|---|---|---|---|
| 1 | IPv4 address, MAC address | switch ARP and CAM polls | SNMP Query probe: ARP (IP-MIB) and CAM (BRIDGE-MIB `dot1dTpFdbPort`) | Full | Shown. All three endpoints appear in ISE from SNMP alone within six minutes of their records being deleted, RADIUS untouched; MAC and switch port from the CAM read, IP for two of three (see row 13's note on the third) |
| 2 | NIC vendor | MAC OUI lookup | OUI attribute in the MAC dictionary | Full | Shown. With real vendor prefixes on the guests, ISE profiled `3C:D9:2B` as `HP-Device` on first sight. The lab's default `52:54:00` prefix maps to nobody, which is a virtual-lab artefact, not an ISE limit |
| 3 | DNS name | DNS lookup | DNS probe stores the FQDN as an endpoint attribute | Full | Not yet. The probe is on; the domain controller has no reverse zone for 10.100.10.0/24, so there is no name to find. A reverse zone with dynamic updates from the switch's DHCP is the fix |
| 4 | Operating system, OS fingerprint, matched profile | active scan plus fingerprint database | NMAP OS scan and SMB discovery | Full | Partly. `emp-pc` (Ubuntu) profiled as `Workstation` from its DHCP fingerprint alone. The NMAP OS scan is a Context Visibility action in the GUI (no API), not yet run |
| 5 | Service banner (22/TCP OpenSSH 7.6p1) | active service probe | NMAP custom scan with service version | Full | Not yet, same GUI action as row 4 |
| 6 | Open ports | active port scan | NMAP common and custom port scans | Full | Not yet, same |
| 7 | Windows domain member | directory query | Active Directory probe (`AD-Host-Exists`, `AD-Join-Point`, `AD-Operating-System`) | Full | Not applicable in this lab: no Windows endpoint yet. The probe is on and ISE is joined to `corp.rooez.com`; a Windows endpoint is the roadmap's Windows 11 item |
| 8 | HTTP user agent strings | passive traffic parsing | HTTP probe: direct 80/8080, SPAN, or portal redirect only | Gap | Agreed. Nothing in this design sends endpoint web traffic through ISE |
| 9 | Function, network function | classification engine | profiling policies and logical profiles | Full | Shown for two of three: `HP-Device` and `Workstation`. `kali` is unprofiled on purpose: it carries the lab's anonymous prefix and is the "unknown device" of Act 2 |
| 10 | SecureConnector manageable, deployment type | agent status | not applicable; ISE's equivalents are Secure Client and agentless posture | N/A today | Agreed; the customer deploys no agents |
| 11 | Admission (host connected to a switch port) | SNMP trap or poll | SNMP Trap probe (linkUp, linkDown, MAC notification) plus the SNMP Query it triggers | Full | Shown. Port bounces on `sw1` produced link traps (five counted on the switch) and ISE re-learned the endpoints on the trap-triggered query |
| 12 | Switch IP/FQDN and port name | switch poll | Context Visibility: network device name, NAD port ID | Full | Shown in the CAM read: each endpoint is bound to `sw1` and its `GigabitEthernet1/0/N`. Visible in the GUI's endpoint attributes, not in the API's endpoint object |
| 13 | Number of hosts on port | CAM count per interface | BRIDGE-MIB data; per-NAD endpoint count in Context Visibility | Partial | Agreed partial, with a lab note: ISE's learning is event driven. After a port bounce ISE bound an IP only to the endpoint that transmitted next; the other two kept their MAC and port and no IP for twelve minutes. The DHCP relay (below) removes the dependence on ARP timing |
| 14 | Switch port alias (description) | SNMP `ifAlias` or CLI | not on the profiler's allowed attribute list (`ifDescr` is, `ifAlias` is not) | Gap | Agreed. `sw1`'s ports carry descriptions ("emp-pc, Act 2 802.1X"); ISE shows the interface name, not the description. Catalyst Center or Nexus Dashboard territory |
| 15 | Switch port configuration | CLI scrape | not an ISE function | Gap | Agreed |
| 16 | Switch port ACL, switch port action | enforcement plumbing | dACL, filter-ID, CoA, ANC | N/A today | Agreed; empty in the customer's data too. This is Act 2 |

## What the lab did to get there, in the slide's six steps

The slide "The same inventory job, natively in ISE" has six steps. Here is
each one as it was done, with the day it was shown to work.

1. Define the switch. `sw1` in ISE as a network device with SNMP
   settings only: v3, user `ise-poll`, SHA and AES128, polling every 600
   seconds, link and MAC trap queries on. Over ERS, one call. RADIUS
   untouched: the Phase 1 device entry that held the same address was
   deleted first so nothing could answer RADIUS. Shown 2026-09-18.
2. Group the estate. Not done separately: the lab has one switch, and
   the default device groups scope it. A `Location` or `Device Type` group
   is one more field on the same ERS call when there are more.
3. Poll. The SNMPQUERY probe on the profiling node, with the switch
   configured for v3 (`snmp-server group ISE-POLL v3 priv`, a user with
   SHA and AES 128). ISE's own SNMP test against the switch succeeded on
   v3 and on v2c; the switch counted 56 get-requests within the first ten
   minutes. Shown 2026-09-18. The switch itself logs that v2c is a "legacy
   protocol" and asks for v3, which is the demo's line too.
4. Listen. The SNMPTRAP probe, with `snmp-server enable traps snmp
   linkdown linkup`, `snmp-server enable traps mac-notification change
   move`, `mac address-table notification change`, and `snmp trap
   mac-notification change added|removed` on the access ports, trap host
   ISE over v2c. Port bounces produced traps and trap-triggered queries.
   Shown 2026-09-18. v3 traps are the next thing to try.
5. Scan the endpoints. ISE 3.5's Endpoint SNMP Scan, driven over the
   API (`/api/v1/profiler/snmp/scan`, with `test`, `action` and
   `scan-history`). `emp-pc` carries an SNMP agent with the same v3 user
   for this. Shown 2026-09-18: a scan of 10.100.10.0/24 created and
   started over the API swept 254 addresses in about two minutes and
   discovered the two SNMP speakers on the VLAN, `emp-pc`'s agent and the
   switch's own VLAN address. What each answered is on the endpoint's
   attribute page in Context Visibility. Two traps on the way: the API's
   `subnets` element is `{subnetIp, mask}`, not a CIDR string, and the
   `testServer` address has to be the endpoint's current lease.
6. Read and publish. The endpoint list and each endpoint's IP and
   profile over the API (`/api/v1/endpoint`); the attributes SNMP
   collected (interface, CAM, ARP, CDP and LLDP where present) in Context
   Visibility. pxGrid and syslog to a SIEM are the roadmap's Splunk item.

Two additions beyond the slide made the result what it is:

- The DHCP relay. `ip helper-address 10.20.2.20` on the endpoint VLAN
  sends ISE a copy of every lease exchange while the switch keeps serving
  them. That is where `hp-printer-01`'s hostname and vendor class
  ("Hewlett-Packard JetDirect") and `emp-pc`'s DHCP fingerprint came from,
  and what profiled them. No RADIUS, no change on the endpoints. A real
  deployment has a DHCP server to relay to anyway.
- Real MAC prefixes. See row 2.

## What the customer should hear

- Rows 1, 2, 9, 11, 12 are shown in this lab from SNMP and DHCP relay
  alone, on a Catalyst 9000v, with nothing changed on the endpoints.
- Rows 4, 5, 6 need the NMAP scan, which is a click in the GUI today and a
  policy action in production; they were not run here yet.
- Rows 3 and 7 need what the customer already has (reverse DNS, a domain)
  and this lab does not yet.
- Rows 8, 14, 15 are gaps, and the operator's mapping already names where
  each one is answered (SPAN-based telemetry, Catalyst Center or Nexus
  Dashboard).
- The switch prefers SNMPv3 and says so in its log. ISE polls with v3 in
  this lab. Traps ran on v2c; v3 traps are the remaining test.
