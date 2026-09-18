# Building the lab from scratch

You have cloned this repo and you have an Azure subscription with nothing in
it. This guide takes you, in build order, to the platform that exists today:
CML on Azure with a routed path from lab nodes to the VNet, a Windows Server
2025 domain controller (`dc1`, forest `corp.rooez.com`, CA `corp-rooez-CA`),
and Cisco ISE 3.5 (`ise1`) joined to that domain with its two groups
selected. On top of that sits whatever lab you import.

Each phase says what it gets you, what has to be true first, the command,
how to check it, and what usually goes wrong. The detail lives in the
documents each phase links to. Every step here has run on a live build, the
last full run on 2026-09-18, except three things this guide says so about
where they appear: the 300 GB Standard SSD form values for ISE, a base-only
image upload, and `40-down.sh --skip-export`.

If you are an AI agent working in this repo: `CLAUDE.md` makes
`terraform apply`, `scripts/20-up.sh`, `scripts/24-ad-up.sh`,
`scripts/40-down.sh`, and `scripts/46-ad-down.sh` without `--dry-run`
stop-and-ask actions. The commands below are written for a human operator.

No secret, public address, subscription ID, or tenant ID appears here. Each
one is named by its variable and by the gitignored file that holds it.

## The environment on one screen

    Mac (operator)
      | SSH 1122 and HTTPS 443 to the CML host's static public IP
      | (the persistent root's output public_ip_address, and the host
      |  part of CML_URL in config/mcp-env/cml.env)
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

    Every script that talks to the controller, and cml-mcp, go through
    SSH forwards on the CML host (scripts/50-tunnels.sh, ADR 0012):
      cml 9443 -> 127.0.0.1:443      CML_API_BASE=https://127.0.0.1:9443
      ise 8443 -> 10.20.2.20:443     https://localhost:8443
      dc  3389 -> 10.20.2.10:3389    RDP client at localhost:3389

The bootstrap root (Terraform state), the persistent root (network, static
public IP, data disk, blob containers), and blob outlive a session (ADR
0002). The CML VM, ISE, and the DC are disposable. A spec to keep ISE and
the DC between sessions,
`docs/specs/2026-09-18-persistent-ise-dc-and-script-consolidation-design.md`,
is approved and not built; this guide describes what exists.

## Words this guide uses

| Term | Meaning |
|---|---|
| Persistent root | The Terraform root that is never destroyed: images, exports, the static public IP, the VNet |
| The transit, `bridge1` | The bridge on the CML host where lab nodes get `10.100.0.0/16` addresses and reach the VNet without NAT (ADR 0003) |
| The forward | The `cml` SSH port forward (`localhost:9443`) every script uses to reach the controller (ADR 0012) |
| NAD | Network access device: a switch or router that ISE treats as a RADIUS client |
| Join point | ISE's record of an Active Directory domain it has joined |
| ERS | ISE's REST API for configuration objects, on port 443 under `/ers/config` |
| CoA, MAB | Change of Authorization (ISE telling a switch to re-evaluate a session); MAC Authentication Bypass (a port authenticated by MAC address) |
| `sw1`, `emp-pc` | The Catalyst 9000v and the Ubuntu endpoint in the hand-built test lab, "cat9kv probe"; not a tracked topology |

## Time budget

| Phase | What | Time |
|---|---|---|
| 0 | Prerequisites and one-time setup | Hours to days. Cisco downloads and the Azure quota request are the slow parts |
| 1 | Storage, then images to blob | The two applies are minutes. The upload depends on your uplink |
| 2 | CML | `20-up.sh` takes about 20 minutes. Allow 15 more for the checks after it |
| 3 | The directory | About 20 minutes |
| 4 | ISE | 10 minutes in the portal, then 30 to 45 minutes of first boot. `25-ise-up.sh` waits for it |
| 5 | The join and the groups | Minutes of API calls |
| 6 | A lab on top | The import is seconds. Give routers and switches a few minutes to boot |
| 7 | Verify | Not timed |
| 8 | Shut down | Not timed |

Once the downloads are on disk, plan on two hours for phases 2 through 5,
most of it spent waiting for ISE. The 2026-09-18 start took that long.

## Phase 0: prerequisites and one-time setup

