# run-as-admin.ps1: run one of the lab's scripts as the domain administrator.
#
# An Azure run command executes as SYSTEM, which on a domain controller is
# only the machine account: it cannot install an Enterprise CA, which takes
# Enterprise Admins. The run command's own run-as option does not help
# either. It looks the user up as a local account, and a domain controller
# has none ("System error thrown for RunAs user", 2026-09-17). So this
# wrapper, still as SYSTEM, waits for the directory, then runs the inner
# script from a one-shot scheduled task registered with the administrator's
# password, which gives it a full logon token with no double hop.
#
# Terraform builds the delivered script by replacing the marker line below
# with the inner script's text. The inner script's arguments arrive as one
# base64 JSON object, a protected parameter, because they can hold
# passwords; they reach the task through a file only administrators can
# read, never a command line, and the file is removed afterward. ADR 0010.
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$AdminUser,
    [Parameter(Mandatory = $true)][string]$AdminPassword,
    [Parameter(Mandatory = $true)][string]$ArgumentsBase64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$inner = @'
__INNER_SCRIPT__
'@

function Wait-Directory {
    # After promotion the server reboots and AD DS takes several minutes to
    # start. A domain logon, which the scheduled task needs, fails until
    # then, so the wait belongs here and not inside the inner script.
    $deadline = (Get-Date).AddMinutes(25)
    while ((Get-Date) -lt $deadline) {
        try {
            Import-Module -Name ActiveDirectory
            $null = Get-ADDomain
            return
        }
        catch {
            Start-Sleep -Seconds 20
        }
    }
    throw 'the directory did not answer within 25 minutes'
}

$bin = 'C:\lab\bin'
$task = "lab-$Name"
$argsFile = Join-Path $bin "$Name.args.json"
$launcher = Join-Path $bin "$Name.launch.ps1"

try {
    Wait-Directory

    $null = New-Item -ItemType Directory -Force -Path $bin
    & icacls.exe $bin /inheritance:r /grant 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' > $null
    Set-Content -Path (Join-Path $bin "$Name.ps1") -Value $inner -Encoding UTF8
    $json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($ArgumentsBase64))
    Set-Content -Path $argsFile -Value $json -Encoding UTF8
    Set-Content -Path $launcher -Encoding UTF8 -Value @"
`$a = Get-Content -Raw -Path '$argsFile' | ConvertFrom-Json
`$h = @{}
`$a.PSObject.Properties | ForEach-Object { `$h[`$_.Name] = `$_.Value }
& '$bin\$Name.ps1' @h
"@

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$launcher`""
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    $null = Register-ScheduledTask -TaskName $task -Action $action -User $AdminUser `
        -Password $AdminPassword -RunLevel Highest
    Start-ScheduledTask -TaskName $task

    $deadline = (Get-Date).AddMinutes(30)
    do {
        Start-Sleep -Seconds 10
        $state = (Get-ScheduledTask -TaskName $task).State
    } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

    $result = (Get-ScheduledTaskInfo -TaskName $task).LastTaskResult
    $log = "C:\lab\log\$Name.txt"
    if (Test-Path -Path $log) {
        Get-Content -Path $log -Tail 40
    }
    if ($state -eq 'Running') {
        throw "$Name was still running after 30 minutes"
    }
    if ($result -ne 0) {
        throw "$Name failed as $AdminUser, task result $result. Transcript: $log"
    }
    Write-Output "$Name finished as $AdminUser"
}
finally {
    Remove-Item -Path $argsFile -Force -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}
