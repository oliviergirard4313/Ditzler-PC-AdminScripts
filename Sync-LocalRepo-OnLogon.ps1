#Requires -Version 5.1

# ==========================================================
# SYNC LOCAL REPO ON LOGON
# Holt bei jeder Windows-Anmeldung automatisch den aktuellen Stand
# von origin/main in alle lokalen Ditzler-Repos (git fetch + ff-only
# pull, je Repo). Reine Pull-Logik liegt zentral in
# Sync-DitzlerRepos.ps1 (Dot-Sourcing) - hier nur noch der Aufruf,
# damit dieses Skript und Start-VSCode-With-GitSync.ps1 nicht mehr
# unabhaengig voneinander auseinanderlaufen koennen.
# Betrifft NUR diese lokale Arbeitskopie (Heim-PC/Arbeitslaptop von
# GIO) - hat nichts mit "Sync SuperOps Files from Git.ps1" zu tun,
# das Dateien auf die Zielserver verteilt.
# ==========================================================
# Autor    : GIO / Claude
# Version  : 2.0
# Datum    : 2026-08-06
#
# Aenderungsverlauf:
#   1.0 (21.07.2026): Erste Version.
#   1.1 (24.07.2026): RepoPath an Umbenennung SuperOps-Scripts ->
#                     Ditzler-Scripts-Superops angepasst.
#   1.2 (2026-08-06): Auf alle drei lokalen Repos erweitert (noch mit
#                     dupliziertem Code gegenueber Start-VSCode-With-
#                     GitSync.ps1).
#   2.0 (2026-08-06): Pull-Logik in Sync-DitzlerRepos.ps1 ausgelagert
#                     (von Start-VSCode-With-GitSync.ps1 mitgenutzt) -
#                     dieses Skript ist jetzt nur noch ein duenner
#                     Aufrufer, um Drift zwischen beiden PCs zu
#                     vermeiden.
#
# Einrichtung: per Windows-Aufgabenplanung (siehe
# Register-DitzlerSyncTask.ps1 fuer eine reproduzierbare Einrichtung
# auf jedem PC), Trigger "Bei Anmeldung", im Kontext des angemeldeten
# Benutzers, versteckt (-WindowStyle Hidden). Bei Fehlschlag (kein
# Netzwerk, Konflikt, nicht-schnellvorlaufbar) wird eine Meldung am
# Bildschirm angezeigt; im Erfolgsfall keine Ausgabe.
# ==========================================================

. (Join-Path $PSScriptRoot "Sync-DitzlerRepos.ps1")
Invoke-DitzlerRepoSync -Mode Pull