Nothing is created in Azure. `docs/PREREQUISITES.md` is the full list; this
is the order to do it in.

1. Initialize the fork submodule: `git submodule update --init`. Preflight
   fails without it.
2. Install the tools preflight looks for: `terraform`, `az`, `azcopy`, `jq`,
   `uv` and `uvx`, `python3`, `shellcheck`, `pre-commit`, `gitleaks`, and
   `ssh-keygen`. Versions that are known to work are in PREREQUISITES
   section 4. Terraform stays on 1.5.x on purpose. The upload script mounts
   the ISO with `hdiutil`, so the operator side is a Mac.
3. `az login`, select the subscription, and export its ID the way
   PREREQUISITES section 2.3 shows. Every script refuses to run without
   `ARM_SUBSCRIPTION_ID`, and the ID is never written to a file.
4. Ask for quota in East US 2 before anything else, because approval can
   take a while: 16 vCPUs of the Edsv6 family for the CML host
   (`Standard_E16ds_v6`), 8 of DSv4 for ISE (`Standard_D8s_v4`, the
   smallest size ISE 3.5 supports), and 2 of BS for the DC
   (`Standard_B2ms`). Preflight checks the first. Nothing checks the other
   two.
5. Get the CML license and token, and download the CML package, both
   reference platform ISOs, and `checksum.txt` into `software/`
   (PREREQUISITES sections 1.1 to 1.4).
6. Accept the ISE Marketplace terms on the subscription. Preflight checks
   this once `config/mcp-env/ise.env` exists and prints the exact
   `az vm image terms accept` command when the answer is no.
7. Copy each template in the table below to its gitignored place and fill
   it in with an editor. Never paste a secret into a chat or a tracked file.
8. Optional, for phase 7: build the pyATS environment as `verify/README.md`
   describes. Preflight only warns when it is absent.

| Template | Copy to | What you set |
|---|---|---|
| `config/cml.tfvars.example` | `config/cml.tfvars` | License token, flavor and node count, your public IP as a /32 in both allowed lists, VM size, package filename. PREREQUISITES section 2.4 |
| `terraform/bootstrap/terraform.tfvars.example` | `terraform/bootstrap/terraform.tfvars` | `owner`, `expires` |
| `terraform/persistent/terraform.tfvars.example` | `terraform/persistent/terraform.tfvars` | `owner`, `expires`. `24-ad-up.sh` reads this file too |
| `config/ise.env.example` | `config/mcp-env/ise.env` | `ISE_ADMIN_PASSWORD` within ISE's password policy, and `RADIUS_SECRET` |
| `config/labs.env.example` | `config/mcp-env/labs.env` | `LAB_PASSWORD`, `ISE_IP` (10.20.2.20), the same `RADIUS_SECRET` as `ise.env`, and later `TRUSTSEC_TEST_*` |
| `config/users.csv.example` | `config/mcp-env/users.csv` | One row per CML account |
| `config/tunnels.conf.example` | `config/tunnels.conf` | Keep the line `cml 9443 127.0.0.1 443`; uncomment `ise` and `dc` |

You do not make the SSH key. `20-up.sh` generates `keys/cml-lab` when it is
missing, and everything under `keys/` is gitignored.

Then run the readiness check. It is read-only:

    scripts/00-preflight.sh

On a new subscription expect a `[WARN]` that reads "blob checks skipped:
persistent root not applied yet", another for `verify/.venv` if you skipped
step 8, and no `[FAIL]`. When nothing fails, preflight writes
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
belongs to the persistent root, so that root comes first: run `20-up.sh` as
far as the persistent apply, upload, run preflight again until it is fully
green, then run `20-up.sh` to the end.

    scripts/20-up.sh --dry-run     # read the plan
    scripts/20-up.sh               # answer y to the bootstrap apply

On a subscription that is not the author's, the script stops right after the
bootstrap apply with "terraform/persistent/backend.tf does not name
<account>". That is expected. A backend block cannot read a variable, so the
state storage account's name is a literal in that tracked file, and yours is
different because the name carries a random suffix. Read yours and put it in
`storage_account_name`:

    terraform -chdir=terraform/bootstrap output -raw storage_account_name   # st...tfstate, 24 characters

