#Requires -Version 5.1

# ==========================================================
# Register-DashboardTask.ps1
# Einmalig-Werkzeug, DIREKT auf SV-OS-PRB-01 als Administrator ausfuehren.
# ==========================================================
# Autor    : GIO / Claude
# Version  : 1.0
# Datum    : 2026-08-12
#
# Zweck:
#   Richtet eine normale Windows-Aufgabenplanung ein, die
#   "Generate SuperOps Alert Dashboard.ps1" jede Minute als SYSTEM
#   ausfuehrt. Bewusst KEIN SuperOps Recurring Script (siehe Kopf-
#   kommentar des Generator-Skripts): die gewuenschte Taktung von
#   30-60s liegt ausserhalb des ueblichen SuperOps-Rhythmus, und dieses
#   Skript ist kein Monitoring/Alerting, sondern reine Anzeigeerzeugung.
#
#   -WhatIf zuerst verwenden, dann ohne -WhatIf real ausfuehren.
#
# Verhalten:
#   - Legt (bzw. ersetzt) die Aufgabe "Ditzler Dashboard Generator" an.
#   - Trigger: bei Anmeldung des Systems + danach alle 1 Minute,
#     unbegrenzt wiederholt.
# ==========================================================

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$TaskName = "Ditzler Dashboard Generator",
    [string]$ScriptPath = "C:\ProgramData\Superops\Scripts\Generate SuperOps Alert Dashboard.ps1"
)

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Generator-Skript nicht gefunden unter: $ScriptPath (zuerst dorthin kopieren, analog zu Ditzler-Powershell-Lib.psm1/credentials.xml)."
}

$Action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration ([TimeSpan]::MaxValue)

$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

if ($PSCmdlet.ShouldProcess($TaskName, "Aufgabe registrieren/ersetzen")) {
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
        -Principal $Principal -Settings $Settings -Force | Out-Null

    Write-Host "Aufgabe '$TaskName' registriert (alle 1 Minute, als SYSTEM)." -ForegroundColor Green
    Write-Host "Manuell testen mit: Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
}
