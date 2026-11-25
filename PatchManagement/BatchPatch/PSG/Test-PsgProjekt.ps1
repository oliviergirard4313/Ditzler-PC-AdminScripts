#Requires -Version 5.1
<#
.SYNOPSIS
    PSG nach dem Patchen: automatische Kontrollen (nur lesen).

.DESCRIPTION
    Erkennt die Rolle am Hostnamen:
      SV-PSG-HIST-01 : Historian-Dienste, Lizenzserver, Ports 14000/8070/3333/27000
      SV-PSG-CIM-0x  : Projekt CIP_MASTER (Prozesse), Router/RtrPing zum
                       Partner, Historian-Collector, KEPServerEX, SQL Server,
                       Erreichbarkeit Historian (14000)
    Ergebnis je Pruefung OK / FEHLER / INFO, Bericht in
    C:\Service\BatchPatch\PSG\Logs\Test-PsgProjekt_<Zeit>.log

    Nicht automatisch pruefbar (manuell, siehe Ablauf-PSG-Patch.md):
    Lizenz KEPServerEX = Good, GefRedundancy Online/Online,
    Historian Administrator (Active/Standby).

    Aufruf durch BatchPatch (Deployment, als SYSTEM / Administrator):
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File Test-PsgProjekt.ps1

.NOTES
    Autor   : Olivier
    Version : 1.0
    Datum   : 23.11.2026

    Exitcodes:
      0  = alle Pruefungen OK
      10 = mindestens eine Pruefung FEHLER
      1  = Unerwarteter Fehler