Commit that edit on your own fork or branch: the name is not a secret, and
the tracked literal is what lets a fresh clone find the state again.

Run `scripts/20-up.sh` again. It reports the bootstrap as already applied.
Answer `y` to the persistent apply, and answer `n` when it asks to apply the
CML root. It exits with "declined", which is what you want at this point.

Now the images. `config/refplat.txt` is the one list the upload, preflight,
and the CML build all read: thirteen images, eight on the base ISO, the
four SD-WAN images and `ftdv` on the supplemental one. The upload script
checks every name against the one ISO it has mounted, so split the list in
two inside the gitignored `config/mcp-env/` and upload in two runs:

    grep -Ev '^(cat-sdwan|ftdv)' config/refplat.txt > config/mcp-env/refplat-base.txt
    grep -E  '^(cat-sdwan|ftdv)' config/refplat.txt > config/mcp-env/refplat-supplemental.txt

    REFPLAT_FILE=config/mcp-env/refplat-base.txt scripts/10-upload-images.sh --dry-run
    REFPLAT_FILE=config/mcp-env/refplat-base.txt scripts/10-upload-images.sh

    REFPLAT_ISO=software/<the -supplemental ISO> \
      REFPLAT_FILE=config/mcp-env/refplat-supplemental.txt scripts/10-upload-images.sh

Existing blobs are skipped, so a rerun costs little. Nothing in this guide
uses the supplemental images; exporting `REFPLAT_FILE` as the base list
for preflight, the upload, and `20-up.sh` gives a build without them, which
nobody has tried.

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

About 20 minutes. The first boot copies every listed image from blob to the
data disk inside the `sas_validity` window (4h in the example tfvars);
later builds copy only new ones. The script ends by printing the URL, the
SSH command, and "Next: scripts/50-tunnels.sh up, then
scripts/90-smoke-test.sh".

Wait a minute first. The host reboots once at the end of the install, after
Terraform has seen the API answer; for about a minute the API is not ready
and sshd throttles simultaneous SSH connections. On 2026-09-18 the first
`50-tunnels.sh up` failed for two of three forwards with
`kex_exchange_identification: Connection reset` and the first smoke test
failed two checks; both passed on a retry a minute later. A failure right
after a build is timing. Rerun once before looking further.

    scripts/50-tunnels.sh up
    scripts/90-smoke-test.sh
    terraform -chdir=terraform/persistent plan

The `cml` forward comes first because every script that logs in to the
controller, and cml-mcp, dial `CML_API_BASE` (the forward) rather than the
public address (ADR 0012). Without it a script stops at once with
`[FAIL] CML API forward not up on 127.0.0.1:9443. Run: scripts/50-tunnels.sh up`.
The smoke test ends with `summary: 13 OK, 0 WARN, 0 FAIL`, and among the
lines are "bridge1 holds 10.100.0.1/24", "net.ipv4.ip_forward is 1", the
data disk at LUN 0, "cml.env loads and the cml forward listens", and cml-mcp
listing labs. The plan must say no changes.

The routed lab path lets a lab node reach ISE and the DC at its own address
(`vendor/cloud-cml/AZURE-LAB.md`). It came up from cloud-init and Terraform
alone on 2026-09-18. Check three things by hand:

1. On the host, `/var/log/provision/06-transit.log` has
   `[06-transit] bridge1 holds 10.100.0.1/24` and
   `[06-transit] 10.100.0.0/16 routes via 10.100.0.2`, and no `FAIL:` line.
   `postprocess` swallows the script's exit code, so the log is the only
   signal.
2. The CML NIC's NSG carries both `lab-transit-in` (400) and
   `lab-transit-out` (410). The NSG's name carries a random suffix:

       nsg="$(az network nsg list -g rg-cml-lab --query "[?starts_with(name,'cml-sg')].name" -o tsv)"
       az network nsg rule list -g rg-cml-lab --nsg-name "$nsg" \
         --query "[?starts_with(name,'lab-transit')].{name:name,dir:direction,pri:priority}" -o table

   Two rows, Inbound 400 and Outbound 410.
