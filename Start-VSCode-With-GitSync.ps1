#Requires -Version 5.1

# ==========================================================
# START VSCODE WITH GIT SYNC
# Wrapper zum Start von VS Code fuer dieses Repo: pullt vor dem Start,
# startet VS Code und wartet ("code --wait"), bis das Fenster geschlossen
# wird, und pusht danach automatisch - aber NUR falls es bereits lokale
# Commits gibt, die noch nicht auf origin/main liegen (kein automatisches
# Commit von Arbeitsstand, das bleibt bewusst manuell).
# Betrifft NUR diese lokale Arbeitskopie (Heim-PC/Arbeitslaptop von GIO) -
# hat nichts mit den SuperOps-Skripten selbst zu tun. Ersetzt den
# direkten Doppelklick auf Ditzler-SuperOps-Scripts.code-workspace -
# stattdessen dieses Skript (bzw. die Desktop-Verknuepfung darauf)
# verwenden.
# ==========================================================
# Autor    : GIO / Claude
# Version  : 1.1
# Datum    : 24.07.2026
#
# Aenderungsverlauf:
#   1.0 (22.07.2026): Erste Version.
#   1.1 (24.07.2026): RepoPath an Umbenennung SuperOps-Scripts ->
#                     Ditzler-Scripts-Superops angepasst. Skript selbst lebt
#                     jetzt in einem eigenen Repo (Ditzler-PC-AdminScripts,
#                     dieser Ordner C:\Admin\Ditzler) statt lose ausserhalb
#                     jedes Repos - LogFile daher relativ zu $PSScriptRoot
#                     statt zu $RepoPath (repo1) verschoben.
#
# Voraussetzung: "code" muss im PATH sein (Standard bei VS-Code-
# Installation mit "Add to PATH" aktiviert, hier bestaetigt).
# ==========================================================

$RepoPath      = "C:\Admin\Ditzler\Ditzler-Scripts-Superops"
$WorkspaceFile = Join-Path $RepoPath "Ditzler-SuperOps-Scripts.code-workspace"
$LogFile       = Join-Path $PSScriptRoot "sync-startup.log"

function Write-SyncLog {
    param([string]$Message)
    $line = "{0} - {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}

function Show-SyncFailure {
    param([string]$Message)
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "Ditzler-Scripts: Git-Sync fehlgeschlagen",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    ) | Out-Null
}

if (-not (Test-Path -LiteralPath $RepoPath)) {
    Show-SyncFailure "Repo-Pfad nicht gefunden:`n$RepoPath"
    exit 1
}

Push-Location $RepoPath
try {
    # --- Pull vor dem Start (best effort - blockiert den VS-Code-Start nicht) ---
    $FetchOutput = git fetch origin 2>&1
    if ($LASTEXITCODE -eq 0) {
        $PullOutput = git pull --ff-only 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-SyncLog "WARNUNG vor VS-Code-Start: git pull --ff-only fehlgeschlagen: $PullOutput"
        } else {
            Write-SyncLog "OK vor VS-Code-Start: $PullOutput"
        }
    } else {
        Write-SyncLog "WARNUNG vor VS-Code-Start: git fetch fehlgeschlagen: $FetchOutput"
    }

    # --- VS Code starten und warten, bis das Fenster geschlossen wird ---
    Write-SyncLog "VS Code wird gestartet (--wait)"
    & code --wait $WorkspaceFile
    Write-SyncLog "VS Code Fenster geschlossen"

    # --- Push nach dem Schliessen, nur falls unpushte Commits vorhanden sind ---
    git fetch origin 2>&1 | Out-Null
    $Ahead = git rev-list --count '@{u}..HEAD' 2>&1

    if ($LASTEXITCODE -eq 0 -and [int]$Ahead -gt 0) {
        $PushOutput = git push 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-SyncLog "FEHLER bei git push nach VS-Code-Schliessung: $PushOutput"
            Show-SyncFailure "Automatischer Push nach VS Code ist fehlgeschlagen (vermutlich Konflikt/kein Netzwerk).`nBitte manuell in $RepoPath pruefen.`n`n$PushOutput"
        } else {
            Write-SyncLog "OK: $Ahead Commit(s) gepusht"
        }
    } else {
        Write-SyncLog "Kein Push noetig (keine unpushten Commits)"
    }
} finally {
    Pop-Location
}
