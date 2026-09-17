# ISE and Active Directory, step by step

`docs/AD.md` explains what the two servers are and why they are built the
way they are. This is the other half: what to type, in build order, and what
comes back. Everything here was either taken from the scripts that do the
work or typed against the running lab on 2026-09-17. Where something is not
proven yet, it says so.

The names throughout: `dc1` at 10.20.2.10 is the domain controller for the
forest `corp.rooez.com` (NetBIOS `CORP`), with the Enterprise Root CA
`corp-rooez-CA`. `ise1` at 10.20.2.20 is ISE 3.5. Both sit on `snet-apps`.

No password appears in this document. Each one is named by its variable in
`config/mcp-env/ad.env` or `config/mcp-env/ise.env`, both gitignored and
mode 0600.

## Part 1: the Windows server

### What the script does

    scripts/24-ad-up.sh --dry-run     # prints the sequence, changes nothing
    scripts/24-ad-up.sh               # about 20 minutes

In order, the script:

1. Deletes any run command on `dc1` that Azure holds in state `Failed`. One
   that failed exists in Azure but not in Terraform's state, and the next
   apply would stop at "already exists".
2. Runs `terraform init` and `terraform apply` in `terraform/ad`. The apply
   asks for approval. It creates the VM, then sends the three PowerShell
   stages below as run commands, one after another.
3. Writes `config/mcp-env/ad.env` at mode 0600 from the root's outputs:
   `AD_DOMAIN`, `AD_NETBIOS`, `AD_DC_IP`, `AD_ADMIN_USERNAME`,
   `AD_ADMIN_PASSWORD`, `AD_SVC_ISE_PASSWORD`, `AD_LAB_USER_PASSWORD`. It
   never prints a value.
4. Runs three checks on the DC and prints `[OK]` or `[FAIL]` for each.
5. Prints the two values the ISE portal form takes.

Stage 1 runs as SYSTEM. Stages 2 and 3 run as `CORP\labadmin` through
`scripts/ad/run-as-admin.ps1`, for the reasons `docs/AD.md` gives. Every
stage writes a transcript under `C:\lab\log` on the server, named after
itself, and every stage skips what already exists.

The rest of Part 1 is what each stage does, written as the commands an
operator would type on the DC in an elevated PowerShell over RDP
(`scripts/50-tunnels.sh up`, then an RDP client at `localhost:3389`). They
are the scripts' own commands with the variables filled in. Nobody has to
type them. They are here so the build can be read, and so a stage can be
repeated by hand if it has to be.

### Stage 1: a server becomes a forest (`10-promote-forest.ps1`)

Sign in as the VM's local administrator, `labadmin`, because there is no
domain yet.

    Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools

    $dsrm = Read-Host -AsSecureString 'DSRM password'
    Install-ADDSForest -DomainName corp.rooez.com -DomainNetbiosName CORP `
        -SafeModeAdministratorPassword $dsrm -InstallDns `
        -NoRebootOnCompletion -Force

    $sam = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SAM'
    New-Item -Path $sam -Force | Out-Null
    Set-ItemProperty -Path $sam -Name SamrChangeUserPasswordApiPolicy -Type DWord -Value 3

    shutdown.exe /r /t 15 /c 'forest promotion'

The registry value between the promotion and the reboot has nothing to do
with promotion. It is there because of when it is read. A Windows Server
2025 domain controller refuses the older SAM RPC password change methods,
ISE 3.5 still uses one of them when it joins a domain, and the join fails
with access denied until the DC is told to allow them (Part 3 has the proof,
ADR 0010 the decision and its risk). The DC reads this value when it starts,
so setting it on a running DC does nothing until the next restart. Set ahead
of the promotion reboot, it is in effect from the DC's first boot as a
domain controller and costs no restart of its own.

