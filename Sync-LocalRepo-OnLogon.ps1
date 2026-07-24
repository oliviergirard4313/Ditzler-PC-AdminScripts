#Requires -Version 5.1

# ==========================================================
# SYNC LOCAL REPO ON LOGON
# Holt bei jeder Windows-Anmeldung automatisch den aktuellen Stand
# von origin/main in dieses lokale Repo (git fetch + ff-only pull).
# Betrifft NUR diese lokale Arbeitskopie (Heim-PC/Arbeitslaptop von
# GIO) - hat nichts mit "Sync SuperOps Files from Git.ps1" zu tun,
# das Dateien auf die Zielserver verteilt.
# ==========================================================
# Autor    : GIO / Claude
# Version  : 1.1
# Datum    : 24.07.2026
#
# Aenderungsverlauf:
#   1.0 (21.07.2026): Erste Version.
#   1.1 (24.07.2026): RepoPath an Umbenennung SuperOps-Scripts ->
#                     Ditzler-Scripts-Superops angepasst. Skript selbst lebt
#                     jetzt in einem eigenen Repo (Ditzler-PC-AdminScripts,
#                     dieser Ordner C:\Admin\Ditzler) statt lose ausserhalb
#                     jedes Repos - LogFile daher relativ zu $PSScriptRoot
#                     statt zu $RepoPath (repo1) verschoben.
#
# Einrichtung: per Windows-Aufgabenplanung, Trigger "Bei Anmeldung",
# im Kontext des angemeldeten Benutzers, versteckt (-WindowStyle Hidden).
# Bei Fehlschlag (kein Netzwerk, Konflikt, nicht-schnellvorlaufbar) wird
# eine Meldung am Bildschirm angezeigt; im Erfolgsfall keine Ausgabe.
# ==========================================================

$RepoPath = "C:\Admin\Ditzler\Ditzler-Scripts-Superops"
$LogFile  = Join-Path $PSScriptRoot "sync-startup.log"

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

try {
    if (-not (Test-Path $RepoPath)) {
        Write-SyncLog "FEHLER: Repo-Pfad nicht gefunden: $RepoPath"
        Show-SyncFailure "Repo-Pfad nicht gefunden:`n$RepoPath"
        exit 1
    }

    Push-Location $RepoPath
    try {
        $fetchOutput = git fetch origin 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-SyncLog "FEHLER bei git fetch: $fetchOutput"
            Show-SyncFailure "git fetch ist fehlgeschlagen (kein Netzwerk?):`n$fetchOutput"
            exit 1
        }

        $pullOutput = git pull --ff-only 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-SyncLog "FEHLER bei git pull --ff-only: $pullOutput"
            Show-SyncFailure "Automatischer Git-Sync fehlgeschlagen (vermutlich lokale Aenderungen oder Konflikt).`nBitte manuell in $RepoPath pruefen.`n`n$pullOutput"
            exit 1
        }

        Write-SyncLog "OK: $pullOutput"
    } finally {
        Pop-Location
    }
} catch {
    Write-SyncLog "AUSNAHME: $($_.Exception.Message)"
    Show-SyncFailure "Unerwarteter Fehler beim Git-Sync:`n$($_.Exception.Message)"
    exit 1
}