#>
param(
    [string]$Arbeitsordner = 'C:\Service\BatchPatch\PSG',
    [string]$HistorianServer = 'SV-PSG-HIST-01'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path "$Arbeitsordner\Logs" | Out-Null
$LogFile = Join-Path "$Arbeitsordner\Logs" ("Test-PsgProjekt_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$script:Fehler = 0
function Write-Log {
    param([string]$Msg)
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Msg
    Write-Output $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Pruefe {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if (-not $Ok) { $script:Fehler++ }
    Write-Log ("{0,-7} {1}{2}" -f $(if ($Ok) { 'OK' } else { 'FEHLER' }), $Name, $(if ($Detail) { " - $Detail" } else { '' }))
}
function Info { param([string]$T) Write-Log ("INFO    {0}" -f $T) }
function Test-Port {
    param([string]$Ziel, [int]$Port)
    $c = New-Object Net.Sockets.TcpClient
    try { return $c.ConnectAsync($Ziel, $Port).Wait(3000) } catch { return $false } finally { $c.Dispose() }
}
function Pruefe-Dienste {
    param([string[]]$Namen)
    $i = 0
    foreach ($n in $Namen) {
        $i++
        Write-Progress -Activity 'Dienste' -Status "[$i/$($Namen.Count)] $n" -PercentComplete ($i / $Namen.Count * 100)
        $s = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if (-not $s) { Pruefe "Dienst $n" $false 'nicht vorhanden'; continue }
        Pruefe "Dienst $n" ($s.State -eq 'Running') ("{0}, {1}" -f $s.State, $s.StartMode)
    }
    Write-Progress -Activity 'Dienste' -Completed
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').UBR
    Write-Log ("===== Test-PsgProjekt {0} =====" -f $env:COMPUTERNAME)
    Info ("Build {0}.{1}, letzter Start {2:dd.MM.yyyy HH:mm}" -f $os.BuildNumber, $ubr, $os.LastBootUpTime)
    $hf = Get-HotFix | Sort-Object { $_.InstalledOn } -Descending | Select-Object -First 3
    Info ("Letzte Updates: {0}" -f (($hf | ForEach-Object { '{0} ({1:dd.MM.yyyy})' -f $_.HotFixID, $_.InstalledOn }) -join ', '))
    $rebootNoetig = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                    (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    Pruefe 'Kein Neustart ausstehend' (-not $rebootNoetig)

    if ($env:COMPUTERNAME -eq $HistorianServer) {
        # ---------- Historian ----------
        Pruefe-Dienste @('IHDataArchiver_x64', 'IHDiagnosticManager_x64', 'IndexingService', 'HistorianTomcat', 'historianPostgres',
                         'UaaTomcat', 'uaaPgSql', 'FNEServer', 'LicenseServerHelperService', 'CCFLIC0', 'CCFLIC4', 'GGLicenseManager', 'CIMPLICITY')
        foreach ($p in @(@{ P = 14000; T = 'Historian Archiver' }, @{ P = 8070; T = 'Historian REST API' }, @{ P = 3333; T = 'Proficy Lizenzserver' }, @{ P = 27000; T = 'lmgrd (WebSpace-Lizenz)' })) {
            Pruefe ("Port {0} ({1})" -f $p.P, $p.T) (Test-Port 'localhost' $p.P)
        }
    }
    elseif ($env:COMPUTERNAME -match '^SV-PSG-CIM-0[12]$') {
        # ---------- CIMPLICITY ----------
        $Partner = if ($env:COMPUTERNAME -eq 'SV-PSG-CIM-01') { 'SV-PSG-CIM-02' } else { 'SV-PSG-CIM-01' }
        $Collector = 'ihOPCCollector-CIMPLICITY_HMI_OPCServer_1'
        $sql = @(Get-CimInstance Win32_Service | Where-Object { $_.Name -match '^(MSSQL\$|MSSQLSERVER$)' -and $_.StartMode -eq 'Auto' } | Select-Object -ExpandProperty Name)
        Pruefe-Dienste (@('CIMPLICITY', 'CimProxy', 'CIMConfigService', 'CIMPLICITYNGINX', 'KEPServerEXV6', 'KEPServerEXConfigAPI6',
                          'KEPServerEXLoggerV6', 'CCFLIC0', 'CCFLIC4', $Collector) + $sql)

        # Projekt CIP_MASTER (4.1)
        $Projektprozesse = @('ptm_rp', 'amrp', 'emrp', 'ptx_rp', 'pm_mcp', 'dl_rp', 'dl_cor_rp', 'ur', 'ptmdp', 'ptdl', 'CalRp', 'iHistOPC', 'CimOPCClient')
        $laufend = @(Get-Process -Name $Projektprozesse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -Unique)
        $fehlend = @($Projektprozesse | Where-Object { $_ -notin $laufend })
        Pruefe 'Projekt CIP_MASTER (Prozesse)' ($fehlend.Count -eq 0) $(if ($fehlend) { "fehlt: $($fehlend -join ', ')" } else { "$($Projektprozesse.Count) Prozesse laufen" })

        # Redundanz (4.3): Router + RtrPing zum Partner
        Pruefe 'Router w32rtr' ([bool](Get-Process w32rtr -ErrorAction SilentlyContinue))
        $rp = Get-CimInstance Win32_Process -Filter "Name='RtrPing.exe'" | Where-Object { $_.CommandLine -match $Partner }
        Pruefe "RtrPing -> $Partner" ([bool]$rp)
        Pruefe "Partner $Partner Router-Port 32000" (Test-Port $Partner 32000)

        # Historian (4.2)
        Pruefe "Historian $HistorianServer Port 14000" (Test-Port $HistorianServer 14000)
        $reg = Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Intellution, Inc.\iHistorian\Services\OPCCollector' -ErrorAction SilentlyContinue |
               Where-Object { $_.PSChildName -like "$($env:COMPUTERNAME)_OPC_*" } | Select-Object -First 1
        if ($reg) {
            $aktiv = (Get-ItemProperty $reg.PSPath).RedundancyIsActiveCollector
            Info ("Collector-Redundanz: {0} (Vergleich mit Partner im Historian Administrator: genau einer Active)" -f $(if ($aktiv -eq 1) { 'ACTIVE' } else { 'Standby' }))
        }
    }
    else {
        Info "Kein PSG-Server ($env:COMPUTERNAME) - nur allgemeine Pruefungen."
    }

    # Allgemein: automatische Dienste, die nicht laufen (nur Information)
    $gestoppt = @(Get-CimInstance Win32_Service | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' -and
                  $_.Name -notmatch '^(gupdate|edgeupdate|MapsBroker|RemoteRegistry|sppsvc|WbioSrvc|tiledatamodelsvc|CDPSvc|ShellHWDetection|clr_optimization.*|wuauserv|BITS|UsoSvc)$' } |
                  Select-Object -ExpandProperty Name)
    if ($gestoppt) { Info ("Automatische Dienste nicht gestartet: {0}" -f ($gestoppt -join ', ')) }

    # Fehler im Ereignisprotokoll seit dem Start (nur Information)
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application', 'System'; Level = 1, 2; StartTime = $os.LastBootUpTime } -ErrorAction SilentlyContinue)
    Info ("Fehler im Ereignisprotokoll seit dem Start: {0}" -f $ev.Count)
    $ev | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 8 |
        ForEach-Object { Info ("   {0,4} x {1}" -f $_.Count, $_.Name) }

    Write-Log ("===== Ergebnis: {0} =====" -f $(if ($script:Fehler -eq 0) { 'ALLES OK' } else { "$($script:Fehler) FEHLER" }))
    Write-Log "Bericht: $LogFile"
    if ($script:Fehler -gt 0) { exit 10 } else { exit 0 }
}
catch {
    Write-Log ("Unerwarteter Fehler: {0}" -f $_.Exception.Message)
    exit 1
}