The script gets the restore mode password from Terraform, which generated it
and stores it nowhere else. By hand you choose one. The reboot is put fifteen
seconds out so that a run command can report success before the machine goes
down; at a console that matters less, but it is what the script does. The
script's last line is `forest corp.rooez.com installed, rebooting in 15
seconds`. Run a second time, it prints `already a domain controller
(DomainRole 5), nothing to do`.

After the reboot the local `labadmin` is the domain's built-in
Administrator, and you sign in as `CORP\labadmin` with `AD_ADMIN_PASSWORD`.
The directory takes several minutes to start. The wrapper waits up to twenty
five minutes for it, and by hand the test is the same one:

    (Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole    # 5
    (Get-ADDomain).DNSRoot                                          # corp.rooez.com
    (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SAM').SamrChangeUserPasswordApiPolicy    # 3

`Get-ADDomain` throwing an error means AD DS is still starting. Wait and ask
again. Nothing in stage 2 or 3 works before it answers.

### Stage 2: the DNS forwarder, then the CA (`20-install-ca.ps1`)

As `CORP\labadmin`. SYSTEM cannot do this one: an Enterprise CA writes to
the forest's configuration partition, which takes Enterprise Admins.

The forwarder first. 168.63.129.16 is Azure's resolver, which any VM in a
virtual network can reach without an internet route:

    Set-DnsServerForwarder -IPAddress 168.63.129.16

Then the role and the authority:

    Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools

    Install-AdcsCertificationAuthority -CAType EnterpriseRootCA `
        -CACommonName corp-rooez-CA -KeyLength 4096 -HashAlgorithm SHA256 `
        -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' `
        -ValidityPeriod Years -ValidityPeriodUnits 5 -Force

Then the CA's registry values, a restart, and a first CRL:

    certutil -setreg CA\CRLOverlapUnits 12
    certutil -setreg CA\CRLOverlapPeriod Hours
    certutil -setreg CA\ValidityPeriodUnits 5
    certutil -setreg CA\ValidityPeriod Years
    certutil -setreg CA\AuditFilter 127
    Restart-Service -Name certsvc
    certutil -crl

`certutil` is a native command, so it fails by exit code and not by
exception. The script checks `$LASTEXITCODE` after each `-setreg` because the
first build lost a failure here. By hand, read each command's last line.
`CRLOverlapUnits` is the name the CA reads; the Quick Start these values came
from writes `CRLOverlapPeriodUnits`, which nothing reads.

Last, the one permission that exists for ISE's sake. Domain controllers may
enroll from the built-in `WebServer` template, so that a certificate request
can later be signed by a command sent to the DC:

    dsacls "CN=WebServer,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,DC=corp,DC=rooez,DC=com" /G "CORP\Domain Controllers:CA;Enroll"

The script ends with `Enterprise Root CA corp-rooez-CA installed`, or, on a
rerun, `certification authority already installed, nothing to do`. It does
not set `EDITF_ATTRIBSUBJECTALTNAME2`, on purpose (`docs/AD.md`).

To check:

    (Get-DnsServerForwarder).IPAddress                              # 168.63.129.16
    Resolve-DnsName dc1.corp.rooez.com -Server 127.0.0.1
    Resolve-DnsName login.microsoftonline.com -Server 127.0.0.1
    certutil -ping

The first `Resolve-DnsName` proves the zone and the second proves the
forwarder. `certutil -ping` has to say the CA's interface is alive; the
string `24-ad-up.sh` looks for is `interface is alive`.

### Stage 3: people, the service account, and ISE's name (`30-create-identities.ps1`)

