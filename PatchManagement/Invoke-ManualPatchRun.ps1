#Requires -Version 5.1

# ==========================================================
# INVOKE-MANUALPATCHRUN.PS1
# Zweck    : Orchestriert einen manuellen Patch-Lauf fuer eine Gruppe von
#            Servern, per PowerShell Remoting (WinRM) - NICHT per PsExec/SMB.
#
#            Historie (25.08.2026): urspruenglich per PsExec + SMB/C$
#            umgesetzt. Erster echter Test auf TEST-Update-1 zeigte zwei
#            Blocker der Reihe nach:
#            1. PsExec braucht Domaenen-Vertrauen (oder lokale Admin-Creds)
#               zwischen der Skript-Maschine und dem Zielserver - geloest
#               durch Domain-Join von TEST-Update-1.
#            2. Danach "The network path was not found" beim SMB-Zugriff
#               (\\server\C$\...) - CIFS/SMB (Port 445) ist zwischen den
#               Servern nicht erlaubt (Zielserver liegt in der OU
#               "10_LAPS-Managed-Servers" - LAPS + WinRM/Kerberos ohne SMB-
#               Lateralverkehr ist genau das erwartete Haertungsmuster).
#            WinRM (Port 5985/5986) ist der tatsaechlich erlaubte Kanal:
#            Invoke-Command schreibt das Install-Skript auf den Zielserver
#            und startet es dort per Start-Process losgeloest (Ersatz fuer
#            PsExec -d), der Fortschritt wird ebenfalls per Invoke-Command
#            (state.json lokal auf dem Ziel lesen) abgefragt - kein SMB/C$
#            mehr noetig, weder fuer den Push noch fuer das Polling.
#
#            Die Kopie auf dem Zielserver loescht sich selbst am Ende
#            (gleiches Muster wie die resume.ps1-Kopie fuer die Reboot-
#            Fortsetzung, siehe Kommentar in Install-ManualPatches-Local.ps1)
#            - sie existiert als Quelle ausschliesslich in diesem Repo.
#
#            Reboot-Handling: Install-ManualPatches-Local.ps1 registriert
#            bei Bedarf selbst eine lokale Scheduled Task (SYSTEM) auf dem
#            Zielserver, die nach dem Neustart automatisch fortsetzt - das
#            ist unabhaengig davon, wie der Lauf urspruenglich gestartet
#            wurde (WinRM-Sitzung ueberlebt den Reboot ohnehin nicht, muss
#            sie auch nicht).
#
# Voraussetzung: WinRM auf den Zielservern aktiviert und erreichbar
#                (Test-WSMan), aktueller Benutzer hat Admin-Rechte auf dem
#                Zielserver (Kerberos, gleiches Rechtemodell wie vorher mit
#                PsExec).
#
#                WICHTIG: Dieses Skript NIEMALS aus einer "psexec -i -s"
#                (SYSTEM-)PowerShell heraus starten - normale PowerShell
#                als Admin-Benutzer (z.B. adm_gio) verwenden. Unter SYSTEM
#                schlaegt Invoke-Command mit "Access is denied" fehl (WinRM-
#                Log: "authorization of the user failed with error 5") -
#                klassisches Double-Hop/Delegation-Problem: SYSTEM kann ein
#                fremdes Kerberos-Ticket nicht fuer eine volle WinRM-Session
#                mit allen Gruppen-SIDs verwenden, obwohl Test-WSMan/klist
#                taeuschend danach aussehen als wuerde es funktionieren
#                (beobachtet 25.08.2026). "psexec -i -s" ist nur fuer
#                Skripte noetig, die credentials.xml entschluesseln (SuperOps
#                API) - dieses Skript tut das nicht.
#
# Beispiel :
#   .\Invoke-ManualPatchRun.ps1 -Category "SV_SW-Std_Manual-Update-Group-2"
#   .\Invoke-ManualPatchRun.ps1 -ServerList SV-OS-PWR-01 -RescanOnly
#   .\Invoke-ManualPatchRun.ps1 -ServerList TEST-Update-1 -WhatIf
#       -> -WhatIf wird 1:1 an Install-ManualPatches-Local.ps1 auf jedem
#          Zielserver durchgereicht: der Lauf wird wie gewohnt gestartet,
#          aber es wird nichts heruntergeladen/installiert/rebootet - nur
#          die gefundenen Updates werden pro Server geloggt (state.json).
# ==========================================================

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Category,
    [string[]]$ServerList,
    [int]$MaxRounds = 2,
    [int]$MaxReboots = 2,
    [switch]$RescanOnly,
    # powershell.exe (Windows PowerShell 5.1) statt pwsh.exe (PowerShell 7) -
    # ist auf jedem Windows Server standardmaessig vorhanden, waehrend
    # pwsh.exe oft erst per Windows Update installiert wird (also gerade auf
    # frisch aufgesetzten/noch nie gepatchten Servern fehlt - beobachtet
    # 26.08.2026 auf TEST-Update-1/2/3, Start scheiterte lautlos ohne
    # jegliche state.json). Install-ManualPatches-Local.ps1 ist bewusst
    # #Requires -Version 5.1, keine PS7-spezifische Syntax verwendet.
    [string]$Interpreter = 'powershell.exe',
    [string]$LocalScriptPath = "C:\Admin\Ditzler\PatchManagement\Install-ManualPatches-Local.ps1",
    [string]$OverviewCsv = "C:\Admin\Ditzler\PatchManagement\Server-Kategorien-Uebersicht.csv",
    [string]$OutputCsv = "C:\Admin\Ditzler\PatchManagement\ManualPatchRun-Ergebnis_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [int]$PollIntervalSeconds = 20,
    # 180 statt frueher 90: die Installation selbst laeuft jetzt per
    # UsoClient (asynchron, intern gepollt bis zu $InstallMaxWaitMinutes
    # pro Runde) statt der fruehen COM-API, die synchron sofort
    # zurueckkehrte oder scheiterte - ein Lauf mit 2 Runden a 45 min kann
    # legitim ueber eine Stunde dauern, siehe SuperOps-Patch-Mechanik.md §4.4/§6b.
    [int]$MaxWaitMinutes = 180,
    [int]$InstallPollSeconds = 30,
    [int]$InstallMaxWaitMinutes = 45
)

