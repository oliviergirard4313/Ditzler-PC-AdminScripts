#Requires -Version 5.1

# ==========================================================
# INVOKE-MANUALPATCHRUN.PS1
# Zweck    : Orchestriert einen manuellen Patch-Lauf fuer eine Gruppe von
#            Servern. Der Skriptinhalt von Install-ManualPatches-Local.ps1
#            wird per PsExec als EncodedCommand im Speicher uebergeben -
#            die Datei wird nie dauerhaft auf den Zielserver kopiert und
#            existiert ausschliesslich in diesem Repo (das Zielskript
#            legt fuer die Reboot-Fortsetzung selbst eine temporaere,
#            sich selbst loeschende Kopie + Scheduled Task an - siehe
#            Kommentar dort).
#
#            PsExec wird mit -d (nicht auf Prozessende warten) gestartet,
#            da der Zielprozess bei einem Reboot ohnehin nicht "sauber"
#            zurueckkehrt. Der Fortschritt wird stattdessen per Remote-
#            Zugriff (\\server\C$\...) auf die State-Datei des Zielskripts
#            abgefragt - das funktioniert unabhaengig davon, ob der
#            Zielserver zwischendurch neu startet.
#
# Voraussetzung: PsExec.exe (Sysinternals) im PATH oder via -PsExecPath.
#                Admin-Rechte auf die Zielserver (SMB/C$ fuer Statusabfrage,
#                PsExec startet den Zielprozess als SYSTEM).
#
# Beispiel :
#   .\Invoke-ManualPatchRun.ps1 -Category "SV_SW-Std_Manual-Update-Group-2"
#   .\Invoke-ManualPatchRun.ps1 -ServerList SV-OS-PWR-01 -RescanOnly
# ==========================================================

param(
    [string]$Category,
    [string[]]$ServerList,
    [int]$MaxRounds = 2,
    [int]$MaxReboots = 2,
    [switch]$RescanOnly,
    [string]$Interpreter = 'pwsh.exe',
    [string]$PsExecPath = 'psexec.exe',
    [string]$LocalScriptPath = "C:\Admin\Ditzler\PatchManagement\Install-ManualPatches-Local.ps1",
    [string]$OverviewCsv = "C:\Admin\Ditzler\PatchManagement\Server-Kategorien-Uebersicht.csv",
    [string]$OutputCsv = "C:\Admin\Ditzler\PatchManagement\ManualPatchRun-Ergebnis_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [int]$PollIntervalSeconds = 20,
    [int]$MaxWaitMinutes = 90
)

try { Clear-Host } catch { }
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor Cyan
}

# ---------------------------------------------------------
# 1. Zielserver bestimmen
# ---------------------------------------------------------

if ($ServerList -and $ServerList.Count -gt 0) {
    $Targets = $ServerList
    Write-Info "Zielserver explizit angegeben: $($Targets.Count)"
}
elseif ($Category) {
    if (-not (Test-Path -LiteralPath $OverviewCsv)) {
        throw "Uebersicht nicht gefunden: $OverviewCsv - zuerst Build-ServerPatchCategoryPlan.ps1 ausfuehren."
    }
    $Overview = Import-Csv -LiteralPath $OverviewCsv
    $Targets = $Overview | Where-Object { $_.Kategorie -eq $Category } | Select-Object -ExpandProperty Name
    if ($Targets.Count -eq 0) {
        throw "Keine Server mit Kategorie '$Category' in $OverviewCsv gefunden."
    }
    Write-Info "Zielserver aus Kategorie '$Category': $($Targets.Count)"
}
else {
    throw "Bitte -Category oder -ServerList angeben."
}
$Targets | ForEach-Object { Write-Host "  - $_" }

# ---------------------------------------------------------
# 2. Voraussetzungen pruefen
# ---------------------------------------------------------

$PsExecCmd = Get-Command $PsExecPath -ErrorAction SilentlyContinue
if (-not $PsExecCmd) { throw "PsExec nicht gefunden ($PsExecPath) - Pfad pruefen oder -PsExecPath angeben." }

if (-not (Test-Path -LiteralPath $LocalScriptPath)) { throw "Install-Skript nicht gefunden: $LocalScriptPath" }
$ScriptContent = Get-Content -LiteralPath $LocalScriptPath -Raw

$RunId = Get-Date -Format 'yyyyMMdd_HHmmss'
Write-Info "RunId fuer diesen Lauf: $RunId"

# ---------------------------------------------------------
# 3. Pro Server auesloesen (PsExec -d = nicht blockierend)
# ---------------------------------------------------------