As `CORP\labadmin`. The people come from `config/ad-identities.csv`, whose
columns are `username`, `display`, and `groups` (separated by `;` when there
is more than one). The script creates each group the first time a row names
it, as a global security group, and each user like this, shown for the first
row:

    $pw = Read-Host -AsSecureString 'lab user password'

    New-ADGroup -Name Mushroom-Kingdom -GroupScope Global -GroupCategory Security
    New-ADUser -Name 'Mario Mario' -SamAccountName mario `
        -UserPrincipalName mario@corp.rooez.com -DisplayName 'Mario Mario' `
        -Description 'lab user' -AccountPassword $pw `
        -Enabled $true -PasswordNeverExpires $true
    Add-ADGroupMember -Identity Mushroom-Kingdom -Members mario

The same for `luigi`, `peach`, and `yoshi` in `Mushroom-Kingdom`, and
`bowser` in a second group, `Koopa-Troop`. Every user in the file gets the
one password in `AD_LAB_USER_PASSWORD`.

`svc-ise` is made the same way with its own password,
`AD_SVC_ISE_PASSWORD`, and the description `ISE domain join`:

    $svc = Read-Host -AsSecureString 'svc-ise password'
    New-ADUser -Name svc-ise -SamAccountName svc-ise `
        -UserPrincipalName svc-ise@corp.rooez.com -DisplayName svc-ise `
        -Description 'ISE domain join' -AccountPassword $svc `
        -Enabled $true -PasswordNeverExpires $true

It is an ordinary user with two grants on the `Computers` container:

    dsacls "CN=Computers,DC=corp,DC=rooez,DC=com" /G "CORP\svc-ise:CC;computer"
    dsacls "CN=Computers,DC=corp,DC=rooez,DC=com" /I:S /G "CORP\svc-ise:WP;;computer"

The first lets it create computer objects, because ISE creates its own when
it joins. The join needs that one. The second is write property on the
computer objects beneath the container, and the first build did not have
it. Whoever creates a computer object may write only a short list of its
attributes: logon information, description, display name, the account name,
account restrictions, and the validated writes for the DNS host name and the
service principal names. ISE also tries to write `operatingSystem`,
`operatingSystemVersion`, and `msDS-SupportedEncryptionTypes`, which are
outside that list. Without the second grant those three writes are denied.
That does not stop a join (Cisco lists setting the OS attributes as
optional), but it leaves ISE's computer object without its operating system
and version, and it leaves denied writes in the join's step log that look
like the cause of a failure when they are not (Part 3). The grant is
harmless and is kept for both reasons. It was made by hand on the running DC
on 2026-09-17, and `30-create-identities.ps1` makes it on every build after
that.

