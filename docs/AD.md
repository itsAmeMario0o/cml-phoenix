# Active Directory for the session

One Windows Server 2025 domain controller, `dc1`, at 10.20.2.10 on
`snet-apps` beside ISE. It is the forest root of `corp.rooez.com`, its DNS
server, and an Enterprise Root CA named `corp-rooez-CA`. It is rebuilt every
session and holds nothing worth keeping. ADR 0010 has the reasons; the
design is `docs/superpowers/specs/2026-09-13-active-directory-session-design.md`.

## Order of operations

    scripts/20-up.sh                       # CML, as always
    scripts/24-ad-up.sh                    # the DC, about 20 minutes
    (ISE portal deploy)                    # with the two values 24-ad-up prints
    scripts/25-ise-up.sh --post-deploy
    ...work...
    scripts/45-ise-down.sh                 # ISE first: it depends on the DC
    scripts/46-ad-down.sh
    scripts/40-down.sh

`24-ad-up.sh` runs `terraform apply` in `terraform/ad`. The apply creates the
VM and then runs three scripts on it in order: promote the forest and
reboot, install the CA, create the identities. It ends by checking that the
directory answers, that DNS resolves both the zone and a public name, and
that the CA is alive, then prints what ISE's portal form needs:

    Primary Name Server: 10.20.2.10
    DNS domain name:     corp.rooez.com

An ISE that is already running with a public resolver can be repointed from
its CLI with `ip name-server 10.20.2.10` and `ip domain-name corp.rooez.com`.
Either restarts the ISE application, about fifteen minutes.

If the apply fails partway, run `scripts/24-ad-up.sh` again. Each script
skips what it already did, and Terraform re-sends only the run command that
did not finish. Each leaves a transcript on the DC under `C:\lab\log`.

## Getting in

Passwords are in `config/mcp-env/ad.env`, mode 0600 and gitignored:
`AD_ADMIN_PASSWORD` for `CORP\labadmin`, `AD_LAB_USER_PASSWORD` for every
user in `config/ad-identities.csv`, and `AD_SVC_ISE_PASSWORD` for `svc-ise`,
the account ISE joins the domain with.

RDP goes through the CML host like everything else. Add this line to
`config/tunnels.conf`, run `scripts/50-tunnels.sh up`, and point an RDP
client at `localhost:3389`:

    dc 3389 10.20.2.10 3389

## Who is in the directory

`config/ad-identities.csv` is tracked. `Mushroom-Kingdom` is the employees
group and `Koopa-Troop` the contractors group when an ISE authorization rule
needs one of each. Edit the file and rerun `24-ad-up.sh` to add people; the
identities script only creates what is missing.

## Network

The DC's NSG allows the whole apps subnet, ISE included, on every port, by
the operator's choice, and RDP from the CML host. It has no public IP. Lab
nodes inside CML can reach it at their own addresses through the routed
path, which is what a domain-joined endpoint in a lab needs.

## Not built yet

Joining ISE to the domain and signing its certificate from the CA are by
hand in the ISE GUI for now. The CA is ready for it: it keeps subject
alternative names from a request, and domain controllers may enroll from
the `WebServer` template, so a CSR can be signed from a run command on the
DC without anyone logging in to it.
