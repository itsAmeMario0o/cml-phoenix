# 20-install-ca.ps1: wait for the directory, point DNS at Azure's resolver,
# and install a one tier Enterprise Root CA.
#
# Runs as the domain administrator, not SYSTEM: an Enterprise CA writes to
# the forest's configuration partition, which takes Enterprise Admins. The
# CA values and the certutil block come from the operator's AWS Quick Start
# (cfn-ps-microsoft-pki, scripts/archive/Invoke-EnterpriseCaConfig.ps1)
# with the Secrets Manager, S3 CRL publishing, and CloudFormation signals
# removed. One addition for this lab: domain controllers may enroll from
# the WebServer template, so a later CSR can be signed from a plain run
# command. Nothing is done about subject alternative names, on purpose: ISE
# carries its SANs inside the CSR and WebServer is a supply-in-the-request
# template, so they survive signing as they are. The flag that lets a
# submitter add SANs as request attributes (EDITF_ATTRIBSUBJECTALTNAME2) is
# a known escalation path and Server 2025's certutil no longer accepts its
# name. Reruns are safe. ADR 0010.
param(
    [Parameter(Mandatory = $true)][string]$CaCommonName,
    [Parameter(Mandatory = $true)][string]$NetbiosName,
    [string]$Forwarder = '168.63.129.16'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Force -Path 'C:\lab\log'
$null = Start-Transcript -Path 'C:\lab\log\20-install-ca.txt' -Append

function Set-CaRegistry {
    # certutil is a native command: it fails by exit code, not by exception,
    # and the first build lost a failure here by discarding the output.
    param([string]$Name, [string]$Value)
    $out = & certutil.exe -setreg $Name $Value 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "certutil -setreg $Name $Value failed ($LASTEXITCODE): $($out | Select-Object -Last 1)"
    }
}

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

    # The value the CA reads is CRLOverlapUnits. The Quick Start this block
    # came from writes CRLOverlapPeriodUnits, which nothing reads.
    Set-CaRegistry -Name 'CA\CRLOverlapUnits' -Value '12'
    Set-CaRegistry -Name 'CA\CRLOverlapPeriod' -Value 'Hours'
    Set-CaRegistry -Name 'CA\ValidityPeriodUnits' -Value '5'
    Set-CaRegistry -Name 'CA\ValidityPeriod' -Value 'Years'
    Set-CaRegistry -Name 'CA\AuditFilter' -Value '127'
    Restart-Service -Name 'certsvc'
    & certutil.exe -crl > $null

    $template = "CN=WebServer,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,$($domain.DistinguishedName)"
    & dsacls.exe $template /G "$NetbiosName\Domain Controllers:CA;Enroll" > $null
    Write-Output "Enterprise Root CA $CaCommonName installed"
}
finally {
    $null = Stop-Transcript
}