Then ISE's name, forward and reverse. The reverse zone does not exist until
this creates it:

    Add-DnsServerResourceRecordA -ZoneName corp.rooez.com -Name ise1 -IPv4Address 10.20.2.20
    Add-DnsServerPrimaryZone -NetworkId 10.20.2.0/24 -ReplicationScope Forest
    Add-DnsServerResourceRecordPtr -ZoneName 2.20.10.in-addr.arpa -Name 20 `
        -PtrDomainName ise1.corp.rooez.com

The script ends with `identities done: 5 users plus svc-ise`.

To check:

    Get-ADUser -Filter * | Select-Object SamAccountName, UserPrincipalName, Enabled
    Get-ADGroupMember -Identity Mushroom-Kingdom | Select-Object SamAccountName
    Get-ADGroupMember -Identity Koopa-Troop | Select-Object SamAccountName
    Get-ADUser -Identity svc-ise
    dsacls "CN=Computers,DC=corp,DC=rooez,DC=com" | Select-String svc-ise
    Resolve-DnsName ise1.corp.rooez.com -Server 127.0.0.1           # 10.20.2.20
    Resolve-DnsName 10.20.2.20 -Server 127.0.0.1                    # ise1.corp.rooez.com

### The three checks the script ends with

`24-ad-up.sh` sends these to the DC as run commands and looks for one string
in each answer:

| Check | Sent to the DC | Passes when the answer contains |
|---|---|---|
| The directory answers | `(Get-ADDomain).DNSRoot` | `corp.rooez.com` |
| DNS, zone and forwarder | `Resolve-DnsName` for `dc1.corp.rooez.com` and `login.microsoftonline.com`, both against 127.0.0.1 | `dns-ok` |
| The CA is alive | `certutil -ping` | `interface is alive` |

A check that fails after a clean apply usually means the directory was still
starting. Run the script again; finished stages are skipped and the checks
run again.

### Running one admin command on the DC without RDP

The write property grant above reached the running DC as a single `dsacls`
line that had to run as the domain admin, and it was sent without opening
RDP. The way that worked:
take `scripts/ad/run-as-admin.ps1`, put the command in place of its
`__INNER_SCRIPT__` marker line, and deliver the result with
`az vm run-command invoke` against `dc1`, giving the wrapper its `Name`,
`AdminUser`, `AdminPassword`, and `ArgumentsBase64` parameters. The password
goes in from a mode 0600 file through az's `@file` argument syntax, so it
never shows in a process listing. Keep that file inside the repo's
gitignored `config/mcp-env/` and delete it afterward.

`AD_ADMIN_USERNAME` in `ad.env` already reads `CORP\labadmin`. Putting
`CORP\` in front of it again gets "No mapping between account names and
security IDs".

## Part 2: ISE

### A fresh deploy

Deploy ISE after `24-ad-up.sh` has passed its checks, through the portal, as
`docs/ISE-MARKETPLACE-DEPLOY.md` describes. Two fields on the Network
Settings tab tie ISE to the directory, and `24-ad-up.sh` prints both:

| Field | Value |
|---|---|
| DNS domain name | `corp.rooez.com` |
| Primary Name Server | `10.20.2.10` |

With Host Name `ise1` that makes ISE `ise1.corp.rooez.com`, the name stage 3
already gave an A record and a PTR. Private IP Address is `10.20.2.20` and
Primary NTP Server is `time.google.com`, as before. Then
`scripts/25-ise-up.sh --post-deploy`. An ISE deployed this way needs nothing
else in Part 2 except the verification at the end.

### Repointing an ISE that predates the DC

The ISE of 2026-09-17 was deployed before the rule existed, with 8.8.8.8 as
its resolver and the domain `rooez.com`. Moving it took three commands, each
with its own restart of ISE's services, 30 to 40 minutes in all. This is the
whole reason the DC is built first.

Get to ISE's CLI over SSH as `iseadmin`, with the lab key `keys/cml-lab`
and the CML host as the jump. SSH on this image is key-only. The prompt is
`ise1/iseadmin#`.

    ssh -i keys/cml-lab -o UserKnownHostsFile=keys/known_hosts \
        -o ProxyCommand="ssh -p 1122 -i keys/cml-lab -o UserKnownHostsFile=keys/known_hosts -W %h:%p sysadmin@<cml-host>" \
        iseadmin@10.20.2.20

The CML host's shell listens on 1122; its address is the host in `CML_URL`,
`config/mcp-env/cml.env`.

Add the DC as a name server:

    ise1/iseadmin# configure terminal
    ise1/iseadmin(config)# ip name-server 10.20.2.10

ISE prints a notice that DNS changed and asks `Do you want to restart ISE
now? Proceed? [yes,no]`. Answer `yes`. The question reads as if `no` would
postpone the restart. It does not: `no` cancels the change itself, ISE
prints `Aborted: by user`, and the running config is as it was. After `yes`
the prompt came back in about 7 minutes with ISE saying `ISE Processes are
initializing`, and the Application Server needed a few minutes more. Watch
it with:

    ise1/iseadmin# show application status ise

Go on when Application Server reads `running`.

Remove the old name server. `ip name-server` appends, so the config now
reads `ip name-server 8.8.8.8 10.20.2.10`, with the public resolver first.
Lookups for the domain would go to a server that has never heard of
`corp.rooez.com`. It has to be taken out by name:

    ise1/iseadmin(config)# no ip name-server 8.8.8.8

Same question, same answer, `yes`, and another restart.

Set the domain name:

    ise1/iseadmin(config)# ip domain-name corp.rooez.com

ISE warns that certificates using the old domain name become invalid, that
it will generate a new self-signed certificate for HTTPS and EAP now, that
any existing Active Directory join should be left first, and that services
will restart. `Proceed? [yes,no]`, `yes`. This one took about 11 minutes.
The new self-signed certificate does not matter much here, because the CA
step in Part 4 replaces it.

