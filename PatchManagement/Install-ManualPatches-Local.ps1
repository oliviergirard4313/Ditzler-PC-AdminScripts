#Requires -Version 5.1

# ==========================================================
# INSTALL-MANUALPATCHES-LOCAL.PS1
# Zweck    : Laeuft LOKAL auf dem Zielserver (per PowerShell Remoting/WinRM
#            von Invoke-ManualPatchRun.ps1 dorthin kopiert und per
#            Start-Process losgeloest gestartet - diese Datei existiert nur
#            in diesem Repo, nicht in der SuperOps Script Library).
#
#            1. Installiert bereits ueber WSUS genehmigte/heruntergeladene
#               Updates via UsoClient.exe StartInstall (Update Orchestrator
#               Service) - NICHT per WUA-COM Installer.Install() (in jedem
#               nicht-interaktiven Kontext mit E_ACCESSDENIED blockiert,
#               siehe SuperOps-Patch-Mechanik.md §4.1) und NICHT per DISM
#               direkt (funktioniert nur fuer einfache .cab-Pakete, nicht
#               fuer "Checkpoint"-Cumulative-Updates im .wim-Format, siehe
#               §4.4). UsoClient spricht den echten, bereits funktionierenden
#               Update-Mechanismus des Betriebssystems an und beherrscht
#               alle Paketformate korrekt - validiert 25.08.2026 auf
#               TEST-Update-1 fuer beide Faelle. Nur Suche/Erkennung (WUA
#               COM Search()) bleibt bei der COM-API, die funktioniert
#               ueberall zuverlaessig.
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
#            -WhatIf            : listet die gefundenen Updates pro Runde auf
#                                  (Titel, KB, IsDownloaded), fuehrt aber kein
#                                  Download/Install/Reboot/SuperOps-Scan aus.
#                                  Da WUA einen Reboot-Bedarf erst nach echter
#                                  Installation kennt, bricht der WhatIf-Lauf
#                                  nach der Auflistung der 1. Runde ab (kein
#                                  Redetect, keine weitere Runde).
# ==========================================================

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$StateId,
    [int]$MaxRounds = 2,
    [int]$MaxReboots = 2,
    [int]$RebootDelaySeconds = 90,
    [switch]$RescanOnly,
    [switch]$Resume,
    # powershell.exe statt pwsh.exe - siehe Kommentar bei diesem Parameter
    # in Invoke-ManualPatchRun.ps1 (pwsh.exe fehlt oft auf frischen Servern).
    [string]$Interpreter = 'powershell.exe',
    [int]$InstallPollSeconds = 30,
    [int]$InstallMaxWaitMinutes = 45
)

# ---------------------------------------------------------
# Kompatibilitaet mit SuperOps Script Library "Run Time Variables":
# SuperOps uebergibt sie NICHT als benannte Argumente, sondern setzt sie im
# Aufrufer-Scope, bevor es das Skript per "&" aufruft, z.B.
# "$StateId = 'sotest1'; & '...\Install-ManualPatches-Local.ps1'" (beobachtet
# 25.08.2026, Fehlermeldung des ersten Run-Test-Versuchs). Unser eigener
# param()-Block erzeugt dabei trotzdem eine LEERE lokale Variable und
# ueberschreibt/verdeckt damit die des Aufrufers - deshalb war StateId davor
# "fehlend", obwohl es im Portal gesetzt war. Fix: falls der Parameter beim
# direkten Aufruf (z.B. WinRM, siehe Invoke-ManualPatchRun.ps1) leer blieb,
# gezielt im Aufrufer-Scope (Scope 1) nachschauen. Der WinRM-Pfad ist davon
# nicht betroffen - dort wird $StateId immer als echtes Argument uebergeben.
if ([string]::IsNullOrEmpty($StateId)) {
    # try/catch noetig: Scope 1 existiert nicht bei einem echten Top-Level-
    # Aufruf ohne Aufrufer-Skript (z.B. "& pwsh.exe -File ... -StateId x") -
    # Get-Variable wirft dann "scope number exceeds active scopes", das auch
    # mit -ErrorAction SilentlyContinue sichtbar auf der Konsole auftaucht
    # (Parameterbindung des Scope-Arguments, nicht durch normales
    # Cmdlet-ErrorAction abgefangen) - beobachtet 25.08.2026.
    try { $OuterStateId = Get-Variable -Name StateId -Scope 1 -ErrorAction Stop } catch { $OuterStateId = $null }
    if ($OuterStateId -and $OuterStateId.Value) { $StateId = $OuterStateId.Value }
}
if ([string]::IsNullOrEmpty($StateId)) {
    throw "StateId fehlt - weder als Parameter noch als SuperOps Run Time Variable im Aufrufer-Scope gefunden."
}

