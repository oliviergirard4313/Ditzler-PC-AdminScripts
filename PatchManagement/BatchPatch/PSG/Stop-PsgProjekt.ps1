#Requires -Version 5.1
<#
.SYNOPSIS
    PSG vor dem Patchen: pruefen, dass CIP_MASTER gestoppt ist, und den Dienst
    CIMPLICITY deaktivieren, damit das Projekt bei den Neustarts NICHT
    automatisch wieder startet.

.DESCRIPTION
    Nur auf SV-PSG-CIM-01 und SV-PSG-CIM-02 (CIMPLICITY Options -> Startup
    Options = "Start projects" CIP_MASTER: das Projekt startet sonst nach
    jedem Neustart von selbst).

    Voraussetzung: das Projekt wurde VORHER manuell im Workbench auf CIM-01
    gestoppt (Stop Redundant Project -> Primary & Secondary).
    Laeuft noch ein Projektprozess, bricht das Skript ab (ExitCode 10) und
    aendert NICHTS -> BatchPatch-Queue stoppt.

    Merkt sich den Zustand (Starttyp CIMPLICITY, Collector) in
    C:\Service\BatchPatch\PSG\Zustand.json fuer Start-PsgProjekt.ps1.

    Aufruf durch BatchPatch (Deployment, als SYSTEM / Administrator):
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Stop-PsgProjekt.ps1
    Probelauf ohne Aenderung: zusaetzlich -DryRun (ExitCode wie im echten Lauf;
    bei laufendem Projekt also 10).

.NOTES
    Autor   : Olivier
    Version : 1.0
    Datum   : 23.11.2026

    Exitcodes:
      0  = OK (Projekt gestoppt, Dienst CIMPLICITY deaktiviert)
      10 = Projekt laeuft noch - nichts geaendert
      20 = Dienst CIMPLICITY konnte nicht deaktiviert werden
      1  = Unerwarteter Fehler
#>
param(
    # Nur pruefen und anzeigen, was gemacht wuerde - nichts aendern
    [switch]$DryRun,
    [string]$Arbeitsordner = 'C:\Service\BatchPatch\PSG',
    # Prozesse von CIP_MASTER (nicht Router/Dienste), Inventar 23.11.2026
    [string[]]$Projektprozesse = @('ptm_rp', 'amrp', 'emrp', 'ptx_rp', 'pm_mcp', 'dl_rp', 'dl_cor_rp', 'ur', 'ptmdp', 'ptdl', 'CalRp', 'iHistOPC', 'CimOPCClient', 'dyn_dir'),
    [string]$CollectorDienst = 'ihOPCCollector-CIMPLICITY_HMI_OPCServer_1'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path "$Arbeitsordner\Logs" | Out-Null
$LogFile = Join-Path "$Arbeitsordner\Logs" ("Stop-PsgProjekt_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] [{2}] {3}" -f (Get-Date), $Level, $env:COMPUTERNAME, $Msg
    Write-Output $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

try {
    Write-Log ("----- Stop-PsgProjekt{0} -----" -f $(if ($DryRun) { ' [DRY-RUN: nichts wird geaendert]' } else { '' }))
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Log ("Konto: {0}, Administrator: {1}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name, $admin)
    $cimVorher = Get-CimInstance Win32_Service -Filter "Name='CIMPLICITY'"
    if (-not $cimVorher) { Write-Log 'Dienst CIMPLICITY nicht vorhanden - falscher Server?' 'ERROR'; exit 20 }
    Write-Log ("Dienst CIMPLICITY: {0}, {1}" -f $cimVorher.State, $cimVorher.StartMode)

    # 1. Laeuft das Projekt noch?
    $laufend = @(Get-Process -Name $Projektprozesse -ErrorAction SilentlyContinue)
    if ($laufend.Count -gt 0) {
        Write-Log ("Projekt laeuft noch: {0}" -f (($laufend.Name | Sort-Object -Unique) -join ', ')) 'ERROR'
        Write-Log 'Zuerst CIP_MASTER im Workbench auf CIM-01 stoppen (Primary & Secondary). Nichts geaendert.' 'ERROR'
        if (-not $DryRun) { exit 10 }
        Write-Log '[DRY-RUN] Echter Lauf wuerde hier mit ExitCode 10 abbrechen (erwartet, solange das Projekt laeuft). Probelauf zeigt trotzdem die weiteren Schritte.'
        $DryExit = 10
    } else {
        Write-Log 'OK: keine Projektprozesse aktiv.'
        $DryExit = 0
    }

    # 2. Zustand merken (nur beim ersten Lauf, damit ein Wiederholungslauf
    #    nicht "Disabled" als Ausgangszustand speichert)
    $ZustandDatei = Join-Path $Arbeitsordner 'Zustand.json'
    $cim  = Get-CimInstance Win32_Service -Filter "Name='CIMPLICITY'"
    $coll = Get-CimInstance Win32_Service -Filter "Name='$CollectorDienst'" -ErrorAction SilentlyContinue
    if ($DryRun) {
        Write-Log ("[DRY-RUN] wuerde speichern: CIMPLICITY StartMode={0}, Collector={1} -> {2}" -f $cim.StartMode, $(if ($coll) { $coll.State } else { 'fehlt' }), $ZustandDatei)
        Write-Log '[DRY-RUN] wuerde Dienst CIMPLICITY auf Disabled setzen. Nichts geaendert.'
        Write-Log "[DRY-RUN] ExitCode des echten Laufs: $DryExit"
        exit $DryExit
    }
    if ($cim.StartMode -ne 'Disabled' -or -not (Test-Path $ZustandDatei)) {
        $z = [ordered]@{
            Zeit                = (Get-Date).ToString('s')
            CimplicityStartMode = $(if ($cim.StartMode -eq 'Disabled') { 'Auto' } else { $cim.StartMode })
            CollectorDienst     = $CollectorDienst
            CollectorStatus     = $(if ($coll) { $coll.State } else { 'fehlt' })
        }
        $z | ConvertTo-Json | Set-Content -Path $ZustandDatei -Encoding UTF8
        Write-Log ("Zustand gespeichert: CIMPLICITY StartMode={0}, Collector={1}" -f $z.CimplicityStartMode, $z.CollectorStatus)
    } else {
        Write-Log "CIMPLICITY bereits deaktiviert, vorhandene Zustand.json bleibt." 'WARN'
    }

    # 3. Dienst CIMPLICITY deaktivieren (Router laeuft weiter bis zum Neustart)
    try {
        Set-Service -Name CIMPLICITY -StartupType Disabled
    } catch {
        Write-Log "Starttyp CIMPLICITY nicht aenderbar: $($_.Exception.Message)" 'ERROR'
        exit 20
    }
    $neu = (Get-CimInstance Win32_Service -Filter "Name='CIMPLICITY'").StartMode
    if ($neu -ne 'Disabled') { Write-Log "CIMPLICITY StartMode ist '$neu' statt Disabled." 'ERROR'; exit 20 }
    Write-Log 'Dienst CIMPLICITY: Starttyp Disabled -> Projekt startet bei den Neustarts NICHT.'
    Write-Log '----- Fertig -----'
    exit 0
}
catch {
    Write-Log ("Unerwarteter Fehler: {0}" -f $_.Exception.Message) 'ERROR'
    exit 1
}