If a command is refused with "the configuration database is locked by
session NNN admin http (rest from 127.0.0.1)", you were too quick after the
previous restart. That session is ISE's own initialization holding the
lock. Wait until `show application status ise` shows the services up and
type the command again. It happened once, to `ip domain-name`, and the retry
worked.

### Verifying ISE's DNS and time

    ise1/iseadmin# show running-config | include name-server
    ip name-server 10.20.2.10

    ise1/iseadmin# show running-config | include domain-name
    ip domain-name corp.rooez.com

    ise1/iseadmin# ping dc1

The ping has to resolve the short name to `dc1.corp.rooez.com (10.20.2.10)`
and get replies. That proves both the name server and the search domain.

Do not use ISE's own `nslookup` for this. On this image it fails with
"/usr/bin/host: parse of /etc/resolv.conf failed" while resolution works
fine. We did not try it before the change, so we do not know whether the
repoint broke it or it never worked.

    ise1/iseadmin# show ntp

ISE should be synchronized. On 2026-09-17 it was, and the DC's clock was
within seconds of ISE's, well inside the five minutes Kerberos allows.

The helper scripts that drove these prompts during the session were expect
scripts in a session scratchpad, not in this repo. One thing from them is
worth keeping anyway and is in `docs/LESSONS-LEARNED.md`: an
`expect { ... }` block written on one line never matches.

## Part 3: joining ISE to the domain

The join has two steps, whichever way it is done: create a join point, which
is only a named pointer to a domain, then join the ISE node to it with an
account that may create a computer object.

### Through the GUI

With the `ise` tunnel up, open `https://localhost:8443` and sign in as
`iseadmin`. Go to Administration > Identity Management > External Identity
Sources > Active Directory > Add. Give `corp.rooez.com` as both the join
point name and the domain, and submit. Then Join, with the user `svc-ise`
and the password in `AD_SVC_ISE_PASSWORD`.

### Through the ERS API

The same tunnel, the same account. The ERS user on a Marketplace ISE is
`iseadmin`. A 401 with a password you know is right means the client is
signing in as `admin`.

Both calls need the headers `Content-Type: application/json` and `Accept:
application/json`. With curl, `-k` accepts ISE's self-signed certificate and
`-u iseadmin` makes curl ask for the password (`ISE_ADMIN_PASSWORD` in
`ise.env`), which keeps it off the command line.

Create the join point:

    POST https://localhost:8443/ers/config/activedirectory

    {"ERSActiveDirectory": {"name": "corp.rooez.com",
                            "domain": "corp.rooez.com",
                            "description": "lab directory on dc1"}}

The answer is 201, and the join point's id is the last part of the
`Location` header.

Join the node:

    PUT https://localhost:8443/ers/config/activedirectory/<id>/join

    {"OperationAdditionalData": {"additionalData": [
        {"name": "username", "value": "svc-ise"},
        {"name": "password", "value": "<AD_SVC_ISE_PASSWORD>"},
        {"name": "node",     "value": "ise1.corp.rooez.com"}]}}

The placeholder stands for the value of `AD_SVC_ISE_PASSWORD`. Put the body
in a mode 0600 file under the gitignored `config/mcp-env/`, send it with
`-d @file`, and delete the file afterward. The `node` value has to be the
FQDN. With the short name `ise1` the call fails with "Falied to send http
get request", which is ISE's spelling and says nothing about the cause.
A join that works answers 204 with no body.

### When the join fails

The API answers a failed join with HTTP 500 and "nodes not able to
join/remove : [ise1.corp.rooez.com]". That message carries no reason. What
each place to look showed:

| Place | What it showed |
|---|---|
| The API response | The 500 above |
| `ad_agent.log` on ISE, at its default level | `LW_ERROR_NOT_JOINED_TO_AD` status lines and nothing about the attempt |
| The Security log on `dc1` | Audit Success only: a TGT for `svc-ise`, a password reset on `ISE1$`, the account enabled. An LDAP write that is denied is not audited by default, so the refusal leaves no event |
| `ise-psc.log` on ISE | The join's full step log, and the final error with its name and code |
| The System log on `dc1` | Event 16984 from SAM at the time of each failed join. Nobody looked there until later (below) |

