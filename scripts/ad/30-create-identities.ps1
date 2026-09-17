# 30-create-identities.ps1: lab groups and users from the tracked CSV, the
# account ISE joins the domain with, and ISE's DNS records.
#
# The CSV arrives base64 encoded so that its line breaks survive as one run
# command parameter. svc-ise is created here, not in the CSV, because it has
# its own password and a delegation, and a reader should not have to know
# that one CSV row is special. Every step is skipped when its object already
# exists, so a rerun changes nothing. ADR 0010.
param(
    [Parameter(Mandatory = $true)][string]$CsvBase64,
    [Parameter(Mandatory = $true)][string]$DomainName,
    [Parameter(Mandatory = $true)][string]$NetbiosName,
    [Parameter(Mandatory = $true)][string]$IseHostName,
    [Parameter(Mandatory = $true)][string]$IseIp,
    [Parameter(Mandatory = $true)][string]$LabUserPassword,
    [Parameter(Mandatory = $true)][string]$SvcIsePassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Force -Path 'C:\lab\log'
$null = Start-Transcript -Path 'C:\lab\log\30-create-identities.txt' -Append

function Add-LabUser {
    param([string]$Name, [string]$Display, [string]$Password, [string]$Description)
    if (Get-ADUser -Filter "SamAccountName -eq '$Name'") {
        return
    }
    $secure = ConvertTo-SecureString -String $Password -AsPlainText -Force
    New-ADUser -Name $Display -SamAccountName $Name -UserPrincipalName "$Name@$DomainName" `
        -DisplayName $Display -Description $Description -AccountPassword $secure `
        -Enabled $true -PasswordNeverExpires $true
    Write-Output "created user $Name"
}

function Add-IseDnsRecords {
    $octets = $IseIp.Split('.')
    $reverseZone = "$($octets[2]).$($octets[1]).$($octets[0]).in-addr.arpa"
    if (-not (Get-DnsServerResourceRecord -ZoneName $DomainName -Name $IseHostName -RRType 'A' -ErrorAction SilentlyContinue)) {
        Add-DnsServerResourceRecordA -ZoneName $DomainName -Name $IseHostName -IPv4Address $IseIp
        Write-Output "added A record $IseHostName.$DomainName"
    }
    if (-not (Get-DnsServerZone -Name $reverseZone -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -NetworkId "$($octets[0]).$($octets[1]).$($octets[2]).0/24" -ReplicationScope 'Forest'
    }
    if (-not (Get-DnsServerResourceRecord -ZoneName $reverseZone -Name $octets[3] -RRType 'Ptr' -ErrorAction SilentlyContinue)) {
        Add-DnsServerResourceRecordPtr -ZoneName $reverseZone -Name $octets[3] -PtrDomainName "$IseHostName.$DomainName"
        Write-Output "added PTR record for $IseIp"
    }
}

try {
    Import-Module -Name ActiveDirectory
    $csvText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($CsvBase64))
    $rows = @($csvText | ConvertFrom-Csv)

    foreach ($row in $rows) {
        Add-LabUser -Name $row.username -Display $row.display -Password $LabUserPassword -Description 'lab user'
        foreach ($group in @($row.groups.Split(';') | Where-Object { $_ })) {
            if (-not (Get-ADGroup -Filter "Name -eq '$group'")) {
                New-ADGroup -Name $group -GroupScope 'Global' -GroupCategory 'Security'
                Write-Output "created group $group"
            }
            Add-ADGroupMember -Identity $group -Members $row.username
        }
    }

    Add-LabUser -Name 'svc-ise' -Display 'svc-ise' -Password $SvcIsePassword -Description 'ISE domain join'
    # ISE creates its own computer object when it joins.
    $computers = "CN=Computers,$((Get-ADDomain).DistinguishedName)"
    & dsacls.exe $computers /G "$NetbiosName\svc-ise:CC;computer" > $null
    # Creating the object does not let svc-ise write operatingSystem,
    # operatingSystemVersion, or msDS-SupportedEncryptionTypes on it. ISE
    # survives the denial but leaves its computer object without them, so
    # grant write property on computer objects under Computers.
    & dsacls.exe $computers /I:S /G "$NetbiosName\svc-ise:WP;;computer" > $null

    Add-IseDnsRecords
    Write-Output "identities done: $($rows.Count) users plus svc-ise"
}
finally {
    $null = Stop-Transcript
}
