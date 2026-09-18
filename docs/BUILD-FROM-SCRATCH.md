# Building the lab from scratch

You have cloned this repo and you have an Azure subscription with nothing in
it. This guide takes you, in build order, to the platform that exists today:
CML on Azure with a routed path from lab nodes to the VNet, a Windows Server
2025 domain controller (`dc1`, forest `corp.rooez.com`, CA `corp-rooez-CA`),
and Cisco ISE 3.5 (`ise1`) joined to that domain with its two groups
selected. On top of that sits whatever lab you import.

It is an orchestration guide. Each phase says what it gets you, what has to
be true first, the command, how long it takes, how to check it, and what
usually goes wrong. The detail lives in the documents each phase links to,
and this guide does not repeat it. Where something is expected to work but
has not been proven on a build from nothing, the phase says so.

If you are an AI agent working in this repo: `CLAUDE.md` makes
`terraform apply`, `scripts/20-up.sh` without `--dry-run`, and
`scripts/40-down.sh` without `--dry-run` stop-and-ask actions. The commands
below are written for a human operator. Ask before running those.

No secret, public address, subscription ID, or tenant ID appears here. Each
one is named by its variable and by the gitignored file that holds it.

## The environment on one screen

    Mac (operator)
      | SSH 1122 and HTTPS 443 to the CML host's static public IP
      | (the IP is the persistent root's output public_ip_address,
      |  and the host part of CML_URL in config/mcp-env/cml.env)
      v
    vnet-cml-lab, resource group rg-cml-lab, East US 2
    +------------------------------+     +--------------------------------+
    | CML subnet                   |     | snet-apps 10.20.2.0/24         |
    |                              |     |                                |
    | cml-controller  10.20.1.10   |     | dc1   10.20.2.10               |
    |   disposable VM              |     |   Windows Server 2025          |
    |   512 GB data disk at LUN 0  |     |   AD DS, DNS, AD CS            |
    |   (persistent, holds images  |     |   corp.rooez.com / CORP        |
    |    and lab exports)          |     |   CA corp-rooez-CA             |
    |                              |     |                                |
    |   bridge1  10.100.0.1/24     |     | ise1  10.20.2.20               |
    |   the transit network        |     |   ISE 3.5, evaluation          |
    +--------------+---------------+     +---------------+----------------+
                   |                                     |
                   |   routed both ways, no NAT (ADR 0003):
                   |   a route on snet-apps sends 10.100.0.0/16 to 10.20.1.10,
                   |   NSG rules lab-transit-in and lab-transit-out on the
                   |   CML NIC, IP forwarding on that NIC
                   v
    lab nodes inside CML, summary 10.100.0.0/16
      transit 10.100.0.0/24   host at .1, lab edge at .2, a lab switch at .3
      the rest of the /16 is routed by the host to the edge at 10.100.0.2

    From the Mac, ISE and the DC are reached only through the CML host:
      ise 8443 -> 10.20.2.20:443     https://localhost:8443
      dc  3389 -> 10.20.2.10:3389    RDP client at localhost:3389

Three things outlive a session: the bootstrap root (the storage account that
holds Terraform state), the persistent root (network, static public IP, data
disk, blob containers), and whatever is in blob. The CML VM, ISE, and the DC
are all disposable. `README.md` and ADR 0002 explain the split.

## Time budget

| Phase | What | Time |
|---|---|---|
| 0 | Prerequisites and one-time setup | Hours to days. Cisco downloads and the Azure quota request are the slow parts |
| 1 | Storage, then images to blob | The two applies are minutes. The upload depends on your uplink and was never timed |
| 2 | CML | `20-up.sh` took about 20 minutes on the first build. Allow 15 more for the checks after it |
| 3 | The directory | About 20 minutes |
| 4 | ISE | 10 minutes in the portal, then 30 to 45 minutes of first boot. `25-ise-up.sh` waits for it |
| 5 | The join and the groups | Minutes of API calls when nothing objects. Not timed on a clean run |
| 6 | A lab on top | The import is seconds. Give routers and switches a few minutes to boot |
| 7 | Verify | Not timed |
| 8 | Shut down | Not timed |

Once the downloads are on disk, plan on two to three hours for phases 1
through 5, most of it spent waiting for ISE.

## Phase 0: prerequisites and one-time setup

This phase leaves you with a Mac that can run every script, a subscription
that will accept the VMs, and the private files the scripts read. Nothing is
created in Azure. `docs/PREREQUISITES.md` is the full list; this is the
order to do it in.

