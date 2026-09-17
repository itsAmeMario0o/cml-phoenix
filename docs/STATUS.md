# Status

A dated handoff log, newest entry first. Read it before doing anything else
at the start of a new session.

Entries before 2026-09-10 moved to `docs/STATUS-ARCHIVE.md` to keep this
file to what is still current.

## 2026-09-17, afternoon: first pyATS Phase 1 run, first MAB session, CoA proven

`scripts/80-verify-lab.sh trustsec-phase1` ran against a live lab for the
first time. RadiusServerReachable and RadiusAccessAccept pass: the C8000v
edge authenticated a real ISE internal user over the routed path.
CoAReceived fails at 0 on the edge, and that is accurate, not a bug: ISE
only sends a CoA for a live session, sessions are keyed by endpoint MAC,
and a router with no endpoints never has one. Three latent bugs fixed on
the way (PR #16): the pyATS console hop checked the operator's own
`known_hosts` and broke after every rebuild (now pinned to
`keys/known_hosts` by `gen_testbed.py`), IOS XE nodes were logged in to as
`cisco` instead of `admin`, and the CoA check used a command this image
rejects; the counters are under `show aaa clients` as `CoA: requests: N`.
The run needs a throwaway ISE identity: `trustsec-verify`, created over
ERS, credentials in gitignored `labs.env` as `TRUSTSEC_TEST_*`. ISE is
redeployed each session, so it has to be recreated each time until
`ise_config.py` learns to do it.

CoA was then proven where it can be, on the switch. On `sw1` in the
cat9kv probe lab, `authentication port-control auto` plus `mab` on
Gi1/0/1 authorized `ep1` (`5254.008b.adb0`) on the first frame: switch
side `Status: Authorized, mab Authc Success`, ISE side passed, method
mab, NAS 10.100.0.3, profile PermitAccess, 80 ms. That needed one more
ISE authorization rule, `trustsec-poc-sw1` (NAS-IP 10.100.0.3 to
PermitAccess), made with the existing `ensure_authorization_rule`; the
only rule before it matched the edge's address. With a real session to
act on, `GET /admin/API/mnt/CoA/Reauth/ise1/<mac>/1` returned
`results: true`, and the switch showed `CoA: requests: 1, Ack responses:
1`, 4 ms. Everything ADR 0003 set out to make possible now works: a
switch seen by ISE at its own address, no NAT, RADIUS both ways, and CoA
back to the right device. ISE's monitoring API is the useful window for
this work: `/admin/API/mnt/AuthStatus/MACAddress/<mac>/<secs>/<n>/All`
for the pass or failure reason, `/Session/ActiveList` for sessions.

The MAB port config and the `sw1` rule exist only on the running switch
and the running ISE. They are the seed of Phase 2's day-0 and policy,
not something to codify as they stand. Next: the Phase 2 spec, with FTDv
and Kali in the topology, SGTs in place of PermitAccess, and the CoA
check moved from the edge scenario to the switch.

## 2026-09-17, later: rebuilt, RADIUS answered, the routed path is proven

Rebuilt CML and ISE from nothing and closed the open problem. A lab
switch now gets a RADIUS reply from ISE: `sw1` sent an Access-Request at
11:45:51.507 UTC and received an Access-Reject (made-up user, the right
answer) 400 ms later. Switch, `bridge1`, host forwarding, Azure, ISE, and
the UDR return path are all proven for the first time.

The cause was Azure, not the host or ISE. The `VirtualNetwork` tag
expands per NIC from that NIC's effective routes, and only `snet-apps`
carries the UDR for 10.100.0.0/16. On the CML NIC a forwarded packet with
a lab source matched no default outbound allow and was dropped silently.
Proven with a RADIUS-filtered capture on ISE's own interface (zero
packets while the switch sent) and `list-effective-nsg`'s `tagMap` for
both NICs. Fix: `lab-transit-out` on the CML NSG, lab summary to the apps
subnet, now in the fork's `azure/main.tf` (`1ade9ae`). The operator added
the rule by hand to the running NSG, since the session's classifier
refuses NSG changes; it is not in that root's state, which is harmless
because teardown deletes the NSG.

