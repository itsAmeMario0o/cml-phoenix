# labs/

One YAML topology per scenario, tracked. Passwords and SSH keys are
placeholders; `scripts/60-import-lab.sh` fills them and imports the lab.
ADR 0006 explains why.

## Importing a lab

1. Once: copy `config/labs.env.example` to `config/mcp-env/labs.env` and
   set `LAB_PASSWORD`. Every user in every lab gets this password.
2. With the controller up:

       scripts/60-import-lab.sh labs/cilium-evpn-blank.yaml

   The lab lands stopped. Start it from the UI, or ask cml-mcp to start
   the lab by title. Start the two spines first, then the leaves, then
   the hosts; six Nexus 9000v booting together on eight cores is slow.

The rendered copy sits in `exports/.rendered/` (gitignored) if you would
rather import through the UI.

## cilium-evpn-blank.yaml

Two Nexus 9000v spines, four leaves, an Ubuntu host with four fabric
facing interfaces for a kind cluster running Cilium, and two Ubuntu
endpoints hanging off leaf1 and leaf2. Adapted from
marinfer/cml-cilium-evpn-lab, with the Nexus Dashboard dependency
removed. The switches boot with a hostname, the admin user, a mgmt0
address, and the loader-prompt workaround. Everything else is yours to
build from the console or through cml-mcp: the underlay, VXLAN, the
VRFs, and the BGP session toward Cilium.

Sizing on the E16ds_v6 host: 84 GB of RAM against 128 and 18 vCPU
against 16. RAM is comfortable, CPU is oversubscribed until the
switches settle.

Management runs over the CML NAT connector, 192.168.255.0/24 with the
gateway at .1, so the kind host can reach the internet for Docker,
kind, kubectl, helm, and the cilium CLI.

| Node | mgmt address | user |
|---|---|---|
| spine1, spine2 | 192.168.255.50, .60 | admin |
| leaf1 to leaf4 | 192.168.255.51 to .54 | admin |
| kind-host | 192.168.255.5 on ens2 | kindops |
| red-endpoint | 10.0.100.10 on the fabric, no mgmt | cisco |
| blue-endpoint | 10.0.200.10 on the fabric, no mgmt | cisco |

Reaching the kind host from the Mac means going through the CML host as
a jump, since 192.168.255.0/24 lives inside the controller. For the kind
cluster itself, the source repo's `kind-config.yaml` binds the API
server to the host's management address; here that is 192.168.255.5.

The fabric itself, as plain NX-OS for the six switches, is in
`cilium-evpn-fabric/`, one file per device with the address plan in its
README. Paste it, push it, or use it as the answer key.

Cilium Enterprise is what makes the EVPN and private-network pieces
work, and it comes from Cisco's Artifactory devhub with a personal
token. Open-source Cilium peers BGP to the leaves but does not do EVPN.
The built edition of this lab, with the full fabric in day-0 config, is
tabled until the blank one has been worked through by hand.

## ftdv-cluster.yaml

Two Nexus 9300v in a vPC domain with routed uplinks to a cat8000v
edge, two Threat Defense Virtual nodes, one per Nexus, that form a
cluster under cloud-delivered management from the operator's Security
Cloud Control tenant, an inside host bonded across the pair, and an
outside host on the edge. No FMCv. Design, address plan, and the
platform rules it follows are in
`docs/superpowers/specs/2026-09-10-ftdv-cluster-lab-design.md`; the
Nexus and edge configuration is in `ftdv-cluster-fabric/`.

The FTDv admin password is `FTD_ADMIN_PASSWORD`, separate from the lab
password, because Threat Defense demands a special character and
blocks all configuration until it gets one. The FTDv day-0 registers
each node with cdFMC at first boot from
values in `config/mcp-env/labs.env`: `CDFMC_HOST`, and per node
`CDFMC_REG_KEY_FTD1`, `CDFMC_NAT_ID_FTD1`, `CDFMC_REG_KEY_FTD2`,
`CDFMC_NAT_ID_FTD2`. Security Cloud Control generates one CLI
registration key command per onboarded device, so onboard two devices
named ftd1 and ftd2 and copy each line's key and NAT ID. The import
refuses to render until all six are set. One timing rule learned the
hard way: a cdFMC registration key is live only briefly after SCC
generates it, so the day-0 values only register if the node boots
within minutes of generating them. The dependable sequence is boot
first, then generate the key in SCC and run `configure manager add`
at the console right away. About 15 vCPU and 48 GB.
The `ftdv-10-0-0` image has been on the data disk since 2026-09-10.

| Node | mgmt address | user |
|---|---|---|
| n9k1, n9k2 | 192.168.255.71, .72 | admin |
| edge | 192.168.255.73 | admin |
| ftd1, ftd2 | 192.168.255.81, .82 | admin |
| inside-host | 10.10.0.100 on bond0, no mgmt | cisco |
| outside-host | 203.0.113.100 on the edge LAN, no mgmt | cisco |

## ips-ha.yaml

Inline IPS on a Threat Defense HA pair. One Nexus 9300v as the switch,
a cat8000v edge as the internet with the inside gateway and a DHCP
scope, ftd1 and ftd2 in high availability each with an inline set
bridging VLAN 10 to VLAN 20, Kali and an Ubuntu server inside, two
Ubuntu servers outside. Managed by cdFMC; no FMCv. Spec:
`docs/superpowers/specs/2026-09-11-ips-ha-lab-design.md`. Replaces the
FTDv cluster lab, which could not run inline sets.

Every node boots configured. Needs `FTD_ADMIN_PASSWORD` and the five
cdFMC values in `config/mcp-env/labs.env`, and the `kali-2026-2` image
with its `kali` node definition on the controller
(`config/node-definitions/kali.yaml`). After both firewalls register:
in cdFMC add the HA pair with the failover link on GigabitEthernet0/0,
then the inline set from 0/1 and 0/2 on the pair, an allow-all access
control policy with an intrusion policy, deploy. Pair first, inline
set second, or both standalone units bridge the segments at once.

| Node | address | user |
|---|---|---|
| n9k1 | 192.168.255.71 mgmt0 | admin |
| edge | 192.168.255.73 mgmt, 10.10.0.1 inside gateway, 203.0.113.1 outside | admin |
| ftd1, ftd2 | 192.168.255.81, .82 mgmt | admin, FTD_ADMIN_PASSWORD |
| kali | DHCP from 10.10.0.100 | kali / kali |
| insrv | 10.10.0.10 | cisco |
| extsrv, esrv | 203.0.113.101, .251 | cisco |

From Kali, `nmap -sS 203.0.113.101` or a ping to 198.51.100.1 crosses
the active unit; pull the active unit's power in CML and the standby
takes over with its inline interfaces coming up.