1. Initialize the fork submodule: `git submodule update --init`. Preflight
   fails without it.
2. Install the tools preflight looks for: `terraform`, `az`, `azcopy`, `jq`,
   `uv` and `uvx`, `python3`, `shellcheck`, `pre-commit`, `gitleaks`, and
   `ssh-keygen`. Versions that are known to work are in PREREQUISITES
   section 4. Terraform stays on 1.5.x on purpose. The upload script mounts
   the ISO with `hdiutil`, so the operator side is a Mac.
3. `az login`, select the subscription, and export its ID the way
   PREREQUISITES section 2.2 shows. Every script refuses to run without
   `ARM_SUBSCRIPTION_ID`, and the ID is never written to a file.
4. Ask for quota in East US 2 before anything else, because approval can
   take a while: 16 vCPUs of the Edsv6 family for the CML host
   (`Standard_E16ds_v6`), 8 of DSv4 for ISE (`Standard_D8s_v4`), and room for
   a `Standard_B2ms` for the DC. Preflight checks the first. Nothing checks
   the other two (`docs/AD.md`, "Not built yet").
5. Get the CML license and token, and download the CML package, the base
   reference platform ISO, and `checksum.txt` into `software/`
   (PREREQUISITES sections 1.1 to 1.4). `config/refplat.txt` also lists five
   images that live on the supplemental ISO; phase 1 explains what that
   means for you.
6. Accept the ISE Marketplace terms on the subscription. Preflight checks
   this once `config/mcp-env/ise.env` exists and prints the exact
   `az vm image terms accept` command when the answer is no.
7. Copy each template in the table below to its gitignored place and fill
   it in with an editor. Never paste a secret into a chat or a tracked file.
8. Optional, for phase 7: build the pyATS environment as `verify/README.md`
   describes. Preflight only warns when it is absent.

| Template | Copy to | What you set |
|---|---|---|
| `config/cml.tfvars.example` | `config/cml.tfvars` | License token, flavor and node count, your public IP as a /32 in both allowed lists, VM size, package filename. PREREQUISITES section 2.3 |
| `terraform/bootstrap/terraform.tfvars.example` | `terraform/bootstrap/terraform.tfvars` | `owner`, `expires` |
| `terraform/persistent/terraform.tfvars.example` | `terraform/persistent/terraform.tfvars` | `owner`, `expires`. `24-ad-up.sh` reads this file too |
| `config/ise.env.example` | `config/mcp-env/ise.env` | `ISE_ADMIN_PASSWORD` within ISE's password policy, and `RADIUS_SECRET` |
| `config/labs.env.example` | `config/mcp-env/labs.env` | `LAB_PASSWORD`, `ISE_IP` (10.20.2.20), the same `RADIUS_SECRET` as `ise.env`, and later `TRUSTSEC_TEST_*` |
| `config/users.csv.example` | `config/mcp-env/users.csv` | One row per CML account |
| `config/tunnels.conf.example` | `config/tunnels.conf` | Keep the `cml` line; uncomment `ise` and `dc` |

You do not make the SSH key. `20-up.sh` generates `keys/cml-lab` when it is
missing, and everything under `keys/` is gitignored.

Then run the readiness check. It is read-only:

    scripts/00-preflight.sh

On a new subscription expect a `[WARN]` that reads "blob checks skipped:
persistent root not applied yet", another for `verify/.venv` if you skipped
step 8, and no `[FAIL]`. The first build's preflight read 31 OK, 1 WARN, 0
FAIL at this point. When nothing fails, preflight writes
`.preflight-ok`, and `20-up.sh` refuses to run without a marker younger than
four hours. `git status` must show none of the files you just made.

| Symptom | Where to look |
|---|---|
| Quota for the family is 0 and the request is refused | LESSONS-LEARNED, "The v5 family quota could not be raised above zero", and PREREQUISITES section 2.1 |
| `terraform validate` breaks after an init | LESSONS-LEARNED, "terraform init selects azurerm 5.x and validate breaks" |
| The ISO will not mount, short read | LESSONS-LEARNED, "A large file in the repo folder becomes unreadable". OneDrive turned it into a placeholder |
| You are on a VPN and filled the allowed lists from `curl ifconfig.me` | LESSONS-LEARNED, "SSH to the host times out while the web UI and the API work fine". Decide this before the build |

## Phase 1: storage first, then images to blob

