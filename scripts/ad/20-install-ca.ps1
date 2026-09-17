# 20-install-ca.ps1: wait for the directory, point DNS at Azure's resolver,
# and install a one tier Enterprise Root CA.
#
# Runs as the domain administrator, not SYSTEM: an Enterprise CA writes to
# the forest's configuration partition, which takes Enterprise Admins. The
# CA values and the certutil block come from the operator's AWS Quick Start
# (cfn-ps-microsoft-pki, scripts/archive/Invoke-EnterpriseCaConfig.ps1)
# with the Secrets Manager, S3 CRL publishing, and CloudFormation signals
# removed. Two additions for this lab: the CA keeps subject alternative
# names from a request, without which ISE's SAN never survives signing, and
# domain controllers may enroll from the WebServer template, so a later CSR
# can be signed from a plain run command. Reruns are safe. ADR 0010.
param(
    [Parameter(Mandatory = $true)][string]$CaCommonName,
    [Parameter(Mandatory = $true)][string]$NetbiosName,
    [string]$Forwarder = '168.63.129.16'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Force -Path 'C:\lab\log'
$null = Start-Transcript -Path 'C:\lab\log\20-install-ca.txt' -Append

function Wait-Directory {
    # The reboot after promotion and the first start of AD DS take several
    # minutes. Get-ADDomain answering is the signal that both are done.
    $deadline = (Get-Date).AddMinutes(20)
    while ((Get-Date) -lt $deadline) {
        try {
            Import-Module -Name ActiveDirectory
            return (Get-ADDomain)
        }
        catch {
            Start-Sleep -Seconds 20
        }
    }
    throw 'the directory did not answer within 20 minutes'
}

try {
    $domain = Wait-Directory
    Write-Output "directory is up: $($domain.DNSRoot)"

    # 168.63.129.16 is Azure's resolver, reachable from any VM in a VNet,
    # so the DC answers public names without a route to the internet.
    $current = @((Get-DnsServerForwarder).IPAddress | ForEach-Object { $_.IPAddressToString })
    if ($current -notcontains $Forwarder) {
        Set-DnsServerForwarder -IPAddress $Forwarder
        Write-Output "DNS forwarder set to $Forwarder"
    }

    if ((Get-WindowsFeature -Name 'ADCS-Cert-Authority').Installed -and (Get-Service -Name 'certsvc' -ErrorAction SilentlyContinue)) {
        Write-Output 'certification authority already installed, nothing to do'
        return
    }

    $null = Install-WindowsFeature -Name 'ADCS-Cert-Authority' -IncludeManagementTools
    $null = Install-AdcsCertificationAuthority -CAType 'EnterpriseRootCA' -CACommonName $CaCommonName `
        -KeyLength 4096 -HashAlgorithm 'SHA256' -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' `
        -ValidityPeriod 'Years' -ValidityPeriodUnits 5 -Force

    & certutil.exe -setreg CA\CRLOverlapPeriodUnits '12' > $null
    & certutil.exe -setreg CA\CRLOverlapPeriod 'Hours' > $null
    & certutil.exe -setreg CA\ValidityPeriodUnits '5' > $null
    & certutil.exe -setreg CA\ValidityPeriod 'Years' > $null
    & certutil.exe -setreg CA\AuditFilter '127' > $null
    & certutil.exe -setreg policy\EditFlags +EDITF_ATTRIBSUBJECTALTNAME2 > $null
    Restart-Service -Name 'certsvc'
    & certutil.exe -crl > $null

    $template = "CN=WebServer,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,$($domain.DistinguishedName)"
    & dsacls.exe $template /G "$NetbiosName\Domain Controllers:CA;Enroll" > $null
    Write-Output "Enterprise Root CA $CaCommonName installed"
}
finally {
    $null = Stop-Transcript
}