So read `ise-psc.log`:

    ise1/iseadmin# show logging application ise-psc.log | include Fatal

It is slow, several minutes, and it pages with `--More--`. The step log
lists each thing the join does to the directory in order and marks the ones
that succeeded. Read it to the end before deciding what failed. A step
without a success line is not necessarily the one that ended the join, as
the next section shows.

### The false lead: three attribute writes denied

The first join ended with "Join Operation Failed: Access is denied, Error
Name: ERROR_ACCESS_DENIED, Error Code: 5". Above that line, the step log
showed the machine account `ISE1$` created, enabled, and given a password,
then `dNSHostName` and the service principal names written, and then
`operatingSystem`, `operatingSystemVersion`, and
`msDS-SupportedEncryptionTypes` with no success line for any of them.

That looked like the answer. `svc-ise` had only the create-computer grant,
and those three attributes are outside what an object's creator may write
(stage 3 in Part 1). The write property grant was added on the DC:

    dsacls "CN=Computers,DC=corp,DC=rooez,DC=com" /I:S /G "CORP\svc-ise:WP;;computer"

It did what it should. On the next attempt the step log showed every
attribute written, `userAccountControl` 4096 and encryption types 28 among
them, and ended its attribute block with "Attributes was setted
successfully" (ISE's wording). The `ISE1` object on the DC now carries
operatingSystem `Cisco Identity Services Engine` and version `3.5.0.527`:

    Get-ADComputer -Identity ISE1 -Properties operatingSystem, operatingSystemVersion, 'msDS-SupportedEncryptionTypes'

And the join failed again, on the same final line, access denied, error
code 5. So the denied attribute writes were never fatal. Cisco lists setting
the OS attributes as optional. They were the only visible denials in the
log, and they sent the debugging the wrong way for a while. The grant stays,
for the reasons in Part 1, but it is not what the join was waiting for.

### The cause: the DC refuses the password change ISE uses

<!-- join-outcome: settled 2026-09-17 -->
The signature is a step log in which everything succeeds, a last line of
access denied with error code 5, and a DC Security log with nothing but
Audit Success.