The CML host pulls its package and its node images from a blob container at
first boot, so they have to be there before the VM is built. The container
belongs to the persistent root, so that root comes first. The first build
went in this order (`docs/STATUS-ARCHIVE.md`, the 2026-09-04 entry): run
`20-up.sh` as far as the persistent apply, upload, run preflight again until
it is fully green, then run `20-up.sh` to the end.

    scripts/20-up.sh --dry-run     # read the plan
    scripts/20-up.sh               # answer y to the bootstrap apply

On a subscription that is not the author's, the script stops right after the
bootstrap apply with "terraform/persistent/backend.tf does not name
<account>". That is expected. A backend block cannot read a variable, so the
state storage account's name is a literal in that tracked file, and yours is
different because the name carries a random suffix. Read yours and put it in
`storage_account_name`:

    terraform -chdir=terraform/bootstrap output -raw storage_account_name

Run `scripts/20-up.sh` again. It reports the bootstrap as already applied.
Answer `y` to the persistent apply, and answer `n` when it asks to apply the
CML root. It exits with "declined", which is what you want at this point.

Now the images. `config/refplat.txt` is the one list the upload, preflight,
and the CML build all read: thirteen images, among them `cat9000v-uadp` and
`cat9000v-q200`. Eight are on the base ISO. The four SD-WAN images and `ftdv`
are on the supplemental ISO, and the upload script checks every name against
the one ISO it has mounted, so a run with the whole list against the base
ISO fails on the five names before it uploads anything. The repo's own
images went up in two runs for that reason, each with `REFPLAT_FILE` naming
only the lines for that ISO. Keep the split lists inside the repo, in the
gitignored `config/mcp-env/`:

    grep -Ev '^(cat-sdwan|ftdv)' config/refplat.txt > config/mcp-env/refplat-base.txt
    grep -E  '^(cat-sdwan|ftdv)' config/refplat.txt > config/mcp-env/refplat-supplemental.txt

    REFPLAT_FILE=config/mcp-env/refplat-base.txt scripts/10-upload-images.sh --dry-run
    REFPLAT_FILE=config/mcp-env/refplat-base.txt scripts/10-upload-images.sh

    REFPLAT_ISO=software/<the -supplemental ISO> \
      REFPLAT_FILE=config/mcp-env/refplat-supplemental.txt scripts/10-upload-images.sh

Existing blobs are skipped, so a rerun costs little. If you do not want the
supplemental ISO at all, nothing in this guide uses its images:
`REFPLAT_FILE` is honored by `00-preflight.sh`, `10-upload-images.sh`, and
`20-up.sh` alike, so exporting it as the base list for all three should give
a build with the eight base images. The scripts read that way. Nobody has
built with it.

To check, run `scripts/00-preflight.sh` again. The blob section now runs for
real: one `[OK]` for the package, and for each listed image one for its node
definition and one for the image with its size. It should end with no
`[FAIL]` and the copy estimate "within SAS validity".

| Symptom | Where to look |
|---|---|
| The persistent apply fails on the storage account with a 409 | LESSONS-LEARNED, "The persistent apply died on the storage account with a 409". The fix is a `terraform import`, which a human runs |
| The upload reports success and most images are missing | LESSONS-LEARNED, "The upload script stopped after the first image and reported success". Fixed in the script; preflight is what catches it |
| `terraform` hangs on the OneDrive folder | LESSONS-LEARNED, "terraform hangs or errors on a stale NFS file handle" |

## Phase 2: CML and the routed path

This builds the CML VM, registers the license, and leaves
`config/mcp-env/cml.env` for every later script and for cml-mcp. You need a
fully green preflight less than four hours old.

    scripts/20-up.sh --dry-run
    scripts/20-up.sh               # y to persistent, y to the CML root

About 20 minutes on the first build. The first boot also copies every listed
image from blob to the data disk, inside the `sas_validity` window (4h in
the example tfvars). Later builds find the images already on the disk and
copy only new ones. The script ends by printing the URL, the SSH command,
and "Next: scripts/50-tunnels.sh up, then scripts/90-smoke-test.sh".

Wait a minute before that next step. The host reboots once at the end of the
install, after Terraform has already seen the API answer, and a smoke test
that lands in the reboot fails five checks for no reason.

    scripts/50-tunnels.sh up
    scripts/90-smoke-test.sh
    terraform -chdir=terraform/persistent plan

The `cml` forward comes first because every script that logs in to the
controller, and cml-mcp, dial it rather than the public address (ADR
0012). The smoke test should be all `[OK]` (13 checks), including "bridge1
holds 10.100.0.1/24", "net.ipv4.ip_forward is 1", the data disk at LUN 0,
"cml.env loads and the cml forward listens", and cml-mcp listing labs. The
plan must say no changes.

