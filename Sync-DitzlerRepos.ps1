#Requires -Version 5.1

# ==========================================================
# SYNC DITZLER REPOS (gemeinsame Bibliothek)
# Zentrale Liste der lokalen Ditzler-Repos + Pull/Push-Logik, per
# Dot-Sourcing von Sync-LocalRepo-OnLogon.ps1 und
# Start-VSCode-With-GitSync.ps1 genutzt. Kein eigenstaendiges Skript -
# definiert nur Funktionen/Variablen, fuehrt selbst nichts aus.
# Grund: beide Aufrufer synchronisierten bisher unabhaengig voneinander
# nur EIN Repo (Ditzler-Scripts-Superops) und drohten bei kuenftigen
# Aenderungen auseinanderzulaufen (2026-08-06 bereits einmal passiert -
# neue Skripte in PatchManagement/ wurden auf einem zweiten PC nicht
# sichtbar, weil beide Sync-Skripte den Ordner Ditzler-PC-AdminScripts
# (diesen Ordner selbst) gar nicht kannten).
# ==========================================================
# Autor    : GIO / Claude
# Version  : 1.3
# Datum    : 2026-08-27
#
# Aenderungsverlauf:
#   1.3 (2026-08-27): Invoke-DitzlerRepoSync durch einen Mutex serialisiert -
#                     die Logon-Aufgabe (Sync-LocalRepo-OnLogon.ps1) und ein
#                     gleichzeitig manuell gestartetes Start-VSCode-With-
#                     GitSync.ps1 pullten sonst parallel im selben Repo-
#                     Ordner und liessen sich gegenseitig FETCH_HEAD
#                     kaputtschreiben ("fatal: Cannot fast-forward to
#                     multiple branches" am 20.08. und 27.08.2026, jeweils
#                     Sekunden nach dem Logon-Trigger - kein echter Konflikt,
#                     alle drei Repos waren danach clean/up-to-date).
#   1.0 (2026-08-06): Erste Version (Pull/Push fuer alle drei Repos).
#   1.1 (2026-08-06): Copy-DitzlerScriptsToTeams ergaenzt - kopiert
#                     Ditzler-Scripts-Superops (ohne .git/.claude/old/
#                     Logs) per robocopy /MIR in den Teams-Ordner
#                     "Louis Ditzler AG\Informatik - General\Skripten\
#                     VisualStudio Code", fuer die Verteilung an
#                     Kollegen. Von Start-VSCode-With-GitSync.ps1 nach
#                     jedem VS-Code-Schliessen aufgerufen.
#   1.2 (2026-08-10): Copy-DitzlerScriptsToTeams zeigt jetzt auf die
#                     Wurzel von "VisualStudio Code" statt auf den
#                     Unterordner "...\Superops" - Aufrufer uebergibt
#                     seither "C:\Admin\Ditzler" (alle drei Repos plus
#                     PatchManagement) statt nur Ditzler-Scripts-
#                     Superops als SourcePath (Wunsch von GIO,
#                     2026-08-10). ACHTUNG: robocopy /MIR loescht dabei
#                     alles im Teams-Zielordner, das nicht (mehr) unter
#                     C:\Admin\Ditzler existiert - beim Umstieg hat das
#                     bewusst den alten Unterordner "...\Superops" sowie
#                     die dort bereits vorhandenen, nicht von diesem
#                     Sync verwalteten Eintraege "Intune\" und
#                     "MaintenanceVMs on HyperV.txt" entfernt.
# ==========================================================

$Global:DitzlerRepos = @(
    "C:\Admin\Ditzler",
    "C:\Admin\Ditzler\Ditzler-Scripts-Superops",
    "C:\Admin\Ditzler\Ditzler-Azure-Automation"
)

$Global:DitzlerSyncLogFile = "C:\Admin\Ditzler\sync-startup.log"

function Write-DitzlerSyncLog {
    param([string]$Message)
    $line = "{0} - {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $Global:DitzlerSyncLogFile -Value $line -Encoding UTF8
}

function Show-DitzlerSyncFailure {
    param([string]$Message)
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "Ditzler-Scripts: Git-Sync fehlgeschlagen",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

function Sync-DitzlerRepoPull {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-DitzlerSyncLog "FEHLER [$Path]: Repo-Pfad nicht gefunden"
        Show-DitzlerSyncFailure "Repo-Pfad nicht gefunden:`n$Path"
        return $false
    }

    Push-Location $Path
    try {
        $FetchOutput = git fetch origin 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-DitzlerSyncLog "FEHLER bei git fetch [$Path]: $FetchOutput"
            Show-DitzlerSyncFailure "git fetch ist fehlgeschlagen (kein Netzwerk?):`n$Path`n$FetchOutput"
            return $false
        }

        $PullOutput = git pull --ff-only 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-DitzlerSyncLog "FEHLER bei git pull --ff-only [$Path]: $PullOutput"
            Show-DitzlerSyncFailure "Automatischer Git-Sync fehlgeschlagen (vermutlich lokale Aenderungen oder Konflikt).`nBitte manuell in $Path pruefen.`n`n$PullOutput"
            return $false
        }

        Write-DitzlerSyncLog "OK Pull [$Path]: $PullOutput"
        return $true
    } finally {
        Pop-Location
    }
}