Cisco Field Notice FN74321, "Cisco Identity Services Engine Fails to Join
Microsoft Active Directory Domain Services Hosted on Windows Server 2025"
(https://www.cisco.com/c/en/us/support/docs/field-notices/743/fn74321.html),
with regression bug CSCwr77017, describes it. A Windows Server 2025 domain
controller by default refuses the legacy SAM RPC password change methods
when they are called remotely (`SamrChangePasswordUser`,
`SamrOemChangePasswordUser2`, `SamrUnicodeChangePasswordUser2`) and accepts
only `SamrUnicodeChangePasswordUser4` (Microsoft, "What's new in Windows
Server 2025",
https://learn.microsoft.com/windows-server/get-started/whats-new-windows-server-2025).
ISE uses a legacy method during a join. The notice's second scenario is our
message exactly. It lists ISE 3.1 through 3.4 P1 as affected and does not
mention 3.5, and the bug lists 3.4 builds and no fixed version. Ours is
3.5.0.527, and the notice applies to it all the same. The DC's own log
proved it.

The DC can be made to say which legacy calls it receives. On `dc1`, under
`HKLM\SYSTEM\CurrentControlSet\Control\SAM`, the DWORD
`AuditLegacyPasswordRpcMethods` set to 1 turns on logging and nothing else
(Microsoft KB5004605):

    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SAM' `
        -Name AuditLegacyPasswordRpcMethods -Value 1 -Type DWord

SAM then writes event 16985 to the System log, provider
`Microsoft-Windows-Directory-Services-SAM`, once for each legacy call, with
the method and the caller. During a join it logged two, both with Client
Network Address 10.20.2.20 and Username `ISE1$`:

| Order | RPC Method | Blocked by Server 2025 |
|---|---|---|
| 1 | `SamrSetInformationUser` | no |
| 2 | `SamrUnicodeChangePasswordUser2` | yes, one of the three |

To read them:

    Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-Directory-Services-SAM'; Id=16984,16985} |
        Select-Object TimeCreated, Id, Message

Set the value back to 0 when done. Even without it the DC leaves a trace:
summary event 16984, "detected N legacy password change or set RPC method
calls in the past 60 minutes", had appeared at the times of the failed joins
(19:58:34 and 21:13:54 UTC). That event is the cheap first thing to look for
when a join ends in access denied.

Cisco's workaround is a policy on the DC: Computer Configuration >
Administrative Templates > System > Security Account Manager > "Configure
SAM change password RPC methods policy", set to "Allow all change password
RPC methods". As a registry value it is the DWORD
`SamrChangeUserPasswordApiPolicy` under
`HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SAM`:

| Value | Meaning |
|---|---|
| 1 | Block all the change password RPC methods |
| 2 | Allow only the strong encryption method. What a DC does when the value is unset |
| 3 | Allow all of them. The workaround |

The operator approved it and set the value to 3 on the running DC, and it
read back as 3. The join failed again with the same error. Then `dc1` was
restarted (`az vm restart`, boot at 21:22 UTC, the directory answering about
two minutes later), and the same join call, with nothing else changed,
returned HTTP 204. ISE was joined.

So the policy is read when the DC starts. Neither Cisco's notice nor the
policy's own description says a restart is needed. On a DC that is already
running, set the value and restart it. On a DC built by this repo the value
is set in stage 1 ahead of the promotion reboot (Part 1), and none of this
should come up. No DC has been built from nothing since that change, so the
first build after it is the test. Stage 1 skips a server that is already a
domain controller, so rerunning `24-ad-up.sh` does not put the value on an
existing DC.

Value 3 makes the DC accept the older, more weakly encrypted password change
methods again, as Server 2022 and earlier did. That is accepted for this
lab and bounded in ADR 0010's amendment: `dc1` has no public address, only
`snet-apps` and the lab range reach it, its passwords are generated, and it
is destroyed with the session. It comes out when Cisco ships a fix for 3.5.
A customer with a Server 2025 domain will need the same setting, or an ISE
patch that carries the fix.

### Selecting the groups

ISE can use a directory group in a rule only after the group has been
selected on the join point. In the GUI that is the join point's Groups tab >
Add > Select Groups From Directory. Over ERS it is two calls.

Ask the join point what groups the domain has:

    PUT https://localhost:8443/ers/config/activedirectory/<id>/getGroupsByDomain

    {"OperationAdditionalData": {"additionalData": [
        {"name": "domain", "value": "corp.rooez.com"}]}}

On 2026-09-17 it returned 53 groups, each with a name, a SID, and a type.
The two that matter:

    corp.rooez.com/Users/Mushroom-Kingdom    GLOBAL
    corp.rooez.com/Users/Koopa-Troop         GLOBAL

Take each group's `sid` from this answer. SIDs are different in every build
of the forest, so they are never written down or hardcoded.

Then add the groups. The obvious call, a plain
`PUT /ers/config/activedirectory/<id>` with the updated object, is refused
with HTTP 405, "The requested Method is not supported for that resource".
The one that works:

    PUT https://localhost:8443/ers/config/activedirectory/<id>/addGroups

    {"ERSActiveDirectory": {
        ...the join point exactly as GET returned it, without "link"...,
        "adgroups": {"groups": [
            {"name": "corp.rooez.com/Users/Mushroom-Kingdom", "sid": "<from getGroupsByDomain>", "type": "GLOBAL"},
            {"name": "corp.rooez.com/Users/Koopa-Troop",      "sid": "<from getGroupsByDomain>", "type": "GLOBAL"}]}}}

It answers 204, and `GET /ers/config/activedirectory/<id>` then lists both
groups under `adgroups`.

### Checking what ISE sees for a user

    PUT https://localhost:8443/ers/config/activedirectory/<id>/getUserGroups

    {"OperationAdditionalData": {"additionalData": [
        {"name": "username", "value": "mario"}]}}

| User | Groups ISE returned |
|---|---|
| `mario` | `Builtin/Users`, `Users/Mushroom-Kingdom`, `Users/Domain Users` |
| `bowser` | `Builtin/Users`, `Users/Domain Users`, `Users/Koopa-Troop` |

That is the CSV, read back through ISE.

### End to end: a directory user from the switch

No ISE policy change was needed for this. The Default policy set
authenticates against `All_User_ID_Stores`, and that sequence includes
`All_AD_Join_Points` as ISE ships. We did not change it. A joined domain is
searched as soon as the join succeeds.

On `sw1`, the Catalyst 9000v that ISE knows as the network device
10.100.0.3, with its RADIUS servers in the group `ISE-GROUP`:

    sw1# test aaa group radius mario <AD_LAB_USER_PASSWORD> new-code
    User successfully authenticated

    sw1# test aaa group radius mario <a wrong password> new-code
    User rejected

The placeholder stands for the value of `AD_LAB_USER_PASSWORD` in `ad.env`.
Typed this way the password lands in the switch's command history, which is
tolerable for a generated lab password on a lab switch and nowhere else.

The DC's Security log shows that Active Directory gave both answers, and not
ISE's internal store. Event 4776, Logon Account `mario@corp.rooez.com`,
Source Workstation `\\ISE1`:

| Attempt | Error Code |
|---|---|
| Right password | `0x0` |
| Wrong password | `0xC000006A` |

    Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4776} -MaxEvents 10 |
        Select-Object TimeCreated, Message

### If the API stops answering partway through

The `ise` tunnel on `localhost:8443` does not survive ISE's restarts. After
the repoint it answered first with connection reset and then with connection
refused, which looks like ISE being down. It was the tunnel.
`scripts/50-tunnels.sh status` shows the forwards, and
`scripts/50-tunnels.sh up` restored this one.

### A PEAP login from an endpoint as a directory user

`test aaa` is the switch asking on its own behalf. It proves the path from
RADIUS to the directory and nothing about a supplicant, so the last check is
a real 802.1X login. `emp-pc` is an Ubuntu node on `sw1` Gi1/0/2 running
`wpa_supplicant` from a systemd unit, `wired-peap`. Its config,
`/etc/wpa_supplicant/wired-peap.conf` (mode 0600), names the user; the
password is `AD_LAB_USER_PASSWORD` from `config/mcp-env/ad.env`:

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

Then `sudo systemctl restart wired-peap` and
`sudo journalctl -u wired-peap --since -1m`. On 2026-09-17 it read:

    CTRL-EVENT-EAP-METHOD EAP vendor 0 method 25 (PEAP) selected
    CTRL-EVENT-EAP-PEER-CERT depth=0 subject='/CN=ise1.corp.rooez.com'
    EAP-MSCHAPV2: Authentication succeeded
    CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully

The certificate is the self-signed one ISE generated when its domain name
changed. The config has no `ca_cert` line, so the supplicant does not check
it; that ends when ISE carries a certificate from `corp-rooez-CA`.

On the switch, `show access-session interface GigabitEthernet1/0/2 details`
showed `User-Name: mario`, `Status: Authorized`, `dot1x Authc Success`. On
the DC, event 4776 for `mario@corp.rooez.com` from workstation `\\ISE1`,
error code 0x0, carried the same second as the supplicant's success.

## Part 4: what is still ahead

None of this is done.

1. Authorization rules that use `Mushroom-Kingdom` and `Koopa-Troop`. The
   groups are selected and no rule refers to them. Mapping a group to a
   Security Group Tag belongs to TrustSec Phase 2.
2. A certificate for ISE signed by `corp-rooez-CA`: import the CA's root
   into ISE's trusted store, generate a request for EAP and admin use, have
   the CA sign it from the `WebServer` template, and bind the result. That
   replaces the self-signed certificate the domain name change generated.