The routed lab path is what lets a lab node reach ISE and the DC at its own
address. `vendor/cloud-cml/AZURE-LAB.md` describes its four pieces. Check
three things by hand:

1. On the host, `/var/log/provision/06-transit.log` has
   `[06-transit] bridge1 holds 10.100.0.1/24` and
   `[06-transit] 10.100.0.0/16 routes via 10.100.0.2`, and no `FAIL:` line.
   `postprocess` swallows the script's exit code, so the log is the only
   signal.
2. The CML NIC's NSG carries both `lab-transit-in` (400) and
   `lab-transit-out` (410).
3. The controller lists the bridge as an external connector. It does not
   until it is told to rescan, because the transit script runs after the
   controller's own startup scan:

       set -a; source config/mcp-env/cml.env; set +a
       TOKEN="$(printf '{"username":"%s","password":"%s"}' "$CML_USERNAME" "$CML_PASSWORD" |
         curl -sk -H 'Content-Type: application/json' -d @- "$CML_API_BASE/api/v0/authenticate" | jq -r .)"
       curl -sk -X PUT -H "Authorization: Bearer $TOKEN" "$CML_API_BASE/api/v0/system/external_connectors"
       curl -sk -H "Authorization: Bearer $TOKEN" "$CML_API_BASE/api/v0/system/external_connectors" | jq .

   The last call should list "Bridge 1" on device `bridge1`. The login call
   is the one `60-import-lab.sh` makes; the password travels on stdin and
   not on a command line, and to `CML_API_BASE`, the `cml` forward, not to
   the public `CML_URL` (ADR 0012).

Two of those pieces have worked only after a hand repair. On the 2026-09-17
build the transit script was shipped under a name `postprocess` skips and
was run by hand on the host, and `lab-transit-out` was added to the running
NSG by hand. Both fixes are in the fork now (`06-transit.sh`, and the rule
in `azure/main.tf`). The next build is the first to get either from
cloud-init and Terraform alone, so do check them.

Then the accounts, with the forwards still up from the smoke test:

    scripts/50-tunnels.sh status
    scripts/70-users.sh --dry-run
    scripts/70-users.sh

`70-users.sh` creates the CML accounts from `config/mcp-env/users.csv`,
grants every lab to the non-admin users, and writes generated passwords to
`config/mcp-env/users-credentials.csv`. Run it again after every lab import.
The `ise` and `dc` forwards will open now and carry nothing until phases 3
and 4. If you want the web UI by name with a real certificate, the
Cloudflare connector is reinstalled after every build: `docs/ACCESS.md`,
"After a rebuild".

| Symptom | Where to look |
|---|---|
| The smoke test fails five checks right after the build | LESSONS-LEARNED, "The smoke test fails five checks straight after a build". Wait and rerun |
| SSH times out while the UI works | LESSONS-LEARNED, "SSH to the host times out while the web UI and the API work fine" |
| Your own `ssh`, or a cml-mcp console, complains about a changed host key | LESSONS-LEARNED, "After a rebuild every script that uses SSH fails with a changed host key" and "After a rebuild cml-mcp cannot reach any node console". The scripts use `keys/known_hosts`; your own file is yours to clear |
| No `06-transit.log` on the host at all | LESSONS-LEARNED, "A customize script is shipped to the host and never runs" |
| `bridge1` exists and the connector never appears | The rescan above, then LESSONS-LEARNED, "The controller never lists a custom bridge as an external connector" |
| A lab node pings 10.100.0.1 and nothing beyond it | LESSONS-LEARNED, "The host forwards nothing from the transit bridge: firewalld" and "RADIUS leaves the CML host and never reaches ISE" |
| The image copy dies with a 403 partway | LESSONS-LEARNED, "Image copy fails partway with an authentication error". Raise `sas_validity` |

## Phase 3: the directory first

This builds `dc1`: a forest, DNS with a forwarder to Azure's resolver, an
Enterprise Root CA, five users in two groups, the `svc-ise` account, and
ISE's DNS records. It comes before ISE because ISE's domain and name server
are the directory's, and both are expensive to change on a running ISE. The
rule and its reasons are in `docs/AD.md`, "The rule: the directory first,
and one domain".

You need the persistent root applied and its `terraform.tfvars` in place.
The script reads `owner` and `expires` from that file and the network values
from that root's outputs. It does not need CML to be running.

    scripts/24-ad-up.sh --dry-run
    scripts/24-ad-up.sh

