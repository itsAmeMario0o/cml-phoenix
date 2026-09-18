# ISE and Active Directory, step by step

`docs/AD.md` says what the two servers are and why. This is what to type,
in build order, and what comes back, taken from the scripts or typed
against the lab on 2026-09-17 and 2026-09-18. `dc1` at 10.20.2.10 is the
domain controller for `corp.rooez.com` (NetBIOS `CORP`) with the CA
`corp-rooez-CA`; `ise1` at 10.20.2.20 is ISE 3.5; both on `snet-apps`.

No password appears here. Each is named by its variable in
`config/mcp-env/ad.env` or `config/mcp-env/ise.env`, both gitignored, mode
0600.

Build order:

    scripts/20-up.sh                       # CML
    scripts/24-ad-up.sh                    # Part 1, about 20 minutes
    (portal deploy, first login)           # Part 2
    scripts/25-ise-up.sh --post-deploy     # Part 2
    (join point, join, groups)             # Part 3
    ...work...
    scripts/45-ise-down.sh                 # ISE first: it depends on the DC
    scripts/46-ad-down.sh
    scripts/40-down.sh

## Part 1: the Windows server

### The script

    scripts/24-ad-up.sh --dry-run     # prints the sequence, changes nothing
    scripts/24-ad-up.sh               # about 20 minutes, asks before apply

It deletes any run command Azure holds in state `Failed`, applies
`terraform/ad`, writes `config/mcp-env/ad.env` (mode 0600, no value
printed), runs three checks on the DC (`Get-ADDomain`, `Resolve-DnsName`
for the zone and a public name, `certutil -ping`), and prints the two
values the ISE portal form takes. Stage 1 runs as SYSTEM; stages 2 and 3
run as `CORP\labadmin` through `scripts/ad/run-as-admin.ps1` (`docs/AD.md`
has why). Every stage writes a transcript under `C:\lab\log` and skips
what already exists. Expected ending:

    [OK]    directory answers for corp.rooez.com
    [OK]    DNS resolves the zone and, through the forwarder, a public name
    [OK]    certification authority is alive
    ISE portal form, Network Settings:
      Primary Name Server: 10.20.2.10
      DNS domain name:     corp.rooez.com

A check that fails after a clean apply usually means the directory was
still starting. Run the script again. Finished stages are skipped.

The rest of Part 1 is each stage as the commands an operator would type on
the DC, in an elevated PowerShell over RDP (`scripts/50-tunnels.sh up`,
then `localhost:3389`). Nobody has to type them; they are here so a stage
can be read, or repeated by hand.

### Stage 1: promote the forest (`10-promote-forest.ps1`)

Sign in as the local `labadmin`; there is no domain yet.

    Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

    $dsrm = Read-Host -AsSecureString 'DSRM password'
    Install-ADDSForest -DomainName corp.rooez.com -DomainNetbiosName CORP `
        -SafeModeAdministratorPassword $dsrm -InstallDns `
        -NoRebootOnCompletion -Force

    $sam = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SAM'
    New-Item -Path $sam -Force | Out-Null
    Set-ItemProperty -Path $sam -Name SamrChangeUserPasswordApiPolicy -Type DWord -Value 3

    shutdown.exe /r /t 15 /c 'forest promotion'

The SAM value must be set before this reboot; the DC reads it at startup
(`docs/AD.md`, "The join and Windows Server 2025"). The script ends with
`forest corp.rooez.com installed, rebooting in 15 seconds`; on a rerun,
`already a domain controller (DomainRole 5), nothing to do`.