Four more latent bugs surfaced on the way, all fixed with tests where
code was involved (PR #14): `06-transit-bridge.sh` was shipped to
`/provision` and silently skipped on its first cloud-init build, because
upstream `postprocess` only runs `[0-9]{2}-[[:alnum:]_]+\.sh` and the
second hyphen fails it, so the script is `06-transit.sh` now and ran by
hand from `/provision` this time; `25-ise-up.sh` read curl's doubled
`000000` as "ISE answered" at 0 seconds, then a front-end `502` as ready
at 28 minutes, so readiness now needs a status below 500; the expect
helpers checked the console server against the operator's own
`known_hosts` and died after the rebuild, so they use `keys/known_hosts`.
ISE's CLI is reachable with `keys/cml-lab` through the jump
(`ise1/iseadmin#`), and its capture syntax on 3.5 is `tech dumptcp
interface GigabitEthernet0 console filter "..." time-limit 1`.

Running now: CML (smoke test 12/12, cloudflared reinstalled,
`lab.rooez.com` back), ISE 3.5 at 10.20.2.20 with `ise-nsg`, all five
resources tagged, policy applied, `c8000v-edge` and `cat9kv-sw1` as
NADs, and two labs up: TrustSec Phase 1 and the untracked cat9kv probe
(`sw1` at 10.100.0.3, `ep1` on Gi1/0/1). Users recreated. Next: the pyATS
`trustsec-phase1` run, then the first MAB session on `ep1`'s port, then
the Phase 2 spec with FTDv and Kali.

## 2026-09-17, Catalyst 9000v live, transit bridge built, RADIUS one hop short

Both Catalyst 9000v flavors are on the controller without a rebuild:
uploaded to blob from the base ISO, then registered on the running host
through the dropfolder and the `POST /images/upload` API (PR #10,
LESSONS-LEARNED). A scratch lab "cat9kv probe" runs one `cat9000v-uadp`
as `sw1` at 10.100.0.3 with an alpine on an access port, and the CLI
probe accepted everything the design needs: switchport access mode,
MAB, dot1x authenticator, `access-session`, CTS enforcement globally
and per VLAN and interface, static SGT maps, `cts manual` inline
tagging with `propagate sgt`, SXP, device-sensor, DHCP snooping,
device tracking. `network-advantage` and `dna-advantage` are licensed.
`cat9kv-sw1` is a network device in ISE. The Cisco doc for the node
lists only basic L2, OSPF, SVIs, and VLANs as tested, so the functional
proof (a real MAB session, SGACL hits) is still owed.

The bigger finding: the routed path to ISE had never been built on the
host. The 2026-09-13 entry below said so ("the fork customize script
never landed") and I had read past it. No lab node could reach ISE and
the Phase 1 pyATS run had never executed. It exists now, after three
rounds on the live host: a netplan bridge named `br-transit` (the
controller's connector scan ignores any name that is not `bridgeN`,
`virbrN`, `vlanN`, or `localN`), then `bridge1` (firewalld on the CML
host rejected every forwarded packet with "administratively
prohibited"), then the shape that works, a libvirt routed network named
`transit` on `bridge1` with the /16 route to the edge in its XML, which
brings its own firewalld zone and policies. That is what
`06-transit-bridge.sh` in the fork does now, listed under
`app.customize`, with `tests/test_transit.sh` covering its dry-run
paths (PR #11, submodule bumped twice). The operator ran it by hand on
the live host each time, since the auto-mode classifier refuses remote
`sudo`; both labs' connector nodes point at `bridge1` and are up.

Proven with tcpdump on the host: the switch's RADIUS request arrives on
`bridge1` and leaves `eth0` toward ISE. Network Watcher confirms ISE's
route back is the UDR and its NSG allows the request in and the reply
out. Yet no reply ever returns. The untested hop is the CML NIC's
outbound NSG evaluation of a forwarded packet with a non-VNet source
(Azure's `test-ip-flow` refuses to model it), and the alternative is
ISE receiving and not answering. The next session starts from ISE's
side: RADIUS Live Logs through the `ise` tunnel, or `tech dumptcp` on
its CLI once the SSH key the Marketplace deploy was given is known
(SSH there is key-only; the try with `keys/cml-lab` was interrupted).
Full state, the exact next steps, and the Phase 2 topology with FTDv
and Kali added are in the Phase 2 note,
`docs/superpowers/specs/2026-09-16-trustsec-phase2-cat9kv-profiling-plan.md`.

Two things to carry forward. The rendered `config/cml.yml` secrets,
sysadmin's sudo password among them, appeared unmasked in this
session's tool output and an editor selection; rotate at the next
build. And a ping from the lab range to ISE can never succeed
(`ise-nsg` has no ICMP rule), so RADIUS is the only valid test of that
path; two hours went into learning that.

Torn down at 02:51 UTC after both PRs merged: all three labs exported
to blob under `exports/20260917T025148Z` (the cat9kv probe lab among
them, so its YAML survives even though it was never tracked), license
deregistered, 13 resources destroyed, persistent plan clean. The
teardown also destroyed the root's `random_password` secrets, so the
next `20-up.sh` rotates the admin and sysadmin passwords that leaked
into this session on its own. The next build ships
`06-transit-bridge.sh` through cloud-init for the first time; check
`/var/log/provision/06-transit-bridge.log` and the connector list
(`Bridge 1` on `bridge1`) before reimporting the labs, then the pyATS
`trustsec-phase1` run is the first thing to try. ISE came down right
after, all five resources: `45-ise-down.sh` needed two fixes first,
recorded in the same PR. az 2.89 refuses `--tag` with
`--resource-group`, so the tag query now filters by resource group in
JMESPath; and the portal deploy leaves the NIC (`ise1nic`) and public IP
(`ise1-ip`) untagged, so `25-ise-up.sh` tags them now and both were
tagged by hand this time so the teardown caught them. Next session
starts with nothing running in Azure but the persistent root; ISE is a
fresh portal deploy plus `25-ise-up.sh --post-deploy` again.

PRs #10 and #11 merged at session end: #10 (Catalyst 9000v in the reference platform)
and #11 (the transit bridge, the `bridge1` rename in the Phase 1 lab,
smoke test, and verify script, these lessons and this entry).

Superseded later the same day by the entry at the top of this file:
steps 1 to 5 were carried out, step 6's question is answered (the CML
NIC's outbound NSG, fixed as `lab-transit-out` in the fork), and the
script and its log are `06-transit.sh` and `06-transit.log` now. Kept
for the record of what was planned.

Next session, in this order (reviewed by `/code-review` before merge;
it caught the wrong Terraform root, the missing rescan, and three
omitted steps):

1. `scripts/00-preflight.sh`, then `scripts/20-up.sh`. Nothing is running
   in Azure but the persistent root, and the data disk already holds
   every image, both Cat9000v flavors included.
2. On the new host, before anything else: `/var/log/provision/06-transit-bridge.log`
   must contain `[06-transit-bridge] bridge1 holds 10.100.0.1/24` and
   `[06-transit-bridge] 10.100.0.0/16 routes via 10.100.0.2` and no
   `FAIL:` line (`postprocess` swallows the exit code, so the log is the
   only signal). This is the fork script's first run through cloud-init;
   it has only ever run by hand. Then `PUT /api/v0/system/external_connectors`
   to rescan, because `postprocess` runs after the controller's own
   startup scan and the script does not rescan for itself; only after
   that should `GET` list `Bridge 1` on device `bridge1`. Making the
   script issue that rescan (the way `04-customize.sh` talks to the API
   from postprocess) is a small fork change worth doing first.
3. `scripts/70-users.sh` (accounts and lab grants live on the disposable
   VM) and the cloudflared reinstall in `docs/ACCESS.md`, both needed
   after every rebuild.
4. `scripts/90-smoke-test.sh` (it checks `bridge1` now), then reimport
   `labs/trustsec-phase1.yaml` with `60-import-lab.sh`, and the cat9kv
   probe lab, which step 6 depends on (it is where `sw1` and `ep1` live;
   the Phase 1 lab has only the edge). The probe lab was never tracked;
   its only surviving copy is the blob export
   `exports/20260917T025148Z/cat9kv-probe-f13f801f-ab62-4436-a788-f04827ad6684.yaml`.
   Rerun `70-users.sh` after importing so the grants cover both labs.
5. ISE: portal deploy per `docs/ISE-MARKETPLACE-DEPLOY.md`, then
   `scripts/25-ise-up.sh --post-deploy`, which now tags the NIC and
   public IP too. Note which SSH public key the deploy is given; the ISE
   CLI is key-only and step 6 needs it. Re-add `cat9kv-sw1` (10.100.0.3)
   as a NAD, or fold it into `ise_config.py`. Then
   `scripts/80-verify-lab.sh trustsec-phase1`, the pyATS run that has
   never executed against a live lab.
6. The open question, from ISE's side first: does the switch's
   Access-Request reach ISE (RADIUS Live Logs through the `ise` tunnel,
   or `tech dumptcp 0 count 12` on its CLI). If not, the CML NIC's NSG is
   the suspect, and it lives in the fork, not the persistent root:
   `azurerm_network_security_group.cml` in
   `vendor/cloud-cml/modules/deploy/azure/main.tf`, next to the existing
   `lab_transit` inbound rule. An explicit outbound rule there for source
   10.100.0.0/16 to the apps subnet is a stop-and-ask vendor edit that
   takes effect on the next build. If ISE does see the request and stays
   silent, the Live Log drop reason says why. Only after RADIUS answers:
   the first MAB session on `ep1`, then the Phase 2 spec with FTDv and
   Kali (`docs/superpowers/specs/2026-09-16-trustsec-phase2-cat9kv-profiling-plan.md`).

## 2026-09-16, TrustSec Phase 2 scoped: profiling, and why it needs a real switch

Brainstormed folding ISE profiling into the TrustSec lab. The real goal
behind it: the operator has to show Cisco, and a customer, that ISE
profiling can approach ForeScout's current agentless NAC and inventory
capability, ahead of migrating a real environment off ForeScout/Arista
onto ISE/Cisco. A standalone Nexus/SNMP profiling proof was considered
and scrapped in favor of building profiling into the TrustSec lab
itself, since it belongs on the access layer either way.

That raised a real question rather than an assumed one: can the Phase 1
C8000v carry the access-layer story alone, or is a Catalyst 9000v
switch required. Tested live against the `edge` node's
GigabitEthernet2 instead of guessing: `switchport mode access` is
flatly rejected (no switchport concept on a router), while `mab`,
`dot1x pae authenticator`, and legacy `authentication port-control
auto` are all syntactically accepted. Testing the newer
`access-session port-control auto` (IBNS 2.0) tripped its own
irreversible CPL-conversion prompt, which resolved to its default
"yes" on its own from a stray keystroke in the test script before it
could be declined; GigabitEthernet2 now carries a converted
`access-session` config and an autogenerated `service-policy type
control subscriber POLICY_Gi2` in running-config only, interface still
down, nothing saved to startup, so a reload reverts it. Net finding:
confirms the operator's own instinct, a real Catalyst switch is needed
for genuine endpoint-facing NAC and profiling. The C8000v's role stays
what Phase 1 proved, RADIUS and CoA transport, not the access edge.

Checked what a Catalyst 9000v would actually cost before planning
further. Both flavors, `cat9000v-uadp` and `cat9000v-q200`, are already
on the downloaded `refplat-20260409-fcs.iso`, no new download needed.
Read both real node definitions off the ISO: both are true switches
with 24 physical switchports plus a management port, both run IOS-XE's
`cat9k` pyATS series, both point at the same Catalyst 9300 series
documentation. The only differences are RAM, 18 GB for UADP against 12
for Q200, and the ASIC each simulates. Leaning UADP, the ASIC family
behind real wiring-closet access switches, but that is not yet decided.

Also traced how new images actually reach a running lab, so the
teardown question has a real answer: uploading to blob
(`config/refplat.txt` plus `scripts/10-upload-images.sh`) is safe
against Azure storage alone and needs no CML VM running. A CML VM only
learns a new node definition at its own boot-time provisioning, so the
switch becomes available on the next ordinary teardown and rebuild,
which this environment already does every session; no special or extra
destroy is required.

Full findings, the live test output, and the open questions (UADP or
Q200, where the switch sits relative to the C8000v, what plays the
endpoint, how much of the operator's five-step SNMP profiling procedure
ISE can reproduce) are in
`docs/superpowers/specs/2026-09-16-trustsec-phase2-cat9kv-profiling-plan.md`.
No lab YAML, refplat, or node-definition file changed yet; brainstorming
is not done.

Also merged PR #7 and PR #8, both left open from the ISE deploy session
below, so `main` carries one clean line into the next session.

## 2026-09-16, ISE deployed and TrustSec Phase 1 policy live

ISE 3.5 deployed by hand through the Azure Marketplace portal, per
`docs/ISE-MARKETPLACE-DEPLOY.md`, at `10.20.2.20` (`ise1`, East US 2,
`Standard_D8s_v4`). `scripts/25-ise-up.sh --post-deploy` then completed
clean end to end: `ise-nsg` created and attached (RADIUS from the lab
summary, admin 443/22 from the CML host only), VM and disk tagged
`role=ise`, readiness confirmed through the CML jump, and the TrustSec
Phase 1 policy applied for real: `c8000v-edge` registered as a RADIUS
network device over ERS, the `trustsec-poc` authorization rule created
under the OpenAPI. `terraform -chdir=terraform/persistent plan` shows no
changes; the deploy didn't disturb `rt-apps`.

Getting there took two more real bugs in `scripts/lib/ise_config.py`,
neither ever exercised against real ISE before this deploy:

- `main()` defaulted the admin username to `"admin"`; the Marketplace
  image's account is always `iseadmin`, fixed by the deploy wizard, not
  customizable. Every ERS call 401'd with the correct password until
  fixed.
- The OpenAPI client assumed bare JSON arrays and flat rule objects.
  Real ISE 3.5 wraps everything in a `{"version", "response"}` envelope,
  and an authorization rule's own fields nest under a `"rule"` key
  alongside `"profile"`. Verified all three real shapes (GET policy-set,
  GET .../authorization, and an actual POST creating `trustsec-poc`)
  directly against the live node before writing the fix.

Also along the way: the repo's own `keys/known_hosts` had gone stale
(a different host key than the live CML host presents), breaking
`scripts/50-tunnels.sh`; fixed directly since that file lives inside the
repo. Added an `ise` entry to `config/tunnels.conf` (gitignored, not
previously created) forwarding local `8443` to ISE's admin GUI over
443, since ISE's private IP has no route from the Mac and all admin
access goes through the CML jump (ADR 0003): the NSG's admin rule only
allows the CML host's own address, not the Mac's, even via ISE's public
IP.

Not fixed, not needed for this phase: ISE raises a `DNS Resolution
Failure` alarm for its own FQDN (`ise1.rooez.com`, no public record
ever created for it). Cosmetic for a standalone lab node; acknowledged
and left as is.

## 2026-09-16, Cilium EVPN fabric verified live, pyATS layer fixed end to end

The operator finished pushing `BUILD-ORDER.md`'s seven layers onto all
six switches, by hand from iTerm over the console-server SSH path.
`scripts/80-verify-lab.sh cilium-evpn` then ran for real, for the first
time ever against this fabric: `common_setup`, `BgpEvpnNeighborsEstablished`,
and `VnisUp` all `PASSED`, 100% success rate. Genie-parsed, not raw text,
so this is a real independent confirmation the fabric is correct, not
just that the operator's own `show` commands looked right.

Getting there took five bug fixes to the pyATS layer itself, all latent
since ADR 0009 landed and never caught because nothing had run this
layer live before now:

- AEtest never discovers a `CommonSetup`/`CommonCleanup` subclass that
  is merely imported, not defined, in the testscript's own module.
  Both scenarios' shared-code pattern hit this; setup and cleanup
  silently never ran. Fixed with a thin local re-declaration per
  scenario.
- `scripts/80-verify-lab.sh` invoked `easypy` by its full venv path,
  which never puts the venv's `bin/` on `PATH`; `easypy`'s own pre-job
  plugin shells out to the bare `pyats` command and aborted every run
  before any testcase started. Fixed.
- `gen_testbed.py` wrote out CML's `/pyats_testbed` export unmodified.
  That export always leaves the `terminal_server` proxy device (the
  console server every connection tunnels through) as a
  `change_me`/`change_me` placeholder, and separately defaults every
  real device's own credentials to a generic `cisco`/`cisco` guess,
  wrong for the NX-OS switches (`admin`) and for `kind-host`
  specifically (`kindops`, not `cisco`, per `labs/README.md`'s node
  table). Fixed with two patch steps and `LAB_PASSWORD` wired in from
  `labs.env` (already sourced, no script changes needed). The
  `kind-host` case needed connecting to each device individually with
  verbose output to catch, since the generic fix alone still failed.
- `VnisUp` assumed every NX-OS device runs NVE. The spines
  route-reflect EVPN but never terminate a VTEP, so `show nve vni`
  does not exist there at all. Fixed by skipping a device where the
  command itself is unsupported instead of erroring the whole check.

All five fixes are on `main`, each with new unit tests. Along the way,
corrected an earlier answer given in chat: the red/blue endpoint
password is `LAB_PASSWORD` in `config/mcp-env/labs.env`, not
`LAB_USER_PASSWORD` (the shared human CML-login password); the two were
conflated when originally asked.

Next: an ISE deploy, by hand through the Azure portal per
`docs/ISE-MARKETPLACE-DEPLOY.md` (ADR 0008 amendment; the automated
`az deployment group create` path stays retired). `config/mcp-env/ise.env`
is already fully populated from earlier work; no ISE resources exist in
Azure right now (`role=ise` tag search is empty). The Cilium-BGP-peering
step from `BUILD-ORDER.md`'s closing section, and the Cloudflare tunnel
token rotation from 2026-09-11, are still open and unrelated to this.

## 2026-09-15, fabric build in progress, console access confirmed by terminal

`labs/cilium-evpn-fabric/BUILD-ORDER.md` merged after a rework: it now
carries the actual per-device config for each of the seven layers,
split out of the tracked `.cfg` files by dependency instead of by
device, plus a section on where spine and leaf actually differ (almost
nowhere among the four leaves; the one real divergence is the step 7
access port, leaf1 red, leaf2 blue, leaf3/leaf4 neither).

Confirmed CML's console server works from a plain terminal, no browser
needed: `ssh admin@<ip>` on port 22 (not 1122) drops into a `consoles>`
menu (`list`, `open`, `view`); passing the target straight on the SSH
command line, `ssh -t admin@<ip> "open /<lab>/<node>/<line>"`, skips
the menu and connects directly. That is now the documented path for
working the fabric build from iTerm, one pane per node, `Session >
Broadcast Input` sending identical config (steps 1, 4, and the whole
of step 6) to every leaf pane at once.

The operator is pushing the fabric config now, by hand, following
`BUILD-ORDER.md` layer by layer. Not done as of this entry. Next: once
all seven layers are in on all six switches, `scripts/80-verify-lab.sh
cilium-evpn` for its first real live run.

## 2026-09-15, full teardown/rebuild cycle, tooling gaps found and fixed

Ran the full cycle for real: `scripts/40-down.sh` then `scripts/20-up.sh`,
both clean. Teardown exported both labs to blob, deregistered the Smart
License (`NOT_REGISTERED`), destroyed all 13 `vendor/cloud-cml` resources;
persistent untouched. Rebuild found persistent unchanged (0 add/change/
destroy) and cloud-cml added 13 resources back on the same static IP,
`20.114.184.195`. License re-registered automatically (`COMPLETED` /
`IN_COMPLIANCE`), confirmed against the live API afterward.

Preflight itself needed fixing first. The Terraform provider caches under
`.terraform/providers/` in `terraform/bootstrap`, `terraform/persistent`,
and `vendor/cloud-cml` had gone stale as OneDrive cloud-only placeholders
(`du` showed 0 blocks against a 229 MB provider binary), which
`terraform validate` surfaced as a `stale NFS file handle` read error, not
just slow hydration. Fix: `rm -rf` each `.terraform` and reinit. Unrelated
to any repo code; worth checking first if a terraform command hangs or
errors oddly on this Mac again (LESSONS-LEARNED).

`cml-mcp` was not connected for this whole session. `scripts/mcp-cml.sh`
refuses to start without `config/mcp-env/cml.env`, which `20-up.sh` only
writes at the end of a build, so the MCP server had already failed at
session startup, before that file existed. Lab import, node start, and
user provisioning all went through the CML REST API directly instead.
Reconnecting the MCP session after a rebuild, once `cml.env` exists again,
should be routine from here.

Reread the pyATS verification layer (ADR 0009) end to end rather than
assume: it is verify-only, `device.parse()` calls only, nothing that
configures a device, and it has never actually been run against a live
lab anywhere in this repo's history (no report archives anywhere; the
09-13 entry below already said as much). The 2026-09-11 entry below
claiming the fabric was "verified" predates pyATS's existence by two
days, so that was a manual check, not this tooling. Pushing the fabric's
BGP/VXLAN/EVPN config onto the switches stays a manual, by-hand step by
design. New: `labs/cilium-evpn-fabric/BUILD-ORDER.md`, the ground-up
dependency chain behind the existing README's design and verification
tables, meant as the reference for that push. PR #1, open, not yet
merged.

`labs/cilium-evpn-blank.yaml` reimported and all 11 nodes booted (spines,
then leaves, then hosts, via direct API calls since cml-mcp was down). No
fabric config pushed yet; the switches carry only day-0 hostname/admin/
mgmt0.

The Cloudflare tunnel broke on the rebuild exactly as `docs/ACCESS.md`
warns it will: `cloudflared` lives on the disposable VM, and reinstalling
it after every rebuild is still a manual step, not yet automated. Also
hit the known stale-SSH-host-key issue from LESSONS-LEARNED, cleared by
hand with `ssh-keygen -R "[20.114.184.195]:1122"`. Reinstalled
`cloudflared` with the existing tunnel token; verified end to end, DNS
resolves to Cloudflare and `lab.rooez.com` correctly redirects to the
Access login page. Token rotation is still the open item from 2026-09-11,
not done here, since the existing token still works.

`scripts/70-users.sh` rerun; the same five accounts came back (all
admin), matching the Cloudflare Access policy's email list.

Still owed: push the fabric config from `BUILD-ORDER.md`, then
`scripts/80-verify-lab.sh cilium-evpn` for its first real live run. Also
open: merge PR #1, rotate the Cloudflare tunnel token.

## 2026-09-13, pyATS lab-verification layer landed

A pyATS lab-verification layer (ADR 0009) landed on the `pyats-and-ise-pivot`
branch and merged to `main`. It is a `verify/` tree with its own pinned venv
(`verify/requirements.txt`, `pyats[full]==26.8`, gitignored `verify/.venv`),
so the core kit stays stdlib only. `verify/lib/gen_testbed.py` (stdlib) pulls
a lab's pyATS testbed from CML at verify time; `scripts/80-verify-lab.sh
<scenario>` generates the testbed and runs the scenario's easypy jobfile in
the venv. Two verifications shipped: `verify/cilium-evpn/` (BGP EVPN sessions
Established, all VNIs up) and `verify/trustsec-phase1/` (the C8000v edge:
RADIUS reachable, `test aaa` Access-Accept, CoA received). Preflight warns,
without failing, when the venv is absent.

Not run yet, the human-gated step: bootstrap the venv
(`python3 -m venv verify/.venv && verify/.venv/bin/pip install -r
verify/requirements.txt`), then `scripts/80-verify-lab.sh cilium-evpn`
against the running Cilium fabric. The TrustSec verification runs once that
lab is deployed. Both AEtest scripts carry documented verify-at-live
assumptions (Genie parser keys, the `os` testbed tags, the `show aaa
servers` parse, `radius` vs `ISE-GROUP`, the CoA counter command), and the
TrustSec run needs `TRUSTSEC_TEST_USERNAME` / `TRUSTSEC_TEST_PASSWORD`
exported (a throwaway ISE test identity; see `config/labs.env.example`).

The same branch also carried the ISE deploy pivot reconciliation, below.

## 2026-09-13, ISE deploy: automated ARM fails, pivot to the portal

The first real ISE deploy ran `scripts/25-ise-up.sh`. The NSG and the VM
were created, but the VM reached a terminal `OSProvisioningTimedOut` state
and ISE never served: TCP 443 never opened in about 50 minutes, and Azure
marked the VM non-recoverable. The ISE appliance image does not complete
Azure's OS-provisioning handshake, so `az deployment group create` fails
even though the portal's Marketplace flow deploys the same image and lets
ISE boot. This matches the operator's cross-project experience: ISE deploys
by hand, not through provisioning tools.

All ISE resources were deleted. The persistent root stayed clean: `rt-apps`
is still associated with `snet-apps` and `terraform -chdir=terraform/
persistent plan` shows no changes, so the failed deploy left nothing behind.

The deploy step is now by hand through the portal, documented with our
environment's fields in `docs/ISE-MARKETPLACE-DEPLOY.md`. The automated
`az deployment group create` path in `25-ise-up.sh` is retired for the
create (ADR 0008 amendment); the NSG, tagging, readiness, policy, and
teardown tooling still apply after the portal deploy.

Two directions were set, both deferred and on the roadmap (items 18 and 19):
adopt the `cisco.ise` Ansible collection as the default ISE config layer,
and use the ISE Eternal Evaluation (ISEEE) patterns to make a per-session
ISE practical. Also in flight: a pyATS lab-verification layer (ADR 0009 and
a spec) on the `pyats-and-ise-pivot` branch.

## 2026-09-13, TrustSec Phase 1 and ISE by the Azure solution template

> Superseded on the ISE deploy method by the newer 2026-09-13 entry above:
> the `scripts/25-ise-up.sh` `az deployment group create` deploy described
> here was retired (ISE terminally fails Azure OS provisioning). ISE is now
> deployed by hand through the portal (ADR 0008 amendment;
> `docs/ISE-MARKETPLACE-DEPLOY.md`). The rest of this entry still holds.

The TrustSec Phase 1 foundation and a new ISE deploy method landed on the
`trustsec-phase1` branch and merged to `main`. Nothing has been deployed to
Azure yet; this is code and docs, ready to run.

What is in the kit now:

- ISE deploys from Cisco's Azure Marketplace solution template, not the raw
  VM image (ADR 0008). The earlier VM-image path kept failing to boot; the
  cause was a hand-rolled user-data file with the wrong NTP key and address
  keys ISE on Azure does not accept. `scripts/25-ise-up.sh` now runs
  `az deployment group create` against `config/ise/template.json`, ISE 3.5
  (`cisco-ise_3_5`, `3.5.527`), with a scoped NSG, a static `10.20.2.20`, our
  SSH key, and the admin password rendered into a `0600` parameters file.
  `scripts/45-ise-down.sh` deletes every `role=ise` resource. ISE keeps a
  Standard public IP for outbound to Security Cloud Control and Entra;
  operator and policy access go through the CML host jump, so a changing
  operator IP never matters.
- ISE policy is code (`scripts/lib/ise_config.py`): the C8000v edge as one
  network device over ERS, one authorization rule over the ISE OpenAPI.
- The Phase 1 proof topology is `labs/trustsec-phase1.yaml` (a C8000v edge as
  the RADIUS client), and the post-build smoke test now checks the host
  transit bridge.

Not yet done, the human-gated deploy lane:

- The host transit bridge itself is not built. The fork customize script
  `06-transit-bridge.sh` and its wiring under `vendor/` were left for the
  gated deploy and never landed. Without it the lab-side RADIUS path from
  `10.100.0.0/16` to ISE does not exist yet. This is the first real step.
- No real ISE deploy has run. When it does, verify two things: that the
  Cisco template's subnet write did not drop the `rt-apps` route-table
  association (ADR 0003), by checking `terraform -chdir=terraform/persistent
  plan` shows no changes, and that the ISE OpenAPI authorization-rule payload
  shape matches the live 3.5 node. Both are recorded in ADR 0008 and the
  `ise_config.py` comments.

Also new: roadmap item 16, reclaiming cloud-manager licenses at teardown
(near-term, cdFMC first), and item 17, an optional Azure Bastion.

## 2026-09-11, current state

Both labs are on the controller and reachable through the front door.

- Cilium EVPN fabric: running. The six-switch eBGP EVPN fabric is
  deployed and verified, every BGP session established and all four VNIs
  up. The kind host and the Cilium install are the hands-on work left,
  done inside the lab.
- Attack Lab, inline IPS: all eleven nodes up, and both FTDv are
  registered to cdFMC (Completed). The HA pair and the inline set are
  not built yet; ftd1 still shows failover Disabled and no inline set,
  so VLAN 10 and 20 stay separate and Kali has no DHCP. Building the
  pair and the inline set in cdFMC is the one step left before the lab
  is fully live.

Access and users:

- Five people created, all admin, each with the shared LAB_USER_PASSWORD.
  The Cloudflare Access policy now lists all five emails, four cisco.com
  and one gmail, so the front door is open for them.
- The Zero Trust team domain was renamed from money-honey to rooez, so
  the login page now reads rooez.cloudflareaccess.com. The tunnel and the
  server were untouched, and lab.rooez.com is unchanged.
- The end-user guide is published as a GitHub Pages site at
  https://itsamemario0o.github.io/cml-phoenix/, linked from the top of
  the README. docs/USER-GUIDE.md is the source, docs/index.html the page.

Still worth doing:

- Finish the FTD HA pair and inline set in cdFMC.
- Rotate the Cloudflare tunnel token, which passed through a chat session.

## 2026-09-11, afternoon

Rebuilt in the afternoon: preflight 55 OK, 13 resources, API ready
about a minute after the build printed its URL, smoke test 10 OK on
the first run this time, connector installed over SSH with four
connections, front door answering. The persistence hook kept all
twelve images, Kali and FTDv included, and both custom definitions
were still registered. Both labs reimported with `60-import-lab.sh`
and the IPS lab is starting, firewalls last.

Registration solved by the operator: the cdFMC registration key is
live only briefly after SCC generates it. Delete the manager on the
console, generate the key, add the manager within a minute, and both
firewalls registered (LESSONS-LEARNED). Both FTDv nodes are Completed
in cdFMC. Next in cdFMC: HA pair on GigabitEthernet0/0, inline set
from 0/1 and 0/2 on the pair, allow-all access control policy with an
intrusion policy, deploy. Then Kali gets DHCP and the IPS lab is live.

Evening check of everything but the firewalls: all eleven nodes
BOOTED; the edge holds its three addresses and loopback and its DHCP
pool has a lease at 10.10.0.100, which means a request crossed VLAN
10 to VLAN 20 through an inline set, so the pair is forwarding. The
Nexus and the four hosts could not be checked from the console this
time: cml-mcp's proxy is blocked by the stale host key in the Mac's
`~/.ssh/known_hosts` (LESSONS-LEARNED), an expect runner through the
console server handled the IOS XE prompt but not the NX-OS and Linux
ones, and the Mac ran out of memory mid-sweep. Their configuration is
day-0 and was verified after the first import. The lab was renamed
in the UI to "Attack Lab - Inline IPS, FTD HA pair"; the console
server paths use that title.

User provisioning revamped (ADR 0007, revised). The CSV is now keyed on
email, since a person logs in to CML with the same address Cloudflare
Access checks, so `email` is the CML username. Columns are email,
fullname, role. `scripts/70-users.sh` creates each user, then puts every
non-admin in one managed group (`lab-users`) that holds lab_exec on
every lab on the controller, so one run gives everyone every lab and a
rerun after importing a lab grants it too. Verified live: a probe user
was created, logged in, and saw both labs under show_all (the UI's
default). Passwords: set LAB_USER_PASSWORD in config/mcp-env/labs.env to give every user the same simple login, or leave it empty to generate one per user; either way they land in the private sheet. CML wants at least 8 characters and rejects common words (labpass1 works, 12345678 does not). This is separate from LAB_PASSWORD, the device login, which is untouched. Verified live: a shared-password user logged in and saw both labs. On 2026-09-11 the five real users in users.csv were created, all role admin (mpipher, gsicari, javigar2, mingktan cisco.com, plus mruiznet gmail.com), each with the shared password; the sheet is at config/mcp-env/users-credentials.csv. All admin, so the lab-users group is empty and the grant is moot; admins see every lab. Still owed: add those five emails to the Cloudflare Access policy, and the gmail one needs an explicit entry since the policy admits cisco.com by domain. The end-user walkthrough is docs/USER-GUIDE.md, also published as a shareable page: https://claude.ai/code/artifact/4b7ad144-a9cd-4221-a689-0092146394eb . The MCP server's create_cml_user works too but passes the
password as a chat argument, so the script stays the path for real
people. `docs/USER-GUIDE.md` is the page to hand an end user: the
Cloudflare email prompt, the one-time code, then the CML login with the
same email. The show_all gotcha is a lesson.

Full verification of every non-FTD node, all correct:

- n9k1: VLAN 10 and 20 up, all seven access ports connected in the
  right VLAN (ftd1/ftd2 inside on 1/1 and 1/3, outside on 1/2 and 1/4,
  edge on 1/5, kali on 1/6, insrv on 1/7).
- edge: mgmt .73, inside gateway 10.10.0.1, outside 203.0.113.1,
  loopback 198.51.100.1, all up; DHCP pool serving VLAN 10.
- insrv: static 10.10.0.10/24. extsrv 203.0.113.101, esrv
  203.0.113.251, both reach the edge and each other.
- kali: eth0 up, no lease yet.

The inside cannot reach the outside, and Kali cannot get DHCP, because
VLAN 10 only reaches VLAN 20 through an inline set on an active
firewall, and the pair is not built yet: ftd1 shows registration
Completed but failover Disabled, no inline set, data interfaces
administratively down. That is the cdFMC work in the operator's hands.
So everything the lab owns is configured; what remains is the HA pair
and the inline set, then Kali gets DHCP and the scans cross.

Both tooling blockers cleared the same evening: the stale host key
was removed with `ssh-keygen -R`, and the env file was back to clean
KEY=VALUE lines, so cml-mcp console sessions work again.

The rebuild wiped the CML users, as every rebuild does. The lab user
mruiznet@gmail.com no longer exists and its lab rights could not be
re-granted. Either recreate it in the UI, or add a row to
`config/mcp-env/users.csv` and run `70-users.sh`; the script's
username rule does not allow an @, so a plain username with the email
in the email column is the fit.

## 2026-09-11, early morning

Torn down at 03:33 UTC. Both labs exported to blob under
`exports/20260911T033320Z` (the first attempt refused a 2.10-shaped
export; fixed, LESSONS-LEARNED), license NOT_REGISTERED, 13 resources
destroyed, data disk unattached with twelve images on it: the ten
from the refplat lists plus FTDv 10.0.0 and Kali 2026.2. The next
build reimports the two labs with `60-import-lab.sh`; the Kali node
definition and image are on the disk, and their blob copies under
`custom/` are the fallback. No VM exists.

The FTDv cluster lab ran for an hour and was retired. The vPC pair,
HSRP, eBGP to the edge, and ECMP toward the firewalls all came up from
the reference configs, and the inside host's LACP bond bundled once
the virtio members were given a link speed (LESSONS-LEARNED). The
firewalls never registered: Threat Defense rejected the day-0
password for lacking a special character and then blocked all
configuration. The deeper problem was design: a Threat Defense
Virtual cluster cannot run inline sets, and the operator wants an IPS
lab. The cluster lab was wiped and deleted from the controller; its
files stay under `labs/ftdv-cluster*` as a retired design.

Replacement: `labs/ips-ha.yaml`, spec
`docs/superpowers/specs/2026-09-11-ips-ha-lab-design.md`. An FTD HA
pair with inline sets between VLAN 10 and 20 on one Nexus, a cat8000v
edge as gateway and DHCP, Kali and an Ubuntu server inside, two
servers outside, cdFMC management. Kali 2026.2 came from the official
QEMU image: downloaded on the CML host, unpacked there with 7z from
apt, registered through the dropfolder and the definitions API under
`config/node-definitions/kali.yaml`, and copied to blob under
`custom/` for future rebuilds (15 GB, fourteen seconds inside Azure).

Built the same night. `labs/ips-ha.yaml` imported with all eleven
nodes; n9k1, edge, the three Ubuntu hosts, Kali, and both FTDv are
up. VLAN 10 and 20 verified on the switch, the edge answers on all
three addresses and reaches both outside servers, no DHCP lease yet
because VLAN 10 is isolated until an inline set exists. Both
firewalls accepted the day-0 password this time and show the cdFMC
manager with registration Pending. Kali needed a serial console
edited into its base image (LESSONS-LEARNED); it now logs in on the
console, nmap 7.99 present, and VNC is available through the video
device in its node definition.

Registration is the open problem. The tenant host refuses 8305 from
everywhere while 443 answers with the tenant's certificate; every
device-side variant was tried and is written up in LESSONS-LEARNED.
Both firewalls currently carry a plain `DONTRESOLVE` manager entry at
the operator's request, Registration Pending. The two device records
in Security Cloud Control are in the onboarding state with the
generated keys, which are in `config/mcp-env/labs.env`; both lines
also passed through the chat transcript, so regenerate them if the
records are recreated. Next step is on the tenant side: find out
which host and port the Online device BOWSER uses, or ask SCC support
why 8305 is refused. Then delete and re-add the manager on both
consoles from the env file.

Everything else in the lab is up and correct. The inline set does
not exist until cdFMC has the pair, so VLAN 10 is still isolated and
Kali has no address; that is by design.

Was blocked on the operator: `FTD_ADMIN_PASSWORD` in
`config/mcp-env/labs.env`, upper, lower, digit, special character, no
sequences. The import refuses to render without it. Then: import,
start the switches, Nexus, and edge, then hosts, then the two FTDv,
console password change if day-0 still trips, registration, and the
HA pair plus inline set in cdFMC.