About 20 minutes. It asks once itself, and then `terraform apply` asks for
its own approval. Terraform creates the VM and sends three PowerShell stages
as run commands; `docs/AD.md`, "How the directory is constructed", says what
each does, and `docs/ISE-AD-BUILD.md`, Part 1, shows the same stages as
commands.

The script ends with its own three checks and then two values:

    [OK]    directory answers for corp.rooez.com
    [OK]    DNS resolves the zone and, through the forwarder, a public name
    [OK]    certification authority is alive
    ISE portal form, Network Settings:
      Primary Name Server: 10.20.2.10
      DNS domain name:     corp.rooez.com

It also writes `config/mcp-env/ad.env` at mode 0600 with the generated
passwords (`AD_ADMIN_PASSWORD`, `AD_SVC_ISE_PASSWORD`,
`AD_LAB_USER_PASSWORD`) and never prints one. To look at the server itself,
RDP to `localhost:3389` through the `dc` forward and sign in as
`CORP\labadmin`.

One more check is worth the RDP session on this build. Stage 1 now sets the
SAM policy value that ISE's join depends on, before the promotion reboot
(phase 5 has the reason), and stage 3 now makes the second `dsacls` grant
for `svc-ise`. Both changes were made after the running DC was built, and no
DC has been built from nothing since. On the DC, the value should read 3;
the command is in `docs/ISE-AD-BUILD.md`, Part 1, at the end of stage 1.

| Symptom | Where to look |
|---|---|
| The apply fails on a run command | Fix the cause and run the script again. It clears the failed run command first and skips finished stages. `docs/AD.md`, "When it goes wrong" |
| The VM is refused for `patch_mode` or for quota | Same table. `vm_size` goes in `terraform/ad/terraform.tfvars` |
| A check fails after a clean apply | The directory was still starting. Rerun |
| Anything else | The transcripts under `C:\lab\log` on the DC |

## Phase 4: ISE

ISE is deployed by hand in the Azure portal, because deploying Cisco's image
through Azure's API ends in a state that cannot be recovered (ADR 0008 and
its amendment). Everything after the portal is one script. You need phase 3
green, the Marketplace terms accepted, and CML running, since ISE is only
ever reached through the CML host.

`docs/ISE-MARKETPLACE-DEPLOY.md` has the wizard tab by tab. In short: take
the tile labeled Azure Application and not the one labeled Virtual Machine;
region East US 2, host name `ise1`, size `Standard_D8s_v4` and not the
default; `vnet-cml-lab` and `snet-apps`, private address 10.20.2.20, the
public key from `keys/cml-lab.pub`; DNS domain name `corp.rooez.com`,
Primary Name Server 10.20.2.10, NTP `time.google.com`; ERS and pxGrid both
`yes`. The `iseadmin` password you type has to be the one in
`ISE_ADMIN_PASSWORD` in `config/mcp-env/ise.env`, because the script signs
in to ISE's API with that value.

Submit, then:

    scripts/25-ise-up.sh --post-deploy --dry-run
    scripts/25-ise-up.sh --post-deploy

`--post-deploy` is required; the script has no other mode. It creates and
attaches `ise-nsg`, tags the VM, disk, NIC, and public IP `role=ise` so
teardown finds them, polls ISE through the CML host for up to 45 minutes,
and then applies the policy in `scripts/lib/ise_config.py`: the network
device `c8000v-edge` (10.100.0.2) and the authorization rule `trustsec-poc`.
First boot is 30 to 45 minutes and you can start the script right after
submitting the form.

It worked if the script printed "directory was built first", "ISE answered
(HTTP ...)", "network device c8000v-edge", and "ISE ready". Then:

    terraform -chdir=terraform/persistent plan      # no changes
    scripts/50-tunnels.sh up                        # then https://localhost:8443, as iseadmin

and, from ISE's CLI, the DNS and time checks in `docs/ISE-AD-BUILD.md`,
"Verifying ISE's DNS and time": `ping dc1` has to resolve to
`dc1.corp.rooez.com (10.20.2.10)`, and `show ntp` has to show ISE
synchronized. The SSH command for ISE's CLI, through the CML host with the
lab key, is in the same Part 2.

The ISE running on 2026-09-17 was deployed before the directory existed and
was repointed from its CLI afterward. A deploy that names the DC in the
portal form from the start is what the documents prescribe, and it has not
been done yet. If you find yourself with an ISE on the wrong resolver
anyway, the repoint is Part 2 of the same document, three restarts and 30 to
40 minutes.

