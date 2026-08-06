#Requires -Version 5.1

# ==========================================================
# INSTALL-MANUALPATCHES-LOCAL.PS1
# Zweck    : Laeuft LOKAL auf dem Zielserver (per PsExec im Speicher
#            ausgefuehrt - diese Datei existiert nur in diesem Repo,
#            nicht in der SuperOps Script Library).
#
#            1. Installiert bereits ueber WSUS genehmigte/heruntergeladene
#               Updates via Windows Update Agent (WUA) COM-API.
#            2. Reboot noetig? -> automatischer Neustart. Der Zustand wird
#               vorher auf Platte persistiert (State-Datei) und eine
#               einmalige Scheduled Task "AtStartup" registriert, die
#               dieses Skript nach dem Neustart im -Resume Modus
#               fortsetzt. Die Task loescht sich selbst als erste
#               Aktion beim naechsten Lauf - sie feuert also nur einmal.
#            3. Nach dem Neustart: automatische Redetect + ggf. weitere
#               Installationsrunde(n), bis MaxRounds oder MaxReboots
#               erreicht ist oder keine Updates mehr ausstehen.
#            4. Am Ende: lokale WUA-Neuerkennung (Reliquate pruefen) +
#               SuperOps-Patch-Scan (osupdater.exe -patchAction
#               patchScan), damit das Portal sofort den aktuellen Stand
#               zeigt. Zustandsordner + temporaere Kopie dieses Skripts
#               werden aufgeraeumt (nichts bleibt dauerhaft liegen).
#
#            Da ein Reboot den Prozessspeicher loescht, MUSS fuer die
#            automatische Fortsetzung eine kleine Kopie dieses Skripts
#            und eine Scheduled Task temporaer auf dem Zielserver liegen
#            (unvermeidbar bei einem echten Neustart-Zyklus) - beides
#            wird am Ende des gesamten Laufs automatisch entfernt.
#
# Aufruf   : & { <Inhalt dieser Datei> } -StateId <id> -MaxRounds 2 -MaxReboots 2
#            -Resume            : interner Modus, von der Scheduled Task
#                                  nach dem Neustart verwendet.
#            -RescanOnly        : nur Reliquate pruefen + SuperOps-Scan,
#                                  keine Installation.
# ==========================================================

param(
    [Parameter(Mandatory = $true)]
    [string]$StateId,
    [int]$MaxRounds = 2,
    [int]$MaxReboots = 2,
    [int]$RebootDelaySeconds = 90,
    [switch]$RescanOnly,
    [switch]$Resume,
    [string]$Interpreter = 'pwsh.exe'
)

$ErrorActionPreference = 'Stop'
$ServerName = $env:COMPUTERNAME

$StateRoot = "C:\ProgramData\Superops\Scripts\_ManualPatchRun"
$StateDir  = Join-Path $StateRoot $StateId
$StateFile = Join-Path $StateDir "state.json"
$SelfCopy  = Join-Path $StateDir "resume.ps1"
$TaskName  = "DitzlerManualPatchResume_$StateId"

function Write-Info {
    param([string]$Message)
    Write-Output "[$(Get-Date -Format 'HH:mm:ss')] $Message"
}

function Save-State {
    param($State)
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -Path $StateDir -ItemType Directory -Force | Out-Null }
    $State | ConvertTo-Json -Depth 8 | Out-File -LiteralPath $StateFile -Encoding UTF8
}

function Remove-ResumeTask {
    $Existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Register-ResumeTask {
    param([string]$InterpreterPath)

    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -Path $StateDir -ItemType Directory -Force | Out-Null }
    Copy-Item -LiteralPath $PSCommandPath -Destination $SelfCopy -Force

    $ArgList = "-NoProfile -NonInteractive -File `"$SelfCopy`" -StateId $StateId -MaxRounds $MaxRounds -MaxReboots $MaxReboots -RebootDelaySeconds $RebootDelaySeconds -Resume -Interpreter `"$InterpreterPath`""
    if ($RescanOnly) { $ArgList += " -RescanOnly" }

    $Action = New-ScheduledTaskAction -Execute $InterpreterPath -Argument $ArgList
    $Trigger = New-ScheduledTaskTrigger -AtStartup
    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3)

    Remove-ResumeTask
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
}

function Get-PendingUpdates {
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    $SearchResult = $Searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    return $SearchResult.Updates
}