function Sync-DitzlerRepoPush {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    Push-Location $Path
    try {
        git fetch origin 2>&1 | Out-Null
        $Ahead = git rev-list --count '@{u}..HEAD' 2>&1

        if ($LASTEXITCODE -eq 0 -and [int]$Ahead -gt 0) {
            $PushOutput = git push 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-DitzlerSyncLog "FEHLER bei git push [$Path]: $PushOutput"
                Show-DitzlerSyncFailure "Automatischer Push ist fehlgeschlagen (vermutlich Konflikt/kein Netzwerk).`nBitte manuell in $Path pruefen.`n`n$PushOutput"
                return $false
            }

            Write-DitzlerSyncLog "OK Push [$Path]: $Ahead Commit(s) gepusht"
            return $true
        }

        Write-DitzlerSyncLog "Kein Push noetig [$Path] (keine unpushten Commits)"
        return $true
    } finally {
        Pop-Location
    }
}

function Copy-DitzlerScriptsToTeams {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath
    )

    $TeamsPath = Join-Path $env:USERPROFILE "Louis Ditzler AG\Informatik - General\Skripten\VisualStudio Code"

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Write-DitzlerSyncLog "FEHLER Teams-Kopie: Quelle nicht gefunden: $SourcePath"
        return
    }

    if (-not (Test-Path -LiteralPath $TeamsPath)) {
        try {
            New-Item -Path $TeamsPath -ItemType Directory -Force | Out-Null
        } catch {
            Write-DitzlerSyncLog "FEHLER Teams-Kopie: Zielordner konnte nicht erstellt werden: $($_.Exception.Message)"
            return
        }
    }

    # /MIR spiegelt den Ordner (loescht auch entfernte/umbenannte Dateien im Ziel).
    # .git/.claude/old sowie Log-/Backup-Dateien werden bewusst nicht mitkopiert -
    # der Teams-Ordner ist fuer die Verteilung an Kollegen gedacht, nicht als
    # zweites Git-Repo oder Ablage fuer interne Tooling-Config.
    & robocopy $SourcePath $TeamsPath /MIR /XD ".git" ".claude" "old" /XF "*.log" "*.bak.ps1" /NFL /NDL /NJH /NJS /NP | Out-Null

    if ($LASTEXITCODE -ge 8) {
        Write-DitzlerSyncLog "FEHLER Teams-Kopie: robocopy Exit-Code $LASTEXITCODE"
    } else {
        Write-DitzlerSyncLog "OK Teams-Kopie nach $TeamsPath (robocopy Exit-Code $LASTEXITCODE)"
    }
}

function Invoke-DitzlerRepoSync {
    param(
        [ValidateSet('Pull', 'Push')]
        [string]$Mode
    )

    # Mutex verhindert, dass die Logon-Aufgabe (Sync-LocalRepo-OnLogon.ps1) und ein
    # gleichzeitig gestartetes Start-VSCode-With-GitSync.ps1 im selben Repo-Ordner
    # parallel fetchen/pullen - sonst ueberschreiben sich die FETCH_HEAD-Dateien
    # gegenseitig und "git pull --ff-only" bricht mit "Cannot fast-forward to
    # multiple branches" ab (beobachtet am 20.08. und 27.08.2026, jeweils direkt
    # nach dem Logon-Trigger). Kein "Global\"-Praefix noetig, da beide Aufrufer
    # immer in derselben interaktiven Benutzersitzung laufen.
    $Mutex = New-Object System.Threading.Mutex($false, "DitzlerRepoSyncMutex")
    $Acquired = $false
    try {
        $Acquired = $Mutex.WaitOne([TimeSpan]::FromMinutes(5))
    } catch [System.Threading.AbandonedMutexException] {
        Write-DitzlerSyncLog "WARNUNG: Sync-Mutex war verwaist (vorheriger Sync abgebrochen?) - trotzdem uebernommen"
        $Acquired = $true
    }

    if (-not $Acquired) {
        Write-DitzlerSyncLog "FEHLER: Sync-Mutex nach 5 Minuten nicht erhalten (Mode=$Mode) - vermutlich haengender paralleler Sync"
        Show-DitzlerSyncFailure "Git-Sync blockiert: Ein anderer Sync-Vorgang laeuft offenbar schon zu lange (>5 Min).`nBitte pruefen, ob ein altes PowerShell-Fenster haengt."
        return
    }

    try {
        foreach ($Repo in $Global:DitzlerRepos) {
            try {
                if ($Mode -eq 'Pull') {
                    Sync-DitzlerRepoPull -Path $Repo | Out-Null
                } else {
                    Sync-DitzlerRepoPush -Path $Repo | Out-Null
                }
            } catch {
                Write-DitzlerSyncLog "AUSNAHME [$Repo]: $($_.Exception.Message)"
                Show-DitzlerSyncFailure "Unerwarteter Fehler beim Git-Sync von $Repo`:`n$($_.Exception.Message)"
            }
        }
    } finally {
        $Mutex.ReleaseMutex()
        $Mutex.Dispose()
    }
}