$ParamArgs = "-StateId $RunId -MaxRounds $MaxRounds -MaxReboots $MaxReboots -Interpreter `"$Interpreter`""
if ($RescanOnly) { $ParamArgs += " -RescanOnly" }

$Launched = @{}

foreach ($server in $Targets) {
    Write-Info "Starte auf $server ..."

    $WrapperCommand = "& {`n$ScriptContent`n} $ParamArgs"
    $Bytes = [System.Text.Encoding]::Unicode.GetBytes($WrapperCommand)
    $EncodedCommand = [Convert]::ToBase64String($Bytes)

    if ($EncodedCommand.Length -gt 24000) {
        Write-Host "  [WARN] EncodedCommand ist $($EncodedCommand.Length) Zeichen lang - Risiko einer Kommandozeilen-Laengenbegrenzung." -ForegroundColor Yellow
    }

    $PsExecArgs = @(
        "\\$server", "-d", "-accepteula", "-nobanner",
        $Interpreter, "-NoProfile", "-NonInteractive",
        "-EncodedCommand", $EncodedCommand
    )

    $Output = & $PsExecCmd.Source @PsExecArgs 2>&1
    $ExitCode = $LASTEXITCODE
    Write-Host "  PsExec ExitCode=$ExitCode"
    if ($ExitCode -ne 0) {
        Write-Host "  --- PsExec Ausgabe ---"
        Write-Host ($Output -join "`n")
    }
    $Launched[$server] = $true
}

# ---------------------------------------------------------
# 4. Fortschritt per Remote-State-Datei abfragen
# ---------------------------------------------------------

Write-Host ""
Write-Info "Warte auf Abschluss (Poll alle $PollIntervalSeconds s, max. $MaxWaitMinutes min)..."

$PendingServers = [System.Collections.Generic.List[string]]::new()
$Targets | ForEach-Object { $PendingServers.Add($_) }

$AllResults = [System.Collections.Generic.List[object]]::new()
$LastStatus = @{}
$PollStart = Get-Date

while ($PendingServers.Count -gt 0 -and ((Get-Date) - $PollStart) -lt (New-TimeSpan -Minutes $MaxWaitMinutes)) {
    foreach ($server in @($PendingServers)) {
        $RemoteStatePath = "\\$server\C$\ProgramData\Superops\Scripts\_ManualPatchRun\$RunId\state.json"
        if (-not (Test-Path -LiteralPath $RemoteStatePath -ErrorAction SilentlyContinue)) { continue }

        try {
            $State = Get-Content -LiteralPath $RemoteStatePath -Raw -ErrorAction Stop | ConvertFrom-Json
        }
        catch { continue }

        if ($LastStatus[$server] -ne $State.Status) {
            Write-Info "$server -> $($State.Status)  (Runden=$($State.RoundsDone) Reboots=$($State.RebootsDone))"
            $LastStatus[$server] = $State.Status
        }

        if ($State.Status -in @('Completed', 'Failed')) {
            $UpdatesInstalled = 0
            foreach ($r in $State.History) { $UpdatesInstalled += @($r.Installed).Count }

            $AllResults.Add([PSCustomObject]@{
                ServerName            = $State.ServerName
                Status                = $State.Status
                RescanOnly            = $State.RescanOnly
                RoundsDone            = $State.RoundsDone
                RebootsDone           = $State.RebootsDone
                UpdatesInstalledTotal = $UpdatesInstalled
                RemainingUpdates      = $State.RemainingUpdatesCount
                SuperOpsScanOk        = $State.SuperOpsScanTriggered
                SuperOpsScanError     = $State.SuperOpsScanError
                ScriptError           = $State.Error
                EndTime               = $State.EndTime
            })
            $PendingServers.Remove($server) | Out-Null
        }
    }

    if ($PendingServers.Count -gt 0) { Start-Sleep -Seconds $PollIntervalSeconds }
}

foreach ($server in $PendingServers) {
    Write-Host "  [WARN] ${server}: kein Abschluss innerhalb von $MaxWaitMinutes Minuten - manuell pruefen (Server evtl. noch am Rebooten/Installieren)." -ForegroundColor Yellow
    $AllResults.Add([PSCustomObject]@{
        ServerName = $server; Status = 'Timeout-BeimPollen'
    })
}

# ---------------------------------------------------------
# 5. Zusammenfassung
# ---------------------------------------------------------

$AllResults | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
Write-Info "Ergebnis geschrieben: $OutputCsv"

Write-Host ""
Write-Host "=== Zusammenfassung ===" -ForegroundColor Yellow
$AllResults | Format-Table ServerName, Status, RoundsDone, RebootsDone, UpdatesInstalledTotal, RemainingUpdates, SuperOpsScanOk, ScriptError -AutoSize