function Invoke-WuaDetectNow {
    try {
        $AutoUpdate = New-Object -ComObject Microsoft.Update.AutoUpdate
        $AutoUpdate.DetectNow()
    }
    catch {
        Write-Warning "DetectNow fehlgeschlagen: $($_.Exception.Message)"
    }
}

function Invoke-InstallRound {
    param([int]$RoundNumber)

    Write-Info "[Round $RoundNumber] Suche nach ausstehenden Updates..."
    $Pending = Get-PendingUpdates

    $RoundResult = [ordered]@{ Round = $RoundNumber; Found = $Pending.Count; Installed = @(); RebootRequired = $false }

    if ($Pending.Count -eq 0) {
        Write-Info "[Round $RoundNumber] Keine ausstehenden Updates gefunden."
        return $RoundResult
    }
    Write-Info "[Round $RoundNumber] $($Pending.Count) Update(s) gefunden."

    # Download falls noetig - sollte via WSUS/GPO (AUOptions=3) bereits
    # lokal vorliegen, hier nur als Sicherheitsnetz.
    $ToDownload = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $Pending) {
        if (-not $u.IsDownloaded) { $ToDownload.Add($u) | Out-Null }
    }
    if ($ToDownload.Count -gt 0) {
        Write-Info "[Round $RoundNumber] Lade $($ToDownload.Count) Update(s) herunter..."
        $Downloader = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateDownloader()
        $Downloader.Updates = $ToDownload
        $Downloader.Download() | Out-Null
    }

    $ToInstall = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $Pending) {
        if ($u.IsDownloaded) { $ToInstall.Add($u) | Out-Null }
    }

    if ($ToInstall.Count -gt 0) {
        Write-Info "[Round $RoundNumber] Installiere $($ToInstall.Count) Update(s)..."
        $Installer = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateInstaller()
        $Installer.Updates = $ToInstall
        $InstallResult = $Installer.Install()

        $InstalledList = @()
        for ($i = 0; $i -lt $ToInstall.Count; $i++) {
            $u = $ToInstall.Item($i)
            $r = $InstallResult.GetUpdateResult($i)
            $kb = if ($u.KBArticleIDs.Count -gt 0) { "KB$($u.KBArticleIDs.Item(0))" } else { '' }
            $InstalledList += [ordered]@{ Title = $u.Title; KB = $kb; ResultCode = $r.ResultCode }
            Write-Info "  - $($u.Title) [$kb] -> ResultCode=$($r.ResultCode)"
        }
        $RoundResult.Installed = $InstalledList
        $RoundResult.RebootRequired = [bool]$InstallResult.RebootRequired
    }

    return $RoundResult
}

# ---------------------------------------------------------
# Zustand laden oder neu anlegen
# ---------------------------------------------------------

if ($Resume -and (Test-Path -LiteralPath $StateFile)) {
    Write-Info "Fortsetzung nach Neustart (StateId=$StateId)."
    # Task sofort entfernen - soll nur einmal feuern.
    Remove-ResumeTask
    $State = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    $RoundsDone = [int]$State.RoundsDone
    $RebootsDone = [int]$State.RebootsDone
    $History = @($State.History)
}
else {
    Write-Info "Neuer Lauf (StateId=$StateId)."
    $RoundsDone = 0
    $RebootsDone = 0
    $History = @()
    Save-State ([ordered]@{
        ServerName = $ServerName; StateId = $StateId; RoundsDone = 0; RebootsDone = 0
        MaxRounds = $MaxRounds; MaxReboots = $MaxReboots; Status = 'Running'; History = @()
        StartTime = (Get-Date).ToString('o')
    })
}

$FinalError = $null
$RebootTriggered = $false

