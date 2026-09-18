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

function Invoke-Native {
    # certutil and dsacls are native commands: they fail by exit code, not
    # by exception, so 'Stop' above does nothing for them and a discarded
    # exit code is a lost failure (the first build lost one that way). Every
    # native call goes through here. The preference is relaxed around the
    # call because Windows PowerShell turns redirected stderr into a
    # terminating error under 'Stop', even when the command succeeds. This
    # script runs as its own powershell.exe from a file, so it carries its
    # own copy rather than sharing one with run-as-admin.ps1. ADR 0010.
    param([Parameter(Position = 0)][string]$Command,
          [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Command @Arguments 2>&1
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $Arguments failed ($LASTEXITCODE): $(($out | Select-Object -Last 3) -join ' | ')"
    }
}

function Set-CaRegistry {
    param([string]$Name, [string]$Value)
    Invoke-Native certutil.exe '-setreg' $Name $Value
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
    # Restart-Service returns before the CA's RPC interface accepts calls,
    # and certutil -crl straight after it fails with RPC_S_SERVER_UNAVAILABLE.
    # The first build hid that by discarding certutil's exit code; the
    # 2026-09-18 build, checking it, stopped here. Wait for the CA to answer.
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        $null = & certutil.exe -ping 2>&1
        if ($LASTEXITCODE -eq 0) { break }
        Start-Sleep -Seconds 5
    }
    Invoke-Native certutil.exe '-crl'

    $template = "CN=WebServer,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,$($domain.DistinguishedName)"
    Invoke-Native dsacls.exe $template /G "$NetbiosName\Domain Controllers:CA;Enroll"
    Write-Output "Enterprise Root CA $CaCommonName installed"
}
finally {
    $null = Stop-Transcript
}
