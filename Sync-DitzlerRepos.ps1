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
# Version  : 1.0
# Datum    : 2026-08-06
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

function Invoke-DitzlerRepoSync {
    param(
        [ValidateSet('Pull', 'Push')]
        [string]$Mode
    )

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
}
