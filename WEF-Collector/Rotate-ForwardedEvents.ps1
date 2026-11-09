<#
.SYNOPSIS
    Archiviert und leert das ForwardedEvents-Log taeglich und loescht zu alte
    Archive. Wird ueber eine taegliche geplante Aufgabe auf SV-OS-BAK-12
    ausgefuehrt (Aufgabe "Rotate-ForwardedEvents", 23:05, SYSTEM).

.DESCRIPTION
    1. Verschiebt automatische Windows-Archive (Archive-ForwardedEvents-*.evtx,
       entstehen bei autoBackup=true, wenn das Log die Maximalgroesse erreicht)
       aus dem Log-Ordner in den Archiv-Ordner.
    2. Sichert und leert das Log in einem Schritt (wevtutil cl /bu), damit
       zwischen Export und Leeren keine Ereignisse verloren gehen.
    3. Loescht Archive, die aelter als RetentionDays sind. Die Langzeit-
       aufbewahrung (1 Jahr) erfolgt im zentralen Log-Server, nicht hier.

.NOTES
    Version : 1.1
    Datum   : 09.11.2026
    Aenderungen:
      1.1 - wevtutil cl /bu statt epl + cl (kein Verlustfenster)
          - automatische Archive (autoBackup) werden einbezogen
          - Standard-Aufbewahrung 30 Tage
      1.0 - 14.08.2026, Erstversion (epl + cl)
    Muss mit Administratorrechten ausgefuehrt werden.
    Voraussetzung: wevtutil sl ForwardedEvents /rt:true /ab:true
#>

param(
    [string]$LogName       = "ForwardedEvents",
    [string]$ArchiveDir    = "D:\WindowsEventForwarding\Archive",
    [int]$RetentionDays    = 30
)

if (-not (Test-Path $ArchiveDir)) {
    New-Item -Path $ArchiveDir -ItemType Directory -Force | Out-Null
}

# 1. Automatische Archive (autoBackup) in den Archiv-Ordner verschieben
$logDatei = (Get-WinEvent -ListLog $LogName -ErrorAction Stop).LogFilePath
$logOrdner = Split-Path ([Environment]::ExpandEnvironmentVariables($logDatei)) -Parent
$autoArchive = Get-ChildItem -Path $logOrdner -Filter "Archive-$LogName-*.evtx" -File -ErrorAction SilentlyContinue
foreach ($a in $autoArchive) {
    Write-Output "[$(Get-Date)] Verschiebe automatisches Archiv $($a.Name)..."
    Move-Item -Path $a.FullName -Destination $ArchiveDir -Force
}

# 2. Log sichern und leeren in einem Schritt
$datum       = Get-Date -Format "yyyyMMdd_HHmmss"
$archivDatei = Join-Path $ArchiveDir "$LogName`_$datum.evtx"

Write-Output "[$(Get-Date)] Sichere und leere $LogName nach $archivDatei..."
wevtutil cl $LogName "/bu:$archivDatei"

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $archivDatei)) {
    Write-Error "[$(Get-Date)] Sichern/Leeren fehlgeschlagen (wevtutil cl /bu), Code $LASTEXITCODE."
    exit 1
}

# 3. Alte Archive loeschen (aelter als $RetentionDays Tage)
$schwelle = (Get-Date).AddDays(-$RetentionDays)
$alteArchive = Get-ChildItem -Path $ArchiveDir -File |
    Where-Object { ($_.Name -like "$LogName`_*.evtx" -or $_.Name -like "Archive-$LogName-*.evtx") -and $_.LastWriteTime -lt $schwelle }

if ($alteArchive) {
    Write-Output "[$(Get-Date)] Loesche $($alteArchive.Count) Archiv(e) aelter als $RetentionDays Tage..."
    $alteArchive | Remove-Item -Force
}

Write-Output "[$(Get-Date)] Rotation abgeschlossen."