| Symptom | Where to look |
|---|---|
| Validation fails with `QuotaExceeded` | ISE-MARKETPLACE-DEPLOY, "The one that bit us: size and quota" |
| The Basics tab has no Host Name field | Wrong tile. Same document, "The wizard, tab by tab" |
| ISE never finishes first boot | A password outside ISE's policy stops it. Same document, "User Details" |
| The script warns "ISE was deployed without the domain controller" | Phase 3 was skipped. `docs/AD.md`, "The rule" |
| `localhost:8443` resets or refuses after an ISE restart | LESSONS-LEARNED, "ISE's API gives connection reset, then refused, after ISE restarts". `scripts/50-tunnels.sh up` |
| An ERS call returns 401 with the right password | The account is `iseadmin`, not `admin`. `docs/AD.md`, "When it goes wrong" |

## Phase 5: ISE joins the domain, and the groups

After this phase ISE is a computer object in `corp.rooez.com`, the groups
`Mushroom-Kingdom` and `Koopa-Troop` can be used in its rules, and a
directory user can authenticate through it with no policy change, because
ISE's Default policy set already searches every join point. None of it is
code yet. You need the `ise` forward up, `ISE_ADMIN_PASSWORD` from
`ise.env`, and `AD_SVC_ISE_PASSWORD` from `ad.env`.

The steps are in `docs/ISE-AD-BUILD.md`, Part 3, for the GUI and for the ERS
API. In short: create a join point named `corp.rooez.com` for the domain of
the same name, join the node as `svc-ise` giving the node's FQDN
`ise1.corp.rooez.com`, read the domain's groups with `getGroupsByDomain`,
and select the two groups with `addGroups`. A plain PUT to the join point is
refused with 405. Group SIDs differ in every forest, so take them from the
answer each time. Request bodies that carry a password go in a mode 0600
file under `config/mcp-env/` and are deleted afterward.

A Windows Server 2025 domain controller refuses the legacy SAM password
change call that ISE 3.5 makes during a join, and the join then ends in
"Access is denied" after a step log in which everything succeeded (Cisco
Field Notice FN74321; `docs/AD.md`, "The join and Windows Server 2025"). The
workaround is the DC policy value `SamrChangeUserPasswordApiPolicy` = 3,
which the DC only reads at startup. The build script now sets it before the
promotion reboot, and that path has not been proven on a DC built from
nothing, which is why phase 3 asks you to read the value back. If it is not
3, set it and restart the DC, as Part 3 describes.

The join works when the join call answers 204. `addGroups` answers 204 too,
and a GET of the join point then lists both groups. `getUserGroups` for
`mario` should return `Mushroom-Kingdom`, and for `bowser` `Koopa-Troop`.
That is `config/ad-identities.csv` read back through ISE, and on 2026-09-17
it matched. On the DC, `Get-ADComputer -Identity ISE1` finds the object.

| Symptom | Where to look |
|---|---|
| HTTP 500, "nodes not able to join/remove" | LESSONS-LEARNED, "A failed ISE join says 'nodes not able to join/remove' and nothing else". The reason is only in `ise-psc.log` |
| Access denied, error code 5, after a clean step log | LESSONS-LEARNED, "The ISE join fails with access denied after a step log that succeeds throughout". Look for event 16984 in the DC's System log |
| Three attribute writes with no success line | LESSONS-LEARNED, "Denied attribute writes in the ISE join log were not why the join failed" |
| "Falied to send http get request", or a 401 | LESSONS-LEARNED, "The ISE join over ERS fails with ...". Use the FQDN and `iseadmin` |
| 405 when updating the join point | LESSONS-LEARNED, "Updating an ISE join point over ERS returns 405" |
| "No mapping between account names and security IDs" on the DC | LESSONS-LEARNED, "`AD_ADMIN_USERNAME` already carries the domain prefix" |

## Phase 6: a lab on top

The platform is finished. What runs on it is a topology from `labs/`,
rendered and imported by one script. `labs/README.md` describes each file.

The tracked TrustSec topology is `labs/trustsec-phase1.yaml`: one cat8000v
edge at 10.100.0.2 on `bridge1`, acting as a RADIUS network device against
ISE. It is the proof of the routed path, RADIUS, and CoA with a router
alone, and phase 4 already gave ISE its two objects for it. It needs
`LAB_PASSWORD`, `ISE_IP`, and `RADIUS_SECRET` in `config/mcp-env/labs.env`,
and the secret has to be the one in `ise.env`.

    scripts/60-import-lab.sh labs/trustsec-phase1.yaml --dry-run
    scripts/60-import-lab.sh labs/trustsec-phase1.yaml
    scripts/70-users.sh            # grants the new lab to everyone