3. The controller lists the bridge as an external connector. It does not
   until it is told to rescan, because the transit script runs after the
   controller's own startup scan. By hand until the spec lands:

       set -a; source config/mcp-env/cml.env; set +a
       TOKEN="$(printf '{"username":"%s","password":"%s"}' "$CML_USERNAME" "$CML_PASSWORD" |
         curl -sk -H 'Content-Type: application/json' -d @- "$CML_API_BASE/api/v0/authenticate" | jq -r .)"
       curl -sk -X PUT -H "Authorization: Bearer $TOKEN" -o /dev/null -w '%{http_code}\n' \
         "$CML_API_BASE/api/v0/system/external_connectors"      # 200
       curl -sk -H "Authorization: Bearer $TOKEN" "$CML_API_BASE/api/v0/system/external_connectors" \
         | jq -r '.[] | "\(.label) -> \(.device_name)"'          # NAT -> virbr0, Bridge 1 -> bridge1

   The last call lists "Bridge 1" on device `bridge1`. The password travels
   on stdin, not on a command line, and to the forward.

If you use the front door in `docs/ACCESS.md`, reinstall the Cloudflare
connector now, by hand until the spec lands; the VM is new and the
connector went with the old one. The `ise` and `dc` forwards are open and
carry nothing until phases 3 and 4.

| Symptom | Where to look |
|---|---|
| The tunnels or the smoke test fail right after the build | Timing. Wait a minute and rerun once. LESSONS-LEARNED, "Tunnels and the smoke test fail in the minute after a build" |
| `[FAIL] CML API forward not up` from any script or cml-mcp | `scripts/50-tunnels.sh up`. LESSONS-LEARNED, "Every script fails with 'CML API forward not up' after a build" |
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
are the directory's, and both are expensive to change on a running ISE
(`docs/AD.md`, "The rule: the directory first, and one domain"). You need
the persistent root applied and its `terraform.tfvars` in place; CML need
not be running.

    scripts/24-ad-up.sh --dry-run
    scripts/24-ad-up.sh

About 20 minutes. It asks once itself, then `terraform apply` asks again.
Terraform creates the VM and sends three PowerShell stages as run commands
(`docs/AD.md`, "How the directory is constructed"; `docs/ISE-AD-BUILD.md`,
Part 1, has them as commands). After a failed stage, fix the cause and run
the script again: it resumes at the failed step.

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
`CORP\labadmin`. Stage 1 sets the SAM policy value ISE's join depends on
(phase 5), and stage 3 makes the second `dsacls` grant for `svc-ise`; both
came up right on the DC built on 2026-09-18.

| Symptom | Where to look |
|---|---|
| The apply fails on a run command | Fix the cause and run the script again. It clears the failed run command first and skips finished stages. `docs/AD.md`, "When it goes wrong" |
| The VM is refused for `patch_mode` or for quota | Same table. `vm_size` goes in `terraform/ad/terraform.tfvars` |
| A check fails after a clean apply | The directory was still starting. Rerun |
| Anything else | The transcripts under `C:\lab\log` on the DC |

## Phase 4: ISE

ISE is deployed by hand in the Azure portal, because deploying Cisco's image
through Azure's API ends in a state that cannot be recovered (ADR 0008).
After the portal it is one login and one script. You need phase 3 green,
the Marketplace terms accepted, and CML running, since ISE is only reached
through the CML host.

`docs/ISE-AD-BUILD.md`, Part 2, has the portal form tab by tab. In short:
take the tile labeled Azure Application and not the one labeled Virtual
Machine; region East US 2, host name `ise1`, size `Standard_D8s_v4` and not
the default; Volume Size 300 and Disk Storage Type Standard SSD (Cisco's
supported minimum, and a third of the idle disk cost of the defaults);
`vnet-cml-lab` and `snet-apps`, private address 10.20.2.20, the public key
from `keys/cml-lab.pub`; DNS domain name `corp.rooez.com`, Primary Name
Server 10.20.2.10, NTP `time.google.com`; ERS and pxGrid both `yes`. The
`iseadmin` password you type has to be within ISE's password policy, or
first boot never finishes.

