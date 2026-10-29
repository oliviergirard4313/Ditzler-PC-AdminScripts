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
    [string]$ScriptPath = "C:\Service\Scripts\DashboardSuperops\Generate SuperOps Alert Dashboard.ps1"
)

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Generator-Skript nicht gefunden unter: $ScriptPath (zuerst dorthin kopieren - C:\Service\Scripts ist der Ablageort fuer per Aufgabenplanung ausgefuehrte Skripte, nicht C:\ProgramData\Superops\Scripts, das gehoert SuperOps selbst)."
}

$Action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

# [TimeSpan]::MaxValue ergibt eine Dauer ("P99999999DT23H59M59S"), die das
# Task-Scheduler-XML-Schema als ausserhalb des gueltigen Bereichs ablehnt
# (live auf SV-OS-PRB-01 bestaetigt: "task XML contains a value which is
# incorrectly formatted or out of range"). 10 Jahre sind praktisch
# "unbegrenzt" fuer diesen Zweck und werden vom Schema akzeptiert.
$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

if ($PSCmdlet.ShouldProcess($TaskName, "Aufgabe registrieren/ersetzen")) {
    # -ErrorAction Stop, damit ein fehlgeschlagenes Register-ScheduledTask (z.B.
    # ungueltiges Trigger-XML) den Erfolgstext unten NICHT trotzdem ausgibt -
    # live beobachtet: Register-ScheduledTask schreibt bei diesem Fehler nur
    # einen NICHT-terminierenden Fehler, das Skript lief bisher trotzdem bis
    # zur "registriert"-Meldung durch, obwohl die Aufgabe nicht angelegt wurde.
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
        -Principal $Principal -Settings $Settings -Force -ErrorAction Stop | Out-Null

    Write-Host "Aufgabe '$TaskName' registriert (alle 1 Minute, als SYSTEM)." -ForegroundColor Green
    Write-Host "Manuell testen mit: Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor Cyan
}