The script prints "imported 'TrustSec Phase 1 proof' as lab <id>, stopped".
Start it from the UI or through cml-mcp. If the `bridge1` connector node
stays `DEFINED_ON_CORE`, the rescan in phase 2 was missed.

### The TrustSec demo lab is not built yet

The lab this platform is for is TrustSec Phase 2, designed in
`docs/superpowers/specs/2026-09-17-trustsec-phase2-design.md`. It is a draft
spec. There is no implementation plan, no `labs/trustsec-phase2.yaml`, and
nothing of it is built.

Much of what STATUS reports as proven was proven on a scratch lab named "cat9kv
probe", which the operator built by hand in CML to test one piece at a time.
It held a `cat9000v-uadp` switch `sw1` at 10.100.0.3 on `bridge1`, an alpine
endpoint `ep1` on Gi1/0/1, and an Ubuntu endpoint `emp-pc` on Gi1/0/2 running
`wpa_supplicant` from a systemd unit named `wired-peap`. It is not tracked in
`labs/` and is not meant to be, so you cannot import it. ISE's side of it was
made by hand as well: the network device `cat9kv-sw1`, the authorization
rule `trustsec-poc-sw1`, and the internal user `trustsec-verify`. What it
proved, all on 2026-09-17 (`docs/STATUS.md`):

| Result | How it was seen |
|---|---|
| The Catalyst 9000v accepts the commands the design needs: MAB, dot1x authenticator, `access-session`, the `cts` set, SXP, device-sensor | CLI probe on `sw1` |
| RADIUS from a lab switch reaches ISE at the switch's own address, no NAT, and the reply comes back | `sw1` got an Access-Reject for a made-up user 400 ms after asking |
| MAB | `ep1` authorized on Gi1/0/1, `mab Authc Success`; ISE recorded NAS 10.100.0.3, PermitAccess |
| CoA reaches the right switch | ISE's reauth call returned true; `sw1` showed `CoA: requests: 1, Ack responses: 1` |
| 802.1X from a Linux supplicant | `emp-pc`, PEAP with MSCHAPv2 against an ISE internal user; ISE recorded PEAP (EAP-MSCHAPv2) |
| Active Directory answers through ISE | `test aaa group radius mario ... new-code` from `sw1`: authenticated with the right password, rejected with a wrong one, and DC event 4776 from `\\ISE1` with codes `0x0` and `0xC000006A` |
| PEAP as a directory user | `emp-pc` as `mario`: `EAP-MSCHAPV2: Authentication succeeded`, Gi1/0/2 authorized by dot1x as `mario`, event 4776 in the same second |

The commands and their output are in `docs/ISE-AD-BUILD.md`, Part 3, "End to
end: a directory user from the switch" and "A PEAP login from an endpoint as
a directory user". Whoever builds the next lab by hand should read two
entries in LESSONS-LEARNED first. "A link made through the CML API carries
nothing: the interface is STOPPED" cost an hour. "A new endpoint on an
802.1X port is refused at once: single-host violation" looks like an EAP
failure and is a port that err-disabled.

## Phase 7: verify

Everything in this table is something you can run yourself.

| Check | Command | Expected |
|---|---|---|
| The CML build | `scripts/90-smoke-test.sh` | Every line `[OK]` |
| Nothing drifted in the root that survives | `terraform -chdir=terraform/persistent plan` | No changes. Run it after the CML build and again after the ISE deploy |
| The directory | `scripts/24-ad-up.sh` again | It skips what exists and repeats its three checks |
| ISE's DNS and time | `ping dc1` and `show ntp` on ISE's CLI | ISE-AD-BUILD, "Verifying ISE's DNS and time" |
| The join and the groups | GET of the join point, `getUserGroups` | ISE-AD-BUILD, "Selecting the groups" and "Checking what ISE sees for a user" |
| The Phase 1 lab | `scripts/80-verify-lab.sh trustsec-phase1` | Below |

`80-verify-lab.sh` knows two scenarios, `cilium-evpn` and `trustsec-phase1`,
and takes `--dry-run`. For `trustsec-phase1` it needs `verify/.venv`, the
Phase 1 lab imported and running, an ISE internal user made for the purpose
(on 2026-09-17 it was `trustsec-verify`, created over ERS), and that user's
credentials in `labs.env` as `TRUSTSEC_TEST_USERNAME` and
`TRUSTSEC_TEST_PASSWORD`. ISE is new every session, so the user is made
again each time. On its first live run, 2026-09-17, RadiusServerReachable
and RadiusAccessAccept passed and CoAReceived failed at 0. That failure is
accurate: ISE sends a CoA only for a live session, and a router with no
endpoints never has one.

