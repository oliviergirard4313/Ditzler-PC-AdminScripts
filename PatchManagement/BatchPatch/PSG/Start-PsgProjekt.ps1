#Requires -Version 5.1
<#
.SYNOPSIS
    PSG nach dem Patchen: Dienst CIMPLICITY wieder auf Automatisch setzen und
    starten. Dadurch startet CIP_MASTER von selbst (Startup Options = "Start
    projects"). Wartet, bis die Projektprozesse laufen, und startet den
    Historian-Collector, falls er vorher lief.

.DESCRIPTION
    Nur auf SV-PSG-CIM-01 und SV-PSG-CIM-02, Reihenfolge: zuerst CIM-01
    (MASTER), erst danach CIM-02 (SLAVE). Vorher Test-PsgProjekt.ps1 auf
    SV-PSG-HIST-01 (Historian + Lizenzserver muessen laufen).

    Startet das Projekt nicht innerhalb von -TimeoutMin, endet das Skript mit
    ExitCode 20: CIP_MASTER dann manuell im Workbench auf CIM-01 starten.

    Aufruf durch BatchPatch (Deployment, als SYSTEM / Administrator):
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Start-PsgProjekt.ps1
    Probelauf ohne Aenderung: zusaetzlich -DryRun.

.NOTES
    Autor   : Olivier
    Version : 1.0
    Datum   : 23.11.2026

    Exitcodes:
      0  = OK (Projekt laeuft, Collector wie vorher)
      10 = Dienst CIMPLICITY nicht aktivierbar / startbar
      20 = Projekt nach -TimeoutMin nicht gestartet (manuell im Workbench starten)
      30 = Collector lief vorher, startet aber nicht
      1  = Unerwarteter Fehler
#>
param(
    # Nur pruefen und anzeigen, was gemacht wuerde - nichts aendern
    [switch]$DryRun,
    [string]$Arbeitsordner = 'C:\Service\BatchPatch\PSG',
    [int]$TimeoutMin = 15,
    # Kernprozesse von CIP_MASTER: laufen sie, gilt das Projekt als gestartet
    [string[]]$Kernprozesse = @('ptm_rp', 'amrp', 'emrp', 'ptx_rp', 'pm_mcp'),
    [string]$CollectorDienst = 'ihOPCCollector-CIMPLICITY_HMI_OPCServer_1'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path "$Arbeitsordner\Logs" | Out-Null
$LogFile = Join-Path "$Arbeitsordner\Logs" ("Start-PsgProjekt_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] [{2}] {3}" -f (Get-Date), $Level, $env:COMPUTERNAME, $Msg
    Write-Output $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

try {
    Write-Log ("----- Start-PsgProjekt{0} -----" -f $(if ($DryRun) { ' [DRY-RUN: nichts wird geaendert]' } else { '' }))

    if (-not (Get-Service CIMPLICITY -ErrorAction SilentlyContinue)) { Write-Log 'Dienst CIMPLICITY nicht vorhanden - falscher Server?' 'ERROR'; exit 10 }

    # 1. Gespeicherten Zustand lesen (Standard: Auto, Collector lief)
    $ZustandDatei = Join-Path $Arbeitsordner 'Zustand.json'
    $z = $null
    if (Test-Path $ZustandDatei) { $z = Get-Content $ZustandDatei -Raw | ConvertFrom-Json }
    else { Write-Log "Keine Zustand.json - Standardwerte (Auto, Collector Running)." 'WARN' }
    $StartMode       = if ($z) { $z.CimplicityStartMode } else { 'Auto' }
    $CollectorVorher = if ($z) { $z.CollectorStatus } else { 'Running' }
    Write-Log "Zustand vor dem Patchen: CIMPLICITY StartMode=$StartMode, Collector=$CollectorVorher"

    if ($DryRun) {
        $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        Write-Log ("[DRY-RUN] Konto: {0}, Administrator: {1}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name, $admin)
        $c = Get-CimInstance Win32_Service -Filter "Name='CIMPLICITY'"
        Write-Log ("[DRY-RUN] Dienst CIMPLICITY jetzt: {0}, {1} -> wuerde Starttyp {2} setzen und starten" -f $c.State, $c.StartMode, $(if ($StartMode -eq 'Manual') { 'Manual' } else { 'Automatic' }))
        $laufend = @(Get-Process -Name $Kernprozesse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique)
        $fehlend = @($Kernprozesse | Where-Object { $_ -notin $laufend })
        Write-Log ("[DRY-RUN] Kernprozesse jetzt: {0}" -f $(if ($fehlend) { "fehlt: $($fehlend -join ', ')" } else { 'alle laufen -> Warten waere sofort erfuellt' }))
        $s = Get-Service $CollectorDienst -ErrorAction SilentlyContinue
        Write-Log ("[DRY-RUN] Collector {0}: {1} -> {2}" -f $CollectorDienst, $(if ($s) { $s.Status } else { 'fehlt' }),
            $(if ($CollectorVorher -eq 'Running') { 'wuerde gestartet, falls er nach 2 min nicht laeuft' } else { 'wuerde nicht gestartet' }))
        Write-Log '[DRY-RUN] Nichts geaendert.'
        exit 0
    }

    # 2. Dienst CIMPLICITY aktivieren und starten
    try {
        $typ = if ($StartMode -eq 'Manual') { 'Manual' } else { 'Automatic' }
        Set-Service -Name CIMPLICITY -StartupType $typ
        if ((Get-Service CIMPLICITY).Status -ne 'Running') { Start-Service -Name CIMPLICITY }
    } catch {
        Write-Log "Dienst CIMPLICITY: $($_.Exception.Message)" 'ERROR'
        exit 10
    }
    Write-Log ("Dienst CIMPLICITY: Starttyp {0}, Status {1}" -f $typ, (Get-Service CIMPLICITY).Status)

    # 3. Warten auf die Projektprozesse
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $fehlend = $Kernprozesse
    while ($sw.Elapsed.TotalMinutes -lt $TimeoutMin) {
        $laufend = @(Get-Process -Name $Kernprozesse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique)
        $fehlend = @($Kernprozesse | Where-Object { $_ -notin $laufend })
        if ($fehlend.Count -eq 0) { break }
        Write-Progress -Activity 'Warte auf CIP_MASTER' -Status ("{0:N0}/{1} min - fehlt: {2}" -f $sw.Elapsed.TotalMinutes, $TimeoutMin, ($fehlend -join ', ')) -PercentComplete ([math]::Min(100, $sw.Elapsed.TotalMinutes / $TimeoutMin * 100))
        Start-Sleep -Seconds 15
    }
    Write-Progress -Activity 'Warte auf CIP_MASTER' -Completed
    if ($fehlend.Count -gt 0) {
        Write-Log ("Projekt nach {0} min nicht gestartet (fehlt: {1}). CIP_MASTER manuell im Workbench auf CIM-01 starten." -f $TimeoutMin, ($fehlend -join ', ')) 'ERROR'
        exit 20
    }
    Write-Log ("Projekt laeuft (nach {0:N1} min)." -f $sw.Elapsed.TotalMinutes)

    # 4. Collector: nur starten, wenn er vorher lief
    if ($CollectorVorher -eq 'Running') {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ((Get-Service $CollectorDienst).Status -ne 'Running' -and $sw.Elapsed.TotalSeconds -lt 120) { Start-Sleep -Seconds 10 }
        if ((Get-Service $CollectorDienst).Status -ne 'Running') {
            Write-Log "Collector laeuft nicht von selbst - starte $CollectorDienst."
            try { Start-Service -Name $CollectorDienst } catch { Write-Log "Collector-Start: $($_.Exception.Message)" 'ERROR'; exit 30 }
        }
        Write-Log ("Collector: {0}" -f (Get-Service $CollectorDienst).Status)
    } else {
        Write-Log "Collector lief vorher nicht ($CollectorVorher) - nicht gestartet." 'WARN'
    }

    Write-Log '----- Fertig -----'
    exit 0
}
catch {
    Write-Log ("Unerwarteter Fehler: {0}" -f $_.Exception.Message) 'ERROR'
    exit 1
}