Submit, then wait for first boot, 30 to 45 minutes. When
https://localhost:8443 (through the `ise` forward) answers, log in once as
`iseadmin` with the password from the form. ISE makes you set a new one.
Set it to `ISE_ADMIN_PASSWORD` from `config/mcp-env/ise.env`, because the
script signs in to ISE's API with that value. Skip this and the policy step
fails with `ise_config: GET /networkdevice/name/c8000v-edge: HTTP 401`.

    scripts/25-ise-up.sh --post-deploy --dry-run
    scripts/25-ise-up.sh --post-deploy

`--post-deploy` is required; the script has no other mode. It creates and
attaches `ise-nsg`, tags the VM, disk, NIC, and public IP `role=ise` so
teardown finds them, polls ISE through the CML host for up to 45 minutes,
and then applies the policy in `scripts/lib/ise_config.py`: the network
device `c8000v-edge` (10.100.0.2) and the authorization rule `trustsec-poc`.

It worked if the script printed "directory was built first", "ISE answered
(HTTP ...)", "network device c8000v-edge", and "ISE ready". Then:

    terraform -chdir=terraform/persistent plan      # no changes

and, from ISE's CLI, the DNS and time checks in `docs/ISE-AD-BUILD.md`,
"Verifying ISE's DNS and time": `ping dc1` has to resolve to
`dc1.corp.rooez.com (10.20.2.10)`, and `show ntp` has to show ISE
synchronized. The SSH command for ISE's CLI, through the CML host with the
lab key, is in the same Part 2. An ISE deployed with the DC's address in the
form passed both on 2026-09-18. An ISE on the wrong resolver is repointed
as Part 2 describes, three restarts and 30 to 40 minutes.

| Symptom | Where to look |
|---|---|
| Validation fails with `QuotaExceeded` | ISE-AD-BUILD, Part 2. The size is `Standard_D8s_v4`; PREREQUISITES section 2.1 for the quota |
| The Basics tab has no Host Name field | Wrong tile. ISE-AD-BUILD, Part 2 |
| ISE never finishes first boot | A password outside ISE's policy stops it. ISE-AD-BUILD, Part 2 |
| `ise_config: GET /networkdevice/name/c8000v-edge: HTTP 401` | The first login was skipped, or the new password is not `ISE_ADMIN_PASSWORD`. Log in at `localhost:8443`, set it, rerun |
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

Windows Server 2025 refuses the legacy SAM password change ISE 3.5 makes
during a join, and the join ends in "Access is denied" after a clean step
log (Cisco Field Notice FN74321; `docs/AD.md`, "The join and Windows Server
2025"). Stage 1 of `24-ad-up.sh` sets the workaround,
`SamrChangeUserPasswordApiPolicy` = 3, before the promotion reboot. If a
join still fails this way, read the value back on the DC (Part 1, end of
stage 1); if it is not 3, set it and restart the DC, as Part 3 describes.

The join works when the join call answers 204. `addGroups` answers 204 too,
and a GET of the join point then lists both groups. `getUserGroups` for
`mario` returns `Mushroom-Kingdom`, and for `bowser` `Koopa-Troop`. That is
`config/ad-identities.csv` read back through ISE. On the DC,
`Get-ADComputer -Identity ISE1` finds the object.

| Symptom | Where to look |
|---|---|
| HTTP 500, "nodes not able to join/remove" | LESSONS-LEARNED, "A failed ISE join says 'nodes not able to join/remove' and nothing else". The reason is only in `ise-psc.log` |
| Access denied, error code 5, after a clean step log | LESSONS-LEARNED, "The ISE join fails with access denied after a step log that succeeds throughout". Look for event 16984 in the DC's System log |
| Three attribute writes with no success line | LESSONS-LEARNED, "Denied attribute writes in the ISE join log were not why the join failed" |
| "Falied to send http get request", or a 401 | LESSONS-LEARNED, "The ISE join over ERS fails with ...". Use the FQDN and `iseadmin` |
| 405 when updating the join point | LESSONS-LEARNED, "Updating an ISE join point over ERS returns 405" |
| "No mapping between account names and security IDs" on the DC | LESSONS-LEARNED, "`AD_ADMIN_USERNAME` already carries the domain prefix" |

## Phase 6: a lab on top

What runs on the platform is a topology from `labs/` (`labs/README.md`
describes each) or the labs exported at the last teardown. Both need the
`cml` forward. `labs/trustsec-phase1.yaml` is one cat8000v edge at
10.100.0.2 on `bridge1`, a RADIUS network device against ISE; phase 4 gave
ISE its two objects for it. It needs `LAB_PASSWORD`, `ISE_IP`, and
`RADIUS_SECRET` in `config/mcp-env/labs.env`, the secret being the one in
`ise.env`.

    scripts/60-import-lab.sh labs/trustsec-phase1.yaml --dry-run
    scripts/60-import-lab.sh labs/trustsec-phase1.yaml

The script prints "imported 'TrustSec Phase 1 proof' as lab <id>, stopped".

The labs from the last session are in `exports/<stamp>/` in the repo
(gitignored) and in the `exports` blob container, one YAML per lab, written
by `40-down.sh`. Re-importing them is by hand until the spec lands. Check
`ls exports/` for every lab that should come back, because a lab that was
not on the CML when the newest export was taken is only in an older
folder; the Cilium fabric was missed for two builds that way. The local
folders are `ls exports/`; the blob copy is
`az storage blob list --account-name <lab storage account> --container-name exports --auth-mode login -o table`.
For each file, in a fresh shell:

    set -a; source config/mcp-env/cml.env; set +a
    TOKEN="$(printf '{"username":"%s","password":"%s"}' "$CML_USERNAME" "$CML_PASSWORD" |
      curl -sk -H 'Content-Type: application/json' -d @- "$CML_API_BASE/api/v0/authenticate" | jq -r .)"
    curl -skf -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/yaml" \
      --data-binary @exports/<stamp>/<lab>.yaml "$CML_API_BASE/api/v0/import" | jq -r .id