try { Clear-Host } catch { }
$ErrorActionPreference = 'Stop'

# CimCmdlets vorab laden - New-PSSession loest sonst beim ersten Aufruf ein
# implizites Modul-Import aus, dessen interne Set-Alias-Aufrufe unter
# -WhatIf sichtbar (und wirkungslos) im Log auftauchen. Rein kosmetisch,
# aber verwirrend - hier einmalig sauber vorgeladen statt spaeter
# unterdrueckt. WICHTIG: kein "-WhatIf:$false" hier - Import-Module hat
# gar keinen -WhatIf Parameter, das wuerde selbst mit
# "A parameter cannot be found that matches parameter name 'WhatIf'"
# abbrechen (beobachtet 25.08.2026 - wurde faelschlich dem Skript selbst
# zugeschrieben, war aber dieser Aufruf hier).
Import-Module CimCmdlets -ErrorAction SilentlyContinue

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

if (-not (Test-Path -LiteralPath $LocalScriptPath)) { throw "Install-Skript nicht gefunden: $LocalScriptPath" }
$ScriptContent = Get-Content -LiteralPath $LocalScriptPath -Raw

$RunId = Get-Date -Format 'yyyyMMdd_HHmmss'
Write-Info "RunId fuer diesen Lauf: $RunId"

$ScriptArgs = @('-StateId', $RunId, '-MaxRounds', $MaxRounds, '-MaxReboots', $MaxReboots, '-Interpreter', $Interpreter, '-InstallPollSeconds', $InstallPollSeconds, '-InstallMaxWaitMinutes', $InstallMaxWaitMinutes)
if ($RescanOnly) { $ScriptArgs += '-RescanOnly' }
if ($WhatIfPreference) {
    $ScriptArgs += '-WhatIf'
    Write-Host "=== WHATIF: kein Download/Install/Reboot/SuperOps-Scan auf den Zielservern ===" -ForegroundColor Yellow
}

# ---------------------------------------------------------
# 3. Pro Server pruefen (WinRM) und ausloesen
# ---------------------------------------------------------
# WICHTIG (gefunden 25.08.2026): Start-Process/Win32_Process.Create/eine
# Scheduled Task, die den Lauf startet, fuehren alle zum selben Fehler -
# das Zielskript stirbt mit Exitcode 0x80070005 (E_ACCESSDENIED), sobald es
# die WUA-COM-API (Microsoft.Update.Session) aufruft. Ursache: WUA verweigert
# den Zugriff aus einem komplett losgeloesten Prozess (kein Fenster-Handle/
# keine Window Station) - unabhaengig vom verwendeten Konto (getestet mit
# SYSTEM und mit einem Domain-Admin via S4U, gleicher Fehler). Funktioniert
# hat nur ein Lauf INNERHALB einer offenen PSSession (per Invoke-Command
# -AsJob) - das ist naeher am erfolgreichen manuellen Test (synchron in der
# WinRM-Sitzung) als ein wirklich verwaister Prozess. Deshalb: PSSession pro
# Server offen halten (in $Sessions), Skript per Hintergrund-Job darin
# starten, Sessions erst am Ende (Abschnitt 5) schliessen.
#
# Reboot-Hinweis: das faellt nicht auseinander, wenn ein Zielserver
# neustartet - dafuer existiert bereits der eigene Fortsetzungs-Mechanismus
# in Install-ManualPatches-Local.ps1 (lokale Scheduled Task AtStartup, siehe
# Kommentar dort). ABER: diese Fortsetzungs-Task ist selbst eine Scheduled
# Task, also potenziell vom selben WUA-Zugriffsproblem betroffen - das ist
# NICHT getestet (nur per -WhatIf getestet, was nie neustartet). Vor einem
# echten Lauf mit Reboot-Bedarf auf Produktivservern: erst an einem
# Testserver mit echtem Reboot verifizieren.

