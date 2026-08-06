#Requires -Version 5.1

<#
.SYNOPSIS
    Legt die geplante Aufgabe "Ditzler-Scripts Git Sync (Logon)" an
    oder aktualisiert sie - identisch auf jedem PC ausfuehrbar, damit
    Heim-PC und Arbeitslaptop garantiert dieselbe Konfiguration haben.

.DESCRIPTION
    Ersetzt die manuelle Einrichtung ueber die Aufgabenplanungs-GUI, bei
    der beide PCs unbemerkt auseinanderlaufen konnten. Einmal je PC mit
    Administratorrechten ausfuehren (Registrierung einer Aufgabe im
    Kontext des angemeldeten Benutzers erfordert i.d.R. keine erhoehten
    Rechte, -RunLevel Limited genuegt hier bewusst).

.EXAMPLE
    .\Register-DitzlerSyncTask.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName   = "Ditzler-Scripts Git Sync (Logon)"
$ScriptPath = "C:\Admin\Ditzler\Sync-LocalRepo-OnLogon.ps1"

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "FEHLER: $ScriptPath nicht gefunden - erst Repo pullen." -ForegroundColor Red
    exit 1
}

$Action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""

$Trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

$Principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

$Settings  = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 72)

Register-ScheduledTask -TaskName $TaskName `
    -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings `
    -Description "Pullt bei jeder Anmeldung alle lokalen Ditzler-Repos (siehe Sync-DitzlerRepos.ps1)." `
    -Force | Out-Null

Write-Host "Geplante Aufgabe '$TaskName' registriert/aktualisiert fuer $env:USERDOMAIN\$env:USERNAME." -ForegroundColor Green
Get-ScheduledTask -TaskName $TaskName | Format-List TaskName, State