Each call prints a lab id. Labs come back stopped. Start them from the UI or
through cml-mcp. Then the accounts:

    scripts/70-users.sh --dry-run
    scripts/70-users.sh

`70-users.sh` creates the CML accounts from `config/mcp-env/users.csv`,
grants every lab to the non-admin users, and writes generated passwords to
`config/mcp-env/users-credentials.csv`. It is idempotent; run it again after
every import so the new lab is granted. If a `bridge1` connector node stays
`DEFINED_ON_CORE`, the rescan in phase 2 was missed.

The lab this platform is for, TrustSec Phase 2, is a draft spec
(`docs/specs/2026-09-17-trustsec-phase2-design.md`) with no topology yet.
What STATUS reports as proven for it was proven on the hand-built "cat9kv
probe" lab, which lives only in the exports; its commands are in
`docs/ISE-AD-BUILD.md`, Part 3. Before building a lab by hand, read two
LESSONS-LEARNED entries: "A link made through the CML API carries nothing:
the interface is STOPPED" and "A new endpoint on an 802.1X port is refused
at once: single-host violation".

## Phase 7: verify

Everything in this table is something you can run yourself.

| Check | Command | Expected |
|---|---|---|
| The CML build | `scripts/90-smoke-test.sh` | `summary: 13 OK, 0 WARN, 0 FAIL` |
| Nothing drifted in the root that survives | `terraform -chdir=terraform/persistent plan` | No changes. Run it after the CML build and again after the ISE deploy |
| The directory | `scripts/24-ad-up.sh` again | It skips what exists and repeats its three checks |
| ISE's DNS and time | `ping dc1` and `show ntp` on ISE's CLI | ISE-AD-BUILD, "Verifying ISE's DNS and time" |
| The join and the groups | GET of the join point, `getUserGroups` | ISE-AD-BUILD, "Selecting the groups" and "Checking what ISE sees for a user" |
| The Phase 1 lab | `scripts/80-verify-lab.sh trustsec-phase1` | Below |

`80-verify-lab.sh` knows `cilium-evpn` and `trustsec-phase1`, and takes
`--dry-run`. `trustsec-phase1` needs `verify/.venv`, the lab running, an
ISE internal user `trustsec-verify`, made again on every new ISE with the
values from `labs.env` (`TRUSTSEC_TEST_USERNAME`, `TRUSTSEC_TEST_PASSWORD`):

    set -a; source config/mcp-env/ise.env; source config/mcp-env/labs.env; set +a
    jq -n --arg u "$TRUSTSEC_TEST_USERNAME" --arg p "$TRUSTSEC_TEST_PASSWORD" \
      '{InternalUser: {name: $u, password: $p, enabled: true}}' \
      | curl -sk -u "iseadmin:$ISE_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
        -d @- -o /dev/null -w '%{http_code}\n' https://localhost:8443/ers/config/internaluser   # 201