try {
    if (-not $RescanOnly) {
        while ($RoundsDone -lt $MaxRounds) {
            $RoundsDone++
            $RoundResult = Invoke-InstallRound -RoundNumber $RoundsDone
            $History += $RoundResult

            Save-State ([ordered]@{
                ServerName = $ServerName; StateId = $StateId; RoundsDone = $RoundsDone; RebootsDone = $RebootsDone
                MaxRounds = $MaxRounds; MaxReboots = $MaxReboots; Status = 'Running'; History = $History
                StartTime = (Get-Date).ToString('o')
            })

            if ($RoundResult.Found -eq 0) { break }

            if ($RoundResult.RebootRequired) {
                if ($RebootsDone -lt $MaxReboots) {
                    $RebootsDone++
                    $InterpreterPath = (Get-Command $Interpreter -ErrorAction SilentlyContinue).Source
                    if (-not $InterpreterPath) { $InterpreterPath = (Get-Command 'powershell.exe').Source }

                    Save-State ([ordered]@{
                        ServerName = $ServerName; StateId = $StateId; RoundsDone = $RoundsDone; RebootsDone = $RebootsDone
                        MaxRounds = $MaxRounds; MaxReboots = $MaxReboots; Status = 'WaitingReboot'; History = $History
                        StartTime = (Get-Date).ToString('o')
                    })

                    Write-Info "Reboot noetig. Registriere Fortsetzungs-Task und starte Neustart in $RebootDelaySeconds Sekunden..."
                    Register-ResumeTask -InterpreterPath $InterpreterPath
                    & shutdown.exe /r /t $RebootDelaySeconds /c "Ditzler Manual Patch Run - automatischer Neustart, Fortsetzung nach Reboot" /f
                    $RebootTriggered = $true
                    break
                }
                else {
                    Write-Info "MaxReboots ($MaxReboots) erreicht - kein weiterer automatischer Neustart."
                    break
                }
            }

            if ($RoundsDone -lt $MaxRounds) {
                Write-Info "[Round $RoundsDone] Redetect fuer eventuelle Folge-Updates..."
                Invoke-WuaDetectNow
                Start-Sleep -Seconds 30
            }
        }
    }
}
catch {
    $FinalError = $_.Exception.Message
}

if ($RebootTriggered) {
    # Skript endet hier bewusst - der Rest laeuft nach dem Neustart im
    # -Resume Modus weiter (via Scheduled Task).
    Write-Info "Neustart eingeleitet. Skript wird nach Neustart automatisch fortgesetzt."
    return
}

# ---------------------------------------------------------
# Abschluss: Reliquate pruefen, SuperOps-Scan, aufraeumen
# ---------------------------------------------------------

$RemainingCount = 0
$SuperOpsScanTriggered = $false
$SuperOpsScanError = $null

try {
    Write-Info "Pruefe verbleibende Updates (Reliquate)..."
    $Remaining = Get-PendingUpdates
    $RemainingCount = $Remaining.Count
    if ($RemainingCount -gt 0) {
        Write-Info "$RemainingCount Update(s) bleiben ausstehend (evtl. noch nicht in WSUS genehmigt, oder MaxRounds/MaxReboots erreicht)."
    }

    Write-Info "Erzwinge lokale WUA-Neuerkennung..."
    Invoke-WuaDetectNow

    $OsUpdaterPath = "C:\Program Files\meineitrmm\bin\osupdater.exe"
    if (Test-Path -LiteralPath $OsUpdaterPath) {
        Write-Info "Loese SuperOps Patch-Scan aus (osupdater.exe -patchAction patchScan)..."
        & $OsUpdaterPath -patchAction patchScan | Out-Null
        $SuperOpsScanTriggered = $true
    }
    else {
        $SuperOpsScanError = "osupdater.exe nicht gefunden unter $OsUpdaterPath"
    }
}
catch {
    if (-not $FinalError) { $FinalError = $_.Exception.Message }
    $SuperOpsScanError = $_.Exception.Message
}

$FinalState = [ordered]@{
    ServerName             = $ServerName
    StateId                = $StateId
    RescanOnly             = [bool]$RescanOnly
    RoundsDone             = $RoundsDone
    RebootsDone            = $RebootsDone
    History                = $History
    RemainingUpdatesCount  = $RemainingCount
    SuperOpsScanTriggered  = $SuperOpsScanTriggered
    SuperOpsScanError      = $SuperOpsScanError
    Error                  = $FinalError
    Status                 = if ($FinalError) { 'Failed' } else { 'Completed' }
    EndTime                = (Get-Date).ToString('o')
}
Save-State $FinalState

# Aufraeumen: Task + temporaere Skriptkopie entfernen, State-Datei bleibt
# als letzter Statusnachweis liegen (klein, lesbar per UNC-Pfad).
Remove-ResumeTask
if (Test-Path -LiteralPath $SelfCopy) { Remove-Item -LiteralPath $SelfCopy -Force -ErrorAction SilentlyContinue }

Write-Info "Fertig. Status=$($FinalState.Status)  Runden=$RoundsDone  Reboots=$RebootsDone  Verbleibend=$RemainingCount  SuperOpsScan=$SuperOpsScanTriggered"

Write-Output "RESULT_JSON_START"
$FinalState | ConvertTo-Json -Depth 8 -Compress
Write-Output "RESULT_JSON_END"
