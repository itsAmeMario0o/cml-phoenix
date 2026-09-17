# 10-promote-forest.ps1: make this server the first domain controller of a
# new forest, then reboot.
#
# Installs the AD DS and DNS roles and runs Install-ADDSForest, the same
# call as the operator's AWS Quick Start script of that name
# (cfn-ps-microsoft-activedirectory, scripts/archive/Install-ADDSForest.ps1)
# with the SSM and CloudFormation wrapping removed. The reboot is scheduled
# fifteen seconds out instead of taken at once, so this run command reports
# success before the machine goes down. Reruns are safe: a server that is
# already a domain controller is left alone. ADR 0010.
param(
    [Parameter(Mandatory = $true)][string]$DomainName,
    [Parameter(Mandatory = $true)][string]$NetbiosName,
    [Parameter(Mandatory = $true)][string]$SafeModePassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Force -Path 'C:\lab\log'
$null = Start-Transcript -Path 'C:\lab\log\10-promote-forest.txt' -Append

try {
    # DomainRole 4 and 5 are backup and primary domain controller.
    $role = (Get-CimInstance -ClassName Win32_ComputerSystem).DomainRole
    if ($role -ge 4) {
        Write-Output "already a domain controller (DomainRole $role), nothing to do"
        return
    }

    $null = Install-WindowsFeature -Name 'AD-Domain-Services', 'DNS' -IncludeManagementTools
    $secure = ConvertTo-SecureString -String $SafeModePassword -AsPlainText -Force
    $null = Install-ADDSForest -DomainName $DomainName -DomainNetbiosName $NetbiosName `
        -SafeModeAdministratorPassword $secure -InstallDns -NoRebootOnCompletion -Force

    # ISE's domain join changes its machine password with
    # SamrUnicodeChangePasswordUser2, which a Server 2025 DC refuses by
    # default (Cisco FN74321, seen on ISE 3.5). 3 allows every SAM change
    # password RPC method, as Server 2022 did. SAM reads it at startup, so
    # it is set here, ahead of the promotion reboot. Accepted for a lab DC
    # with no public address; remove when ISE is fixed. ADR 0010.
    $samPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\SAM'
    $null = New-Item -Path $samPolicy -Force
    Set-ItemProperty -Path $samPolicy -Name 'SamrChangeUserPasswordApiPolicy' -Type DWord -Value 3

    $null = & shutdown.exe /r /t 15 /c 'forest promotion'
    Write-Output "forest $DomainName installed, rebooting in 15 seconds"
}
finally {
    $null = Stop-Transcript
}