The password rides on stdin, never on a command line. Expect RadiusServerReachable and
RadiusAccessAccept to pass and CoAReceived to fail at 0: ISE sends a CoA
only for a live session, and a router with no endpoints has none. No pyATS
scenario covers 802.1X, MAB, a switch, or Active Directory yet.

## Phase 8: shut down, and what survives

CML first, then ISE, then the DC. ISE depends on the DC, so it goes before
it; CML depends on neither.

    scripts/40-down.sh --dry-run
    scripts/40-down.sh
    scripts/45-ise-down.sh
    scripts/46-ad-down.sh
    scripts/50-tunnels.sh down     # reaps the forwards, which died with the host

All but the tunnels' `down` take `--dry-run`. `40-down.sh` exports every
lab (to `/data/exports/<stamp>` on the disk, `exports/<stamp>/` in the
repo, and the `exports` blob container), stops them, releases the Smart
License and confirms it, and destroys only the fork's root. It stops if
the license is not confirmed released, since a stranded license blocks the
next build; `--force-license` overrides that and leaves you to release it
in Smart Software Manager. For a wedged VM whose API never came up,
`--skip-export` drops the export: it makes you type the VM name first,
because the labs on it are lost, and such a VM usually needs
`--force-license` too. `45-ise-down.sh` lists what is tagged `role=ise` and
asks before deleting the five resources. `46-ad-down.sh` destroys
`terraform/ad` and removes `ad.env`. Afterward
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
and on the disk.

## What is code and what is still by hand

Every row marked "until the spec lands" is folded into a script by
`docs/specs/2026-09-18-persistent-ise-dc-and-script-consolidation-design.md`,
which is approved and not built.

| Piece | State |
|---|---|
| State storage, network, public IP, data disk, blob containers | Code: `terraform/bootstrap`, `terraform/persistent`, driven by `20-up.sh` |
| The storage account name in `terraform/persistent/backend.tf` | By hand, once per subscription |
| Images to blob | Code: `10-upload-images.sh`. Splitting the list per ISO is by hand |
| The CML VM, license, data disk reuse | Code: the fork, driven by `20-up.sh` and `40-down.sh` |
| Transit bridge and the two NSG rules | Code in the fork. Proven from a build alone on 2026-09-18 |
| External connector rescan | By hand after every CML build, one API call, until the spec lands |
| Re-import of the last export | By hand after every CML build, one API call per lab, until the spec lands |
| CML users and lab grants | Code: `70-users.sh` from a CSV. Run by hand after every import until the spec lands |
| SSH forwards | Code: `50-tunnels.sh` from `config/tunnels.conf`. Run by hand after every CML build |
| The Cloudflare connector | By hand after every CML build (`docs/ACCESS.md`), until the spec lands |
| The domain controller: forest, DNS, CA, users, `svc-ise`, ISE's records | Code: `terraform/ad`, `scripts/ad/`, driven by `24-ad-up.sh` and `46-ad-down.sh`. Proven from nothing on 2026-09-18, the SAM policy value and the second `svc-ise` grant included |
| The ISE VM | By hand, in the portal, then one login to set the password |
| ISE's NSG, tags, readiness wait | Code: `25-ise-up.sh --post-deploy` |
| ISE policy: `c8000v-edge` and `trustsec-poc` | Code: `scripts/lib/ise_config.py` |
| ISE policy: join point, join, groups, any switch as a network device, its rule, the pyATS test user | By hand, over ERS or in the GUI, until the spec lands |
| A certificate for ISE from `corp-rooez-CA` | Not done at all |
| Authorization by directory group, SGTs | Not done. Phase 2 |
| Lab import | Code: `60-import-lab.sh` for anything in `labs/` |
| Lab verification | Code for `cilium-evpn` and `trustsec-phase1`. Everything else by hand |
| The TrustSec Phase 2 lab | A draft spec |