# Gleiches Problem fuer -WhatIf: SuperOps kann das automatische
# SupportsShouldProcess-Schalterverhalten nicht ansprechen, da es keine
# "-WhatIf"-Argumente uebergibt. Falls eine Run Time Variable "WhatIf" mit
# Wert "true"/"1" im Aufrufer-Scope liegt, manuell auf $WhatIfPreference
# uebertragen.
if (-not $WhatIfPreference) {
    try { $OuterWhatIf = Get-Variable -Name WhatIf -Scope 1 -ErrorAction Stop } catch { $OuterWhatIf = $null }
    if ($OuterWhatIf -and "$($OuterWhatIf.Value)" -in @('true', '1', 'True')) { $WhatIfPreference = $true }
}

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

$script:StateDirAclFixed = $false

function Initialize-StateDir {
    # Manche ProgramData-Unterordner erben eine ACL mit "BUILTIN\Users Deny
    # AppendData", die selbst Admins/SYSTEM den Zugriff verweigert, sobald
    # eine API (z.B. PS-Remoting-Dateikopie, teils auch .NET-Dateizugriffe)
    # AppendData mitanfordert - ein Deny gewinnt in Windows immer gegen ein
    # Allow FullControl. Erst per Remove-Item+Out-File umgangen, dann per
    # rohem .NET-Dateizugriff (beide beobachtet 25.08.2026, keins davon
    # dauerhaft zuverlaessig). Eigentliche Ursache, warum der erste Versuch
    # eines Wurzel-Fixes hier nichts brachte: $StateDir existiert zu diesem
    # Zeitpunkt meist schon (von Invoke-ManualPatchRun.ps1 per einfachem
    # New-Item angelegt, BEVOR dieses Skript ueberhaupt startet) - ein
    # "nur beim Neuanlegen fixen"-Guard griff deshalb nie. Jetzt: Ordner bei
    # Bedarf anlegen, ACL aber unabhaengig davon einmal pro Prozess fixen.
    if (-not (Test-Path -LiteralPath $StateDir)) {
        New-Item -Path $StateDir -ItemType Directory -Force -WhatIf:$false | Out-Null
    }
    if ($script:StateDirAclFixed) { return }
    try {
        $Acl = Get-Acl -Path $StateDir
        $Acl.SetAccessRuleProtection($true, $false)
        foreach ($Rule in @($Acl.Access)) { $Acl.RemoveAccessRule($Rule) | Out-Null }
        foreach ($Identity in @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
            $Rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $Identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $Acl.AddAccessRule($Rule)
        }
        # -WhatIf:$false zwingend - Set-Acl unterstuetzt ShouldProcess und
        # wuerde sonst unter -WhatIf lautlos uebersprungen (beobachtet
        # 26.08.2026: ACL blieb kaputt, State-Verfolgung blieb ab der ersten
        # Ueberschreibung fuer immer bei "Running" haengen, obwohl das
        # Skript selbst laengst sauber durchgelaufen und beendet war - siehe
        # SuperOps-Patch-Mechanik.md). Analog zu Save-State: das ist unsere
        # eigene Zustandsverfolgung, kein risikoreicher Vorgang.
        Set-Acl -Path $StateDir -AclObject $Acl -WhatIf:$false
        $script:StateDirAclFixed = $true
    }
    catch {
        Write-Warning "Initialize-StateDir: ACL-Reset fehlgeschlagen - $($_.Exception.Message)"
    }
}

