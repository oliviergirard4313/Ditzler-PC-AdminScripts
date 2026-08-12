#Requires -Version 5.1

# ==========================================================
# START VSCODE WITH GIT SYNC
# Wrapper zum Start von VS Code: pullt vor dem Start alle lokalen
# Ditzler-Repos, startet VS Code fuer den Superops-Workspace und
# wartet ("code --wait"), bis das Fenster geschlossen wird, und pusht
# danach alle Repos - aber NUR falls es bereits lokale Commits gibt,
# die noch nicht auf origin/main liegen (kein automatisches Commit
# von Arbeitsstand, das bleibt bewusst manuell). Pull/Push-Logik liegt
# zentral in Sync-DitzlerRepos.ps1 (Dot-Sourcing, auch von
# Sync-LocalRepo-OnLogon.ps1 genutzt).
# Betrifft NUR diese lokale Arbeitskopie (Heim-PC/Arbeitslaptop von GIO) -
# hat nichts mit den SuperOps-Skripten selbst zu tun. Ersetzt den
# direkten Doppelklick auf Ditzler-SuperOps-Scripts.code-workspace -
# stattdessen dieses Skript (bzw. die Desktop-Verknuepfung darauf)
# verwenden.
# ==========================================================
# Autor    : GIO / Claude
# Version  : 2.2
# Datum    : 2026-08-10
#
# Aenderungsverlauf:
#   1.0 (22.07.2026): Erste Version.
#   1.1 (24.07.2026): RepoPath an Umbenennung SuperOps-Scripts ->
#                     Ditzler-Scripts-Superops angepasst.
#   1.2 (2026-08-06): Auf alle drei lokalen Repos erweitert (noch mit
#                     dupliziertem Code gegenueber Sync-LocalRepo-
#                     OnLogon.ps1).
#   2.0 (2026-08-06): Pull/Push-Logik in Sync-DitzlerRepos.ps1
#                     ausgelagert (von Sync-LocalRepo-OnLogon.ps1
#                     mitgenutzt) - dieses Skript enthaelt nur noch den
#                     VS-Code-spezifischen Teil, um Drift zwischen
#                     beiden PCs zu vermeiden.
#   2.1 (2026-08-06): Kopie von Ditzler-Scripts-Superops nach Teams
#                     (Copy-DitzlerScriptsToTeams in Sync-DitzlerRepos.ps1)
#                     nach jedem VS-Code-Schliessen ergaenzt, fuer die
#                     Verteilung an Kollegen ueber den Teams-Ordner
#                     "Louis Ditzler AG\Informatik - General\Skripten".
#   2.2 (2026-08-10): Teams-Kopie auf die gesamte lokale Arbeitskopie
#                     C:\Admin\Ditzler erweitert (SourcePath statt
#                     $RepoPath), da Copy-DitzlerScriptsToTeams jetzt auf
#                     die Wurzel von "...\VisualStudio Code" zeigt statt
#                     auf den Unterordner "...\Superops" (Wunsch von GIO).
#
# Voraussetzung: "code" muss im PATH sein (Standard bei VS-Code-
# Installation mit "Add to PATH" aktiviert, hier bestaetigt).
# ==========================================================

$RepoPath      = "C:\Admin\Ditzler\Ditzler-Scripts-Superops"
$WorkspaceFile = Join-Path $RepoPath "Ditzler-SuperOps-Scripts.code-workspace"

. (Join-Path $PSScriptRoot "Sync-DitzlerRepos.ps1")

if (-not (Test-Path -LiteralPath $RepoPath)) {
    Show-DitzlerSyncFailure "Repo-Pfad nicht gefunden:`n$RepoPath"
    exit 1
}

# --- Pull vor dem Start (best effort - blockiert den VS-Code-Start nicht) ---
Invoke-DitzlerRepoSync -Mode Pull

# --- VS Code starten und warten, bis das Fenster geschlossen wird ---
Write-DitzlerSyncLog "VS Code wird gestartet (--wait)"
& code --wait $WorkspaceFile
Write-DitzlerSyncLog "VS Code Fenster geschlossen"

# --- Push nach dem Schliessen, nur falls unpushte Commits vorhanden sind ---
Invoke-DitzlerRepoSync -Mode Push

# --- Kopie nach Teams (Louis Ditzler AG\Informatik - General\Skripten\VisualStudio Code) ---
# Fuer die Verteilung an Kollegen - unabhaengig vom Git-Push, immer nach jedem
# VS-Code-Schliessen aktualisiert, damit der Teams-Ordner den aktuellen Stand zeigt.
# Seit 2026-08-10 wird die gesamte lokale Arbeitskopie C:\Admin\Ditzler gespiegelt
# (alle drei Repos plus PatchManagement), nicht mehr nur Ditzler-Scripts-Superops.
Copy-DitzlerScriptsToTeams -SourcePath "C:\Admin\Ditzler"
