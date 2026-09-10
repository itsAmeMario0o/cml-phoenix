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