function Write-Step {
    # Feingranularer Fortschritts-Marker auf Platte, zusaetzlich zu
    # Save-State (das nur an groben Meilensteinen schreibt). Ziel: falls der
    # Prozess unerwartet stirbt (kein Fehler im try/catch abgefangen -
    # beobachtet 25.08.2026 beim Lauf ueber die SuperOps Script Library,
    # ohne jegliche Fehlerspur in Windows-/Bitdefender-Logs), zeigt diese
    # Datei den letzten erreichten Schritt. -WhatIf:$false wie bei
    # Save-State, aus demselben Grund (ACL-Deny beim Ueberschreiben).
    param([string]$Step)
    try {
        Initialize-StateDir
        $StepFile = Join-Path $StateDir "laststep.txt"
        if (Test-Path -LiteralPath $StepFile) { Remove-Item -LiteralPath $StepFile -Force -WhatIf:$false -ErrorAction SilentlyContinue }
        "$(Get-Date -Format 'HH:mm:ss.fff')  $Step" | Out-File -LiteralPath $StepFile -Encoding UTF8 -WhatIf:$false
    } catch { }
}

function Save-State {
    param($State)
    # -WhatIf:$false erzwingen - das ist unsere eigene Status-Nachverfolgung
    # (fuer das Polling durch Invoke-ManualPatchRun.ps1), nicht die riskante
    # Aktion, die -WhatIf eigentlich verhindern soll. Ohne dies wuerde ein
    # SupportsShouldProcess-Skript jeden ShouldProcess-faehigen Cmdlet-Aufruf
    # (auch diesen) automatisch unterdruecken - state.json wuerde bei -WhatIf
    # nie geschrieben und Invoke-ManualPatchRun.ps1 wuerde ewig auf Abschluss
    # pollen (beobachtet 25.08.2026).
    Initialize-StateDir
    $Json = $State | ConvertTo-Json -Depth 8
    # [System.IO.File]::WriteAllText statt Out-File/Remove-Item+Out-File:
    # manche ProgramData-Ordner erben eine ACL mit "BUILTIN\Users Deny
    # AppendData" - ein Deny gewinnt in Windows immer gegen ein Allow
    # FullControl, auch fuer Admins (meist indirekt Mitglied von Users).
    # Erst per Remove-Item+Out-File umgangen, dann per rohem .NET-Zugriff -
    # beide sind am 25.08.2026 trotzdem noch an derselben ACL gescheitert
    # (der Deny wirkt unabhaengig vom Zugriffsweg). Der eigentliche Fix ist
    # Initialize-StateDir oben, das die Vererbung am Ordner kappt; die
    # Retry-Schleife hier bleibt nur als zusaetzliches Sicherheitsnetz.
    $Attempts = 0
    $LastError = $null
    while ($Attempts -lt 3) {
        try {
            [System.IO.File]::WriteAllText($StateFile, $Json, [System.Text.Encoding]::UTF8)
            return
        }
        catch {
            $LastError = $_
            $Attempts++
            Start-Sleep -Milliseconds 300
        }
    }
    Write-Warning "Save-State: Schreiben von $StateFile nach 3 Versuchen fehlgeschlagen - $($LastError.Exception.Message)"
}

function Remove-ResumeTask {
    $Existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -WhatIf:$false -ErrorAction SilentlyContinue
    }
}

function Register-ResumeTask {
    param([string]$InterpreterPath)

    Initialize-StateDir
    Copy-Item -LiteralPath $PSCommandPath -Destination $SelfCopy -Force

    $ArgList = "-NoProfile -NonInteractive -File `"$SelfCopy`" -StateId $StateId -MaxRounds $MaxRounds -MaxReboots $MaxReboots -RebootDelaySeconds $RebootDelaySeconds -InstallPollSeconds $InstallPollSeconds -InstallMaxWaitMinutes $InstallMaxWaitMinutes -Resume -Interpreter `"$InterpreterPath`""
    if ($RescanOnly) { $ArgList += " -RescanOnly" }

    $Action = New-ScheduledTaskAction -Execute $InterpreterPath -Argument $ArgList
    $Trigger = New-ScheduledTaskTrigger -AtStartup
    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3)

    Remove-ResumeTask
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings -Force | Out-Null
}