Check, after the reboot, signed in as `CORP\labadmin` with
`AD_ADMIN_PASSWORD`:

    (Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole    # 5
    (Get-ADDomain).DNSRoot                                          # corp.rooez.com
    (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SAM').SamrChangeUserPasswordApiPolicy    # 3

`Get-ADDomain` throwing means AD DS is still starting. Wait and ask again.

### Stage 2: DNS forwarder, then the CA (`20-install-ca.ps1`)

As `CORP\labadmin`.

    Set-DnsServerForwarder -IPAddress 168.63.129.16

    Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools

    Install-AdcsCertificationAuthority -CAType EnterpriseRootCA `
        -CACommonName corp-rooez-CA -KeyLength 4096 -HashAlgorithm SHA256 `
        -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' `
        -ValidityPeriod Years -ValidityPeriodUnits 5 -Force

    certutil -setreg CA\CRLOverlapUnits 12
    certutil -setreg CA\CRLOverlapPeriod Hours
    certutil -setreg CA\ValidityPeriodUnits 5
    certutil -setreg CA\ValidityPeriod Years
    certutil -setreg CA\AuditFilter 127
    Restart-Service -Name certsvc
    certutil -ping        # repeat until "interface is alive", then:
    certutil -crl

    dsacls "CN=WebServer,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=corp,DC=rooez,DC=com" /G "CORP\Domain Controllers:CA;Enroll"

`certutil` fails by exit code, not exception: read each command's last
line. The script ends with `Enterprise Root CA corp-rooez-CA installed`;
on a rerun, `certification authority already installed, nothing to do`.

Check:

    (Get-DnsServerForwarder).IPAddress                              # 168.63.129.16
    Resolve-DnsName dc1.corp.rooez.com -Server 127.0.0.1            # 10.20.2.10
    Resolve-DnsName login.microsoftonline.com -Server 127.0.0.1     # any answer: the forwarder works
    certutil -ping                                                  # interface is alive

### Stage 3: identities and ISE's name (`30-create-identities.ps1`)

As `CORP\labadmin`. Users and groups come from `config/ad-identities.csv`
(columns `username`, `display`, `groups`, groups separated by `;`). Shown
for the first row; the script repeats it for every row and creates a group
the first time a row names it:

    $pw = Read-Host -AsSecureString 'lab user password'

    New-ADGroup -Name Mushroom-Kingdom -GroupScope Global -GroupCategory Security
    New-ADUser -Name 'Mario Mario' -SamAccountName mario `
        -UserPrincipalName mario@corp.rooez.com -DisplayName 'Mario Mario' `
        -Description 'lab user' -AccountPassword $pw `
        -Enabled $true -PasswordNeverExpires $true
    Add-ADGroupMember -Identity Mushroom-Kingdom -Members mario

The service account and its two grants on `Computers` (`docs/AD.md`,
"Who is in the directory", has what each grant is for):

    $svc = Read-Host -AsSecureString 'svc-ise password'
    New-ADUser -Name svc-ise -SamAccountName svc-ise `
        -UserPrincipalName svc-ise@corp.rooez.com -DisplayName svc-ise `
        -Description 'ISE domain join' -AccountPassword $svc `
        -Enabled $true -PasswordNeverExpires $true

    dsacls "CN=Computers,DC=corp,DC=rooez,DC=com" /G "CORP\svc-ise:CC;computer"
    dsacls "CN=Computers,DC=corp,DC=rooez,DC=com" /I:S /G "CORP\svc-ise:WP;;computer"

ISE's name, forward and reverse. The reverse zone does not exist until
this creates it:

    Add-DnsServerResourceRecordA -ZoneName corp.rooez.com -Name ise1 -IPv4Address 10.20.2.20
    Add-DnsServerPrimaryZone -NetworkId 10.20.2.0/24 -ReplicationScope Forest
    Add-DnsServerResourceRecordPtr -ZoneName 2.20.10.in-addr.arpa -Name 20 `
        -PtrDomainName ise1.corp.rooez.com

The script ends with `identities done: 5 users plus svc-ise`.

Check:

    Get-ADUser -Filter * | Select-Object SamAccountName, UserPrincipalName, Enabled
    Get-ADGroupMember -Identity Mushroom-Kingdom | Select-Object SamAccountName   # mario luigi peach yoshi
    Get-ADGroupMember -Identity Koopa-Troop | Select-Object SamAccountName        # bowser
    dsacls "CN=Computers,DC=corp,DC=rooez,DC=com" | Select-String svc-ise         # two lines
    Resolve-DnsName ise1.corp.rooez.com -Server 127.0.0.1                        # 10.20.2.20
    Resolve-DnsName 10.20.2.20 -Server 127.0.0.1                                 # ise1.corp.rooez.com

### One admin command on the DC without RDP

Put the command in place of the `__INNER_SCRIPT__` line of
`scripts/ad/run-as-admin.ps1` and send it with `az vm run-command invoke`
against `dc1`, with the wrapper's `Name`, `AdminUser`, `AdminPassword`,
and `ArgumentsBase64`. Pass the password with az's `@file` syntax from a
mode 0600 file under `config/mcp-env/`, deleted afterward.
`AD_ADMIN_USERNAME` already reads `CORP\labadmin`; a second `CORP\` gets
"No mapping between account names and security IDs".

## Part 2: ISE

### Before the portal

- `scripts/24-ad-up.sh` has passed its three checks and printed the two
  DNS values below. An ISE deployed before the DC needs the repoint at
  the end of this part, three restarts and 30 to 40 minutes.
- `config/mcp-env/ise.env` exists (from `config/ise.env.example`) with
  `ISE_ADMIN_PASSWORD` and `RADIUS_SECRET` set.
- The Marketplace terms for ISE 3.5 are accepted; `scripts/00-preflight.sh`
  prints the `az vm image terms accept` command if not.
- The portal is signed in as the account the CLI uses, on the lab
  subscription. The CML host is running; ISE is reached only through it.
- The lab public key on the clipboard: `cat keys/cml-lab.pub`.

Do not accept the wizard's default size `Standard_F16s_v2`: the FSv2
quota is 10 cores and validation fails with `QuotaExceeded`.

### The portal form

Open the Marketplace tile "Cisco Identity Services Engine (ISE)" labeled
**Azure Application** (Cisco's solution template, ADR 0008), not the
"Virtual Machine" tile of the same name. Plan "Cisco Identity Services
Engine (ISE) BYOL 3.5", then Create. Check: the Basics tab asks for Host
Name and Time Zone.

Basics:

| Field | Value |
|---|---|
| Subscription | the lab subscription |
| Resource group | `rg-cml-lab` |
| Region | East US 2, the VNet's region |
| Host Name | `ise1` |
| Time Zone | `Etc/UTC` |
| VM Size | `Standard_D8s_v4`, the smallest ISE 3.5 supports |
| Disk Storage Type | `Standard SSD` |
| Disk Encryption Key | blank |
| Volume Size | `300` |

300 GB on Standard SSD is the smallest disk Cisco allows and bills about
$38 a month idle instead of $123 for 600 GB Premium (ADR 0008 amendment,
2026-09-18). The ISE of 2026-09-18 was deployed at 600 GB Premium; a
managed disk cannot shrink, so the next deploy uses these values.

Network Settings:

| Field | Value |
|---|---|
| Virtual Network | `vnet-cml-lab` |
| Subnet | `snet-apps` |
| Network Security Group | none. `25-ise-up.sh` attaches one |
| SSH public key source | Use existing public key |
| SSH Key | the contents of `keys/cml-lab.pub` |
| Key pair name | `cml-lab` |
| Private IP Address | `10.20.2.20` |
| Public IP Address | new, `ise1-ip`, Standard SKU, Static. Outbound only |
| **DNS domain name** | **`corp.rooez.com`** |
| **Primary Name Server** | **`10.20.2.10`** |
| Primary NTP Server | `time.google.com` |

Leave the secondary and tertiary DNS and NTP fields blank. The two bold
values are what `24-ad-up.sh` printed. On 2026-09-18 an ISE deployed with
them came up as `ise1.corp.rooez.com`, resolving through the DC, with no
CLI work.

Services:

| Field | Value |
|---|---|
| ERS | `yes` |
| PXGrid | `yes` |

User Details:

| Field | Value |
|---|---|
| Password for `iseadmin` | a first-boot password, within ISE's rule |

ISE's rule: 6 to 25 characters, at least one uppercase, one lowercase, and
one digit, not containing `iseadmin` or `cisco`, special characters only
from `@ ~ * ! , + = _ - .`. A password outside the rule stops first boot.
`ISE_ADMIN_PASSWORD` in `ise.env` has to follow the same rule, because the
first login below sets ISE's password to it.

Review + submit. The portal may show provisioning warnings from the
OS-provisioning handshake ADR 0008 describes; it does not fail, and ISE
boots. On 2026-09-18 the login page answered 33 minutes after Create.

### First login: set the password the scripts use

Do this before `25-ise-up.sh`: its policy step signs in as `iseadmin`
with `ISE_ADMIN_PASSWORD`, and ISE refuses ERS until the first-login
password change is done.

    scripts/50-tunnels.sh up
    open https://localhost:8443

Sign in as `iseadmin` with the portal password. ISE asks for a new one:
enter the value of `ISE_ADMIN_PASSWORD` from `config/mcp-env/ise.env`.
Check: sign out and back in with the new password.

Skipping this ends `25-ise-up.sh` with
`ise_config: GET /networkdevice/name/c8000v-edge: HTTP 401`. The NSG and
tags before that step are already done, so do the login and rerun; the
rerun is quick.

### The script

    scripts/25-ise-up.sh --post-deploy --dry-run    # the plan, changes nothing
    scripts/25-ise-up.sh --post-deploy              # asks before it changes anything

In order, as verified on 2026-09-18: creates `ise-nsg` (RADIUS from the
lab range, 443 and 22 from the CML host, never `0.0.0.0/0`) and attaches
it to `ise1nic`; tags the VM, OS disk, NIC, and public IP `role=ise` so
`45-ise-down.sh` finds them; waits for ISE to answer through the CML jump
(`ISE answered (HTTP 401)` counts as up); creates the network device
`c8000v-edge` and the rule `trustsec-poc`. It does not create
`cat9kv-sw1`; that device and its rule are by hand until the spec lands
(`docs/specs/2026-09-18-persistent-ise-dc-and-script-consolidation-design.md`).

Expected ending:

    [OK]    ISE answered (HTTP 401) after <elapsed>
    [OK]    ISE ready. Reach it through the CML host jump (ADR 0003), never directly.

    terraform -chdir=terraform/persistent plan     # No changes: the deploy left rt-apps alone

### Check ISE's DNS and time

Over SSH as `iseadmin`, key only, with the CML host as the jump. Its
address is the host in `CML_URL`, `config/mcp-env/cml.env`.

    ssh -i keys/cml-lab -o UserKnownHostsFile=keys/known_hosts \
        -o ProxyCommand="ssh -p 1122 -i keys/cml-lab -o UserKnownHostsFile=keys/known_hosts -W %h:%p sysadmin@<cml-host>" \
        iseadmin@10.20.2.20

    ise1/iseadmin# show running-config | include name-server
    ip name-server 10.20.2.10

    ise1/iseadmin# show running-config | include domain-name
    ip domain-name corp.rooez.com

    ise1/iseadmin# ping dc1
    # resolves to dc1.corp.rooez.com (10.20.2.10) and gets replies

    ise1/iseadmin# show ntp
    # synchronized

Do not use ISE's own `nslookup`; on this image it fails with
"/usr/bin/host: parse of /etc/resolv.conf failed" while resolution works.

### The exception: repointing an ISE deployed before the DC

Only for an ISE whose form had a public resolver and another domain (the
ISE of 2026-09-17 had `8.8.8.8` and `rooez.com`). Three commands, each
followed by a restart of ISE's services, 30 to 40 minutes in all. From the
SSH session above:

    ise1/iseadmin# configure terminal
    ise1/iseadmin(config)# ip name-server 10.20.2.10

ISE asks `Do you want to restart ISE now? Proceed? [yes,no]`. Answer
`yes`. `no` cancels the change itself, not the restart. The prompt is back
in about 7 minutes; wait until Application Server reads `running`:

    ise1/iseadmin# show application status ise

`ip name-server` appends, so the public resolver is still first. Remove it
by name, `yes` to the same question, and wait again:

    ise1/iseadmin(config)# no ip name-server 8.8.8.8

Then the domain. ISE warns that certificates with the old name become
invalid, that it will generate a new self-signed certificate, and that an
existing directory join should be left first. `yes`. About 11 minutes.

    ise1/iseadmin(config)# ip domain-name corp.rooez.com

"The configuration database is locked by session NNN admin http" means
you were too quick after a restart. Wait for `show application status
ise` and retry. Then run the check above again.

## Part 3: joining ISE to the domain

Proven on 2026-09-18 against a DC built by the scripts: the join returned
204 on the first call, no DC restart needed. These calls are still by hand;
the spec moves them into `25-ise-up.sh`.

The `ise` tunnel from Part 2 must be up. Every ERS call below signs in as
`iseadmin` (the Marketplace image has no `admin`); `-u iseadmin` makes
curl ask for `ISE_ADMIN_PASSWORD` so it stays off the command line, and
`-k` accepts ISE's self-signed certificate. Bodies go in mode 0600 files
under the gitignored `config/mcp-env/`, deleted afterward.

### Create the join point

    curl -sk -u iseadmin -i -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -X POST https://localhost:8443/ers/config/activedirectory \
        -d '{"ERSActiveDirectory": {"name": "corp.rooez.com", "domain": "corp.rooez.com", "description": "lab directory on dc1"}}'

Check: `HTTP/1.1 201`. The join point's id is the last segment of the
`Location` header. Keep it:

    JP=<id from Location>

### Join

    umask 077
    . config/mcp-env/ad.env
    cat > config/mcp-env/ise-join.json <<EOF
    {"OperationAdditionalData": {"additionalData": [
        {"name": "username", "value": "svc-ise"},
        {"name": "password", "value": "${AD_SVC_ISE_PASSWORD}"},
        {"name": "node",     "value": "ise1.corp.rooez.com"}]}}
    EOF

    curl -sk -u iseadmin -o /dev/null -w '%{http_code}\n' \
        -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -X PUT "https://localhost:8443/ers/config/activedirectory/${JP}/join" \
        -d @config/mcp-env/ise-join.json
    rm config/mcp-env/ise-join.json

Check: `204`. `node` has to be the FQDN; the short name fails with
"Falied to send http get request" (ISE's spelling). A 500 with "nodes not
able to join/remove" is a failed join; the troubleshooting table at the
end of this part has where to look.

In the GUI the same is Administration > Identity Management > External
Identity Sources > Active Directory > Add, then Join as `svc-ise`.

### Select the groups

ISE can use a group in a rule only after it is selected on the join
point. Ask the domain for its groups:

    curl -sk -u iseadmin -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -X PUT "https://localhost:8443/ers/config/activedirectory/${JP}/getGroupsByDomain" \
        -d '{"OperationAdditionalData": {"additionalData": [{"name": "domain", "value": "corp.rooez.com"}]}}' \
        | jq . | grep -B1 -A2 'Mushroom-Kingdom\|Koopa-Troop'

Check: both `corp.rooez.com/Users/Mushroom-Kingdom` and
`corp.rooez.com/Users/Koopa-Troop`, type `GLOBAL`, each with a `sid`. SIDs
differ in every build of the forest; never write them down.

Add them. A plain `PUT .../activedirectory/<id>` returns 405; the call is
`addGroups`, with the join point exactly as GET returned it, minus `link`:

    curl -sk -u iseadmin -H 'Accept: application/json' \
        "https://localhost:8443/ers/config/activedirectory/${JP}" \
        | jq --arg mk '<Mushroom-Kingdom sid>' --arg kt '<Koopa-Troop sid>' \
            'del(.ERSActiveDirectory.link)
             | .ERSActiveDirectory.adgroups = {groups: [
                 {name: "corp.rooez.com/Users/Mushroom-Kingdom", sid: $mk, type: "GLOBAL"},
                 {name: "corp.rooez.com/Users/Koopa-Troop",      sid: $kt, type: "GLOBAL"}]}' \
        > config/mcp-env/ise-addgroups.json

    curl -sk -u iseadmin -o /dev/null -w '%{http_code}\n' \
        -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -X PUT "https://localhost:8443/ers/config/activedirectory/${JP}/addGroups" \
        -d @config/mcp-env/ise-addgroups.json
    rm config/mcp-env/ise-addgroups.json

Check: `204`, and `GET .../activedirectory/${JP}` lists both groups under
`adgroups`. In the GUI: the join point's Groups tab > Add > Select Groups
From Directory.

### Check what ISE sees for a user

    curl -sk -u iseadmin -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -X PUT "https://localhost:8443/ers/config/activedirectory/${JP}/getUserGroups" \
        -d '{"OperationAdditionalData": {"additionalData": [{"name": "username", "value": "mario"}]}}' | jq .

| User | Groups ISE returned on 2026-09-18 |
|---|---|
| `mario` | `Builtin/Users`, `Users/Mushroom-Kingdom`, `Users/Domain Users` |
| `bowser` | `Builtin/Users`, `Users/Domain Users`, `Users/Koopa-Troop` |

That is the CSV, read back through ISE.

### End to end: a directory user from the switch

No ISE policy change is needed: the Default policy set authenticates
against `All_User_ID_Stores`, which includes `All_AD_Join_Points`. What is
needed is `sw1` as a network device in ISE (`cat9kv-sw1`, 10.100.0.3,
with `RADIUS_SECRET`) and its rule `trustsec-poc-sw1`. `25-ise-up.sh`
creates neither yet; add both in the GUI, matching `c8000v-edge` and
`trustsec-poc`.

On `sw1`, with its RADIUS servers in the group `ISE-GROUP`:

    sw1# test aaa group radius mario <AD_LAB_USER_PASSWORD> new-code
    User successfully authenticated

    sw1# test aaa group radius mario <a wrong password> new-code
    User rejected

The password lands in the switch's command history; tolerable on a lab
switch and nowhere else. The DC's Security log proves Active Directory
answered, not ISE's internal store: event 4776, Logon Account
`mario@corp.rooez.com`, Source Workstation `\\ISE1`, error code `0x0` for
the right password and `0xC000006A` for the wrong one:

    Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4776} -MaxEvents 10 |
        Select-Object TimeCreated, Message

Proven 2026-09-17 on the ISE of that day.

### A PEAP login from an endpoint

`test aaa` is the switch asking on its own behalf; this is a real 802.1X
login. `emp-pc` is an Ubuntu node on `sw1` Gi1/0/2 running `wpa_supplicant`
from the systemd unit `wired-peap`, with
`/etc/wpa_supplicant/wired-peap.conf` (mode 0600):

    ctrl_interface=/run/wpa_supplicant
    ap_scan=0
    network={
        key_mgmt=IEEE8021X
        eap=PEAP
        identity="mario"
        password="<AD_LAB_USER_PASSWORD>"
        phase2="auth=MSCHAPV2"
        eapol_flags=0
    }

    sudo systemctl restart wired-peap
    sudo journalctl -u wired-peap --since -1m

Check, as read on 2026-09-17:

    CTRL-EVENT-EAP-METHOD EAP vendor 0 method 25 (PEAP) selected
    CTRL-EVENT-EAP-PEER-CERT depth=0 subject='/CN=ise1.corp.rooez.com'
    EAP-MSCHAPV2: Authentication succeeded
    CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully

On the switch, `show access-session interface GigabitEthernet1/0/2
details` shows `User-Name: mario`, `Status: Authorized`; on the DC, event
4776 for `mario@corp.rooez.com`, error code 0x0. The config has no
`ca_cert` line, so the supplicant does not check ISE's self-signed
certificate; that ends with Part 4.

### When it goes wrong

| Symptom | Cause | What to do |
|---|---|---|
| `24-ad-up.sh` apply fails on a run command | Whatever the stage threw; the message is in the apply error | Fix it, rerun the script. It deletes the failed run command first and skips finished stages |
| The CA stage fails at `certutil -crl` with `RPC_S_SERVER_UNAVAILABLE` | `Restart-Service certsvc` returns before the CA's RPC interface answers | Fixed 2026-09-18 (PR #27): the script waits for `certutil -ping`. By hand, do the same |
| A `24-ad-up.sh` check fails but the apply succeeded | The directory was still starting | Rerun the script |
| `25-ise-up.sh` ends with `ise_config: GET /networkdevice/name/c8000v-edge: HTTP 401` | The first-login password change was not done, or `ISE_ADMIN_PASSWORD` differs from what was set | Do the first login (Part 2), rerun the script |
| An ERS call returns 401 with the right password | The client signed in as `admin` | Use `iseadmin` |
| `localhost:8443` gives connection reset or refused after an ISE restart | The `ise` tunnel dropped | `scripts/50-tunnels.sh up` |
| ISE CLI refuses a command: "configuration database is locked by session NNN admin http" | Too soon after a restart | Wait for `show application status ise`, retry |
| Join returns 500, "nodes not able to join/remove" | The message never carries the reason | `show logging application ise-psc.log \| include Fatal` on ISE's CLI (slow, pages with `--More--`). Read the step log to the end; the DC's Security log will not help, a denied LDAP write is not audited |
| The step log shows `operatingSystem`, `operatingSystemVersion`, `msDS-SupportedEncryptionTypes` with no success line | `svc-ise` lacks write property on computer objects. Not fatal, but misleading | The second `dsacls` grant in Part 1, stage 3. The build makes it |
| The step log succeeds throughout and still ends "Access is denied", error code 5; the DC's System log has event 16984 from SAM at that time | Cisco FN74321: a Server 2025 DC refuses the SAM password change method ISE uses (`docs/AD.md`, "The join and Windows Server 2025"). Only on a DC built before the fix | On the DC: `Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SAM' -Name SamrChangeUserPasswordApiPolicy -Type DWord -Value 3`, then `az vm restart`. The value is read at startup. Join again |
| Not sure the DC is refusing the method | | `Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SAM' -Name AuditLegacyPasswordRpcMethods -Value 1 -Type DWord`, join again, then `Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Directory-Services-SAM'; Id=16984,16985}`. Event 16985 names the method and `ISE1$`. Set the value back to 0 |
| Join fails with "Falied to send http get request" | `node` was the short name | Use `ise1.corp.rooez.com` |
| Updating the join point returns 405 | A plain `PUT .../activedirectory/<id>` is not supported | `PUT .../<id>/addGroups` |
| Anything on the DC | | The transcripts under `C:\lab\log`, over RDP |

## Part 4: not done

1. Authorization rules that use `Mushroom-Kingdom` and `Koopa-Troop`. The
   groups are selected and no rule refers to them. Mapping a group to a
   Security Group Tag is TrustSec Phase 2.
2. A certificate for ISE signed by `corp-rooez-CA`: import the CA's root
   into ISE's trusted store, generate a request for EAP and admin use, have
   the CA sign it from the `WebServer` template, bind the result.
3. The join, the groups, and `cat9kv-sw1` as code in `25-ise-up.sh`, and
   ISE and the DC deallocated between sessions instead of destroyed:
   `docs/specs/2026-09-18-persistent-ise-dc-and-script-consolidation-design.md`.