$RemoteScriptPath = "C:\ProgramData\Superops\Scripts\_ManualPatchRun\$RunId\install.ps1"
$LaunchFailures   = [System.Collections.Generic.List[object]]::new()
$PendingServers   = [System.Collections.Generic.List[string]]::new()
$Sessions         = @{}

foreach ($server in $Targets) {
    Write-Info "Pruefe WinRM-Erreichbarkeit von $server ..."
    try {
        Test-WSMan -ComputerName $server -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "  [FEHLER] WinRM auf $server nicht erreichbar: $($_.Exception.Message)" -ForegroundColor Red
        $LaunchFailures.Add([PSCustomObject]@{ ServerName = $server; Status = 'WinRM-NichtErreichbar'; ScriptError = $_.Exception.Message })
        continue
    }

    Write-Info "Starte auf $server ..."
    try {
        $Session = New-PSSession -ComputerName $server -ErrorAction Stop

        Invoke-Command -Session $Session -ErrorAction Stop -ScriptBlock {
            param($Path, $Content)
            $Dir = Split-Path -Path $Path -Parent
            if (-not (Test-Path -LiteralPath $Dir)) { New-Item -Path $Dir -ItemType Directory -Force | Out-Null }
            Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
        } -ArgumentList $RemoteScriptPath, $ScriptContent

        Invoke-Command -Session $Session -ErrorAction Stop -AsJob -ScriptBlock {
            param($Exe, $ScriptPath, $Arguments)
            & $Exe -NoProfile -NonInteractive -File $ScriptPath @Arguments 2>&1
        } -ArgumentList $Interpreter, $RemoteScriptPath, $ScriptArgs | Out-Null

        $Sessions[$server] = $Session
        $PendingServers.Add($server)
    }
    catch {
        Write-Host "  [FEHLER] Start auf $server fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
        $LaunchFailures.Add([PSCustomObject]@{ ServerName = $server; Status = 'StartFehlgeschlagen'; ScriptError = $_.Exception.Message })
        if ($Session) { Remove-PSSession -Session $Session -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------
# 4. Fortschritt per WinRM abfragen (state.json lokal auf dem Zielserver)
# ---------------------------------------------------------

Write-Host ""
Write-Info "Warte auf Abschluss von $($PendingServers.Count) Server(n) (Poll alle $PollIntervalSeconds s, max. $MaxWaitMinutes min)..."

$AllResults = [System.Collections.Generic.List[object]]::new()
$LaunchFailures | ForEach-Object { $AllResults.Add($_) }

$LastStatus = @{}
$PollStart = Get-Date

while ($PendingServers.Count -gt 0 -and ((Get-Date) - $PollStart) -lt (New-TimeSpan -Minutes $MaxWaitMinutes)) {
    foreach ($server in @($PendingServers)) {
        $State = $null
        try {
            $StateJson = Invoke-Command -ComputerName $server -ErrorAction Stop -ScriptBlock {
                param($Path)
                if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw }
            } -ArgumentList "C:\ProgramData\Superops\Scripts\_ManualPatchRun\$RunId\state.json"
            if ($StateJson) { $State = $StateJson | ConvertFrom-Json }
        }
        catch {
            # Waehrend eines Reboots ist WinRM voruebergehend nicht erreichbar - normal, einfach weiter pollen.
            continue
        }
        if (-not $State) { continue }

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
                WhatIf                = $State.WhatIf
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

# PSSessions aus Abschnitt 3 schliessen - der eigentliche Lauf haengt nicht
# daran (er laeuft als Prozess auf dem Zielserver weiter/ist bereits fertig),
# das sind nur unsere Handles dazu.
foreach ($s in $Sessions.Values) {
    Remove-PSSession -Session $s -WhatIf:$false -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------
# 5. Zusammenfassung
# ---------------------------------------------------------

$AllResults | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8 -WhatIf:$false
Write-Info "Ergebnis geschrieben: $OutputCsv"

Write-Host ""
Write-Host "=== Zusammenfassung ===" -ForegroundColor Yellow
$AllResults | Format-Table ServerName, Status, RoundsDone, RebootsDone, UpdatesInstalledTotal, RemainingUpdates, SuperOpsScanOk, ScriptError -AutoSize