function Test-WuaRebootRequired {
    # Microsoft.Update.SystemInfo.RebootRequired waere der direkte WUA-Weg,
    # scheitert aber in diesem Kontext genau wie Downloader.Download() und
    # Installer.Install() mit E_ACCESSDENIED (beobachtet 25.08.2026 im
    # usotest1-Lauf) - dieselbe COM-Zugriffsbeschraenkung, siehe
    # SuperOps-Patch-Mechanik.md. Stattdessen dieselben Registry-Marker
    # abfragen, die CBS/WU/Session Manager selbst setzen und die auch ohne
    # erhoehte COM-Rechte lesbar sind.
    try {
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
        if (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
        $Pfro = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue
        if ($Pfro -and $Pfro.PendingFileRenameOperations) { return $true }
        return $false
    }
    catch {
        Write-Warning "Test-WuaRebootRequired fehlgeschlagen: $($_.Exception.Message)"
        return $false
    }
}

function Get-PendingUpdates {
    Write-Step "Get-PendingUpdates: vor New-Object Microsoft.Update.Session"
    $Session = New-Object -ComObject Microsoft.Update.Session
    Write-Step "Get-PendingUpdates: Session erstellt, vor CreateUpdateSearcher"
    $Searcher = $Session.CreateUpdateSearcher()
    Write-Step "Get-PendingUpdates: Searcher erstellt, vor Search()"
    $SearchResult = $Searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Software'")
    Write-Step "Get-PendingUpdates: Search() zurueckgekehrt"
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

    # Zielliste VOR dem Installationsversuch festhalten (Titel + KB), um
    # nachher zu sehen was tatsaechlich verschwunden (= installiert) ist -
    # UsoClient/der Orchestrator arbeitet global, nicht pro-Update wie
    # frueher die COM-API es zurueckmeldete.
    $TargetKeys = @($Pending | ForEach-Object {
        $kb = if ($_.KBArticleIDs.Count -gt 0) { "KB$($_.KBArticleIDs.Item(0))" } else { $_.Title }
        [PSCustomObject]@{ Title = $_.Title; KB = $kb }
    })
    foreach ($t in $TargetKeys) { Write-Info "  - Ziel: $($t.Title) [$($t.KB)]" }

    if ($WhatIfPreference) {
        Write-Info "[Round $RoundNumber] WhatIf: folgende Update(s) wuerden via UsoClient StartInstall installiert:"
        foreach ($u in $Pending) {
            $kb = if ($u.KBArticleIDs.Count -gt 0) { "KB$($u.KBArticleIDs.Item(0))" } else { '' }
            Write-Info "  - $($u.Title) [$kb] (IsDownloaded=$($u.IsDownloaded))"
        }
        return $RoundResult
    }

    # Download: kein eigener Aufruf noetig - WSUS/AUOptions=3 laedt bereits
    # automatisch im Hintergrund herunter. Nur per DetectNow anstossen
    # (simpler COM-Aufruf ohne Rueckgabewert, anders als Download()/
    # Install() nie blockiert beobachtet).
    Invoke-WuaDetectNow

    # Installation per UsoClient.exe StartInstall - siehe Kommentar am
    # Dateianfang, warum nicht COM Installer.Install() oder DISM direkt.
    # Asynchron: kein Rueckgabewert/Exitcode zur Fortschrittsverfolgung -
    # deshalb per Search()/IsPendingInstallation gepollt, bis entweder alle
    # Ziel-Updates aus der Pending-Liste verschwunden sind, kein Fortschritt
    # mehr erkennbar ist, oder die maximale Wartezeit erreicht ist.
    Write-Info "[Round $RoundNumber] Installiere $($TargetKeys.Count) Update(s) via UsoClient StartInstall..."
    Write-Step "[Round $RoundNumber] vor UsoClient StartInstall"
    & UsoClient.exe StartInstall | Out-Null
    Write-Step "[Round $RoundNumber] UsoClient StartInstall ausgeloest, beginne Polling"

    $PollStart = Get-Date
    $StillPendingKBs = @($TargetKeys.KB)
    $LastRemainingCount = $StillPendingKBs.Count
    $StaleCount = 0

    while ($true) {
        Start-Sleep -Seconds $InstallPollSeconds
        $ElapsedSeconds = [int]((Get-Date) - $PollStart).TotalSeconds

        $CurrentPending = Get-PendingUpdates
        $CurrentByKB = @{}
        foreach ($u in $CurrentPending) {
            $kb = if ($u.KBArticleIDs.Count -gt 0) { "KB$($u.KBArticleIDs.Item(0))" } else { $u.Title }
            $CurrentByKB[$kb] = $u
        }

        $StillPendingKBs = @($TargetKeys.KB | Where-Object { $CurrentByKB.ContainsKey($_) })
        $ActivelyInstalling = @($StillPendingKBs | Where-Object { $CurrentByKB[$_].IsPendingInstallation })

        Write-Step "[Round $RoundNumber] Poll nach ${ElapsedSeconds}s: $($StillPendingKBs.Count) Ziel-Update(s) noch offen, $($ActivelyInstalling.Count) davon aktiv (IsPendingInstallation)"
        Write-Info "[Round $RoundNumber] Poll nach ${ElapsedSeconds}s: $($StillPendingKBs.Count)/$($TargetKeys.Count) noch offen, $($ActivelyInstalling.Count) aktiv installierend"

        if ($StillPendingKBs.Count -eq 0) {
            Write-Info "[Round $RoundNumber] Alle Ziel-Update(s) nicht mehr ausstehend - Installation abgeschlossen."
            break
        }

        if ($StillPendingKBs.Count -eq $LastRemainingCount -and $ActivelyInstalling.Count -eq 0) {
            $StaleCount++
        }
        else {
            $StaleCount = 0
        }
        $LastRemainingCount = $StillPendingKBs.Count

        if ($StaleCount -ge 3) {
            Write-Info "[Round $RoundNumber] Kein Fortschritt seit $($StaleCount * $InstallPollSeconds)s und nichts aktiv (IsPendingInstallation) - Warten abgebrochen."
            break
        }

        if ($ElapsedSeconds -ge ($InstallMaxWaitMinutes * 60)) {
            Write-Info "[Round $RoundNumber] Maximale Wartezeit ($InstallMaxWaitMinutes min) erreicht - Warten abgebrochen."
            break
        }
    }

    $InstalledList = @()
    foreach ($t in $TargetKeys) {
        $status = if ($t.KB -notin $StillPendingKBs) { 'Installiert' } else { 'NochAusstehend' }
        $InstalledList += [ordered]@{ Title = $t.Title; KB = $t.KB; ResultCode = $status }
        Write-Info "  - $($t.Title) [$($t.KB)] -> $status"
    }
    $RoundResult.Installed = $InstalledList
    $RoundResult.RebootRequired = Test-WuaRebootRequired
    Write-Step "[Round $RoundNumber] Runde beendet: RebootRequired=$($RoundResult.RebootRequired)"

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
            # Select-Object -Last 1 noetig: Invoke-InstallRound ruft intern
            # Write-Info auf, dessen Output sonst den Rueckgabewert der
            # Funktion verunreinigt (History wuerde dann Log-Zeilen als
            # String-Elemente enthalten statt nur das Round-Objekt - das
            # verfaelscht die "UpdatesInstalledTotal"-Zaehlung im
            # Orchestrator, beobachtet 25.08.2026: 8 statt 0 bei -WhatIf).
            $RoundResult = Invoke-InstallRound -RoundNumber $RoundsDone | Select-Object -Last 1
            $History += $RoundResult

            Save-State ([ordered]@{
                ServerName = $ServerName; StateId = $StateId; RoundsDone = $RoundsDone; RebootsDone = $RebootsDone
                MaxRounds = $MaxRounds; MaxReboots = $MaxReboots; Status = 'Running'; History = $History
                StartTime = (Get-Date).ToString('o')
            })

            if ($RoundResult.Found -eq 0) { break }

            if ($WhatIfPreference) {
                Write-Info "[Round $RoundsDone] WhatIf: kein Redetect/weitere Runde - Abbruch nach Auflistung."
                break
            }

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
    # -Resume Modus weiter (via Scheduled Task). Expliziter exit 0 (statt
    # nur return) aus demselben Grund wie am eigentlichen Skriptende -
    # ein sauberer Exitcode fuer den Aufrufer (SuperOps o.ae.), das ist
    # hier kein Fehler, sondern eine kontrollierte Unterbrechung.
    Write-Info "Neustart eingeleitet. Skript wird nach Neustart automatisch fortgesetzt."
    exit 0
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

    # Der Ordnername des SuperOps-Agenten unter "Program Files" ist nicht
    # einheitlich - "meineitrmm" auf manchen Servern, "superopsrmm" auf
    # anderen (vermutlich je nach Alter/Branding der Agent-Installation,
    # beobachtet 27.08.2026 auf SV-OS-MGT-01). Deshalb dynamisch per
    # Wildcard suchen statt einen einzigen Ordnernamen fest zu verdrahten.
    # "...\patch\<Version>\backup|extracted\bin\osupdater.exe" (Reste einer
    # Agent-Selbstaktualisierung) bewusst ausgeschlossen - nur die direkte
    # "<AgentOrdner>\bin\osupdater.exe" ist die aktive Installation.
    $OsUpdaterPath = Get-ChildItem -Path 'C:\Program Files\*\bin\osupdater.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($WhatIfPreference) {
        Write-Info "WhatIf: SuperOps Patch-Scan (osupdater.exe -patchAction patchScan) wuerde hier ausgeloest."
    }
    elseif ($OsUpdaterPath) {
        Write-Info "Loese SuperOps Patch-Scan aus ($OsUpdaterPath -patchAction patchScan)..."
        & $OsUpdaterPath -patchAction patchScan | Out-Null
        $SuperOpsScanTriggered = $true
    }
    else {
        $SuperOpsScanError = "osupdater.exe nicht gefunden unter C:\Program Files\*\bin\osupdater.exe"
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
    WhatIf                 = [bool]$WhatIfPreference
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

# Aufraeumen: Task + temporaere Skriptkopien entfernen, State-Datei bleibt
# als letzter Statusnachweis liegen (klein, lesbar per UNC-Pfad).
Remove-ResumeTask
if (Test-Path -LiteralPath $SelfCopy) { Remove-Item -LiteralPath $SelfCopy -Force -WhatIf:$false -ErrorAction SilentlyContinue }
# Initiale Kopie, die Invoke-ManualPatchRun.ps1 per WinRM/Invoke-Command
# angelegt hat (siehe dessen Abschnitt 3).
$InitialCopy = Join-Path $StateDir "install.ps1"
if (Test-Path -LiteralPath $InitialCopy) { Remove-Item -LiteralPath $InitialCopy -Force -WhatIf:$false -ErrorAction SilentlyContinue }

Write-Info "Fertig. Status=$($FinalState.Status)  Runden=$RoundsDone  Reboots=$RebootsDone  Verbleibend=$RemainingCount  SuperOpsScan=$SuperOpsScanTriggered"

Write-Output "RESULT_JSON_START"
$FinalState | ConvertTo-Json -Depth 8 -Compress
Write-Output "RESULT_JSON_END"

# Explizites Exit noetig, damit z.B. SuperOps (das ueber runScriptOnAsset
# den Skript-Exitcode auswertet) sauber Success/Failed erkennt, statt nur
# vom natuerlichen Skriptende auszugehen (beobachtet 25.08.2026 - Executed
# Scripts blieb auch bei erfolgreichem Lauf auf "In Progress" stehen).
if ($FinalState.Status -eq 'Failed') { exit 1 } else { exit 0 }