No pyATS scenario covers 802.1X, MAB, a switch, or Active Directory. Those
were checked by hand on the probe lab, and automated checks for them belong
to Phase 2.

## Phase 8: shut down, and what survives

ISE goes first because it depends on the DC, then the DC, then CML.

    scripts/30-export-labs.sh      # optional on its own: 40-down.sh runs it first anyway
    scripts/50-tunnels.sh down
    scripts/45-ise-down.sh
    scripts/46-ad-down.sh
    scripts/40-down.sh --dry-run
    scripts/40-down.sh

Every one of them takes `--dry-run` except the tunnels' `down`.
`45-ise-down.sh` lists what is tagged `role=ise` and asks before deleting
the five resources. `46-ad-down.sh` destroys `terraform/ad` and removes
`ad.env`. `40-down.sh` exports every lab, stops them, releases the Smart
License and confirms it is released, and destroys only the fork's root. It
stops if the license cannot be confirmed released, because a stranded
license blocks the next build; `--force-license` overrides that and leaves
you to release it in Smart Software Manager. Afterward
`terraform -chdir=terraform/persistent plan` should still say no changes.

| Survives | Where |
|---|---|
| Node images and node definitions | The data disk, and the `cml` blob container |
| Lab exports | The `exports` blob container (the durable copy), `/data/exports` on the disk, and `exports/` in the repo |
| The network, the static public IP, the route for the lab range | The persistent root |
| Terraform state for the persistent root | The bootstrap root's storage account |
| Your private config | `config/cml.tfvars`, `config/mcp-env/` except `ad.env`, `keys/` |
| The Cloudflare tunnel and Access policy, if you made them | Cloudflare |

The next session starts at phase 2, because the images are already in blob
and on the disk. These have to be done again by hand each time:

- The ISE portal deploy. The automated path was tried and retired (ADR 0008).
- ISE's join, the group selection, and any ISE object beyond the two that
  `ise_config.py` makes, until that script learns them (roadmap item 22).
- The connector rescan after the CML build, `70-users.sh`, and the
  tunnels.
- The `cloudflared` reinstall, if you use the front door.

The 2026-09-17 environment is being taken down in the order above. STATUS
records how it went.

## What is code and what is still by hand

| Piece | State |
|---|---|
| State storage, network, public IP, data disk, blob containers | Code: `terraform/bootstrap`, `terraform/persistent`, driven by `20-up.sh` |
| The storage account name in `terraform/persistent/backend.tf` | By hand, once per subscription |
| Images to blob | Code: `10-upload-images.sh`. Splitting the list per ISO is by hand |
| The CML VM, license, data disk reuse | Code: the fork, driven by `20-up.sh` and `40-down.sh` |
| Transit bridge and the two NSG rules | Code in the fork. Not yet seen to work from a build alone |
| External connector rescan | By hand, one API call |
| CML users and lab grants | Code: `70-users.sh` from a CSV |
| SSH forwards | Code: `50-tunnels.sh` from `config/tunnels.conf` |
| The Cloudflare connector | By hand after every build (`docs/ACCESS.md`) |
| The domain controller: forest, DNS, CA, users, `svc-ise`, ISE's records | Code: `terraform/ad`, `scripts/ad/`, driven by `24-ad-up.sh` and `46-ad-down.sh` |
| The SAM policy value for FN74321 | Code, in stage 1. Not yet proven on a new DC |
| The ISE VM | By hand, in the portal |
| ISE's NSG, tags, readiness wait | Code: `25-ise-up.sh --post-deploy` |
| ISE policy: `c8000v-edge` and `trustsec-poc` | Code: `scripts/lib/ise_config.py` |
| ISE policy: join point, join, groups, any switch as a network device, its rule, the pyATS test user | By hand, over ERS or in the GUI |
| A certificate for ISE from `corp-rooez-CA` | Not done at all |
| Authorization by directory group, SGTs | Not done. Phase 2 |
| Lab import | Code: `60-import-lab.sh` for anything in `labs/` |
| Lab verification | Code for `cilium-evpn` and `trustsec-phase1`. Everything else by hand |
| The TrustSec Phase 2 lab | A draft spec |
