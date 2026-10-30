# ==========================================================
# AUTOPILOT-VORBEREITUNG
# Bringt einen neuen PC waehrend der OOBE auf den aktuellen Patchstand
# und registriert ihn anschliessend in Windows Autopilot (Intune).
# Start: Shift+F10 in der OOBE -> __launch_.cmd (vom USB-Stick)
# ==========================================================
# Autor    : GIO / Claude
# Version  : 1.2
# Datum    : unbekannt (vor 16.10.2026)
# Geaendert: 30.10.2026
#
# Zweck:
#   Vorbereitung eines fabrikneuen bzw. frisch installierten PCs fuer das
#   Hybrid-Autopilot-Onboarding, bevor der Benutzer ihn zum ersten Mal
#   startet.
#
# Ausfuehrungskontext:
#   - Shift+F10 in der OOBE = Konto SYSTEM (lokal)
#   - KEINE Integration vorhanden: kein SuperOps-Agent, keine
#     Ditzler-Powershell-Lib, kein Intune -> nur lokales Log, keine Alerts
#   - Protokoll: C:\Service\AutopilotSetup\Work\Autopilot-Vorbereitung.log
#
# Ablauf:
#   Phase Update (wird ueber Neustarts hinweg mehrfach durchlaufen):
#     1. Skript lokal kopieren (falls vom USB-Stick gestartet)
#     2. Netzwerkverbindung pruefen
#     3. PSWindowsUpdate installieren
#     3b. Nur HP: HP Image Assistant (Treiber, BIOS, Firmware) online -
#        im ersten Zyklus, ein zweites Mal nur nach einem BIOS-Update
#        (Ordner "HPIA" neben dem Skript auf dem USB-Stick, sonst Download von HP)
#     4. Windows Updates suchen/installieren, mehrere Durchgaenge ohne
#        Neustart, solange neue Updates gefunden werden
#     5. Neustart-Entscheidung
#        -> Neustart noetig: automatischer Neustart, Skript danach erneut
#           starten (Zykluszaehler wird auf Disk gespeichert)
#        -> Nichts mehr zu tun oder $MaxZyklen erreicht: Update-Phase fertig
#
#   Phase Onboarding (einmalig nach abgeschlossener Update-Phase):
#     6. Get-WindowsAutoPilotInfo, Microsoft.Graph.Authentication und
#        WindowsAutopilotIntune bereitstellen
#     7. Warten auf Tastendruck, Graph-Anmeldung, Hash-Upload + Profil-
#        zuweisung, Verifikation in Intune
#     8. Bereinigung (Flags + lokale Skriptkopie, Log bleibt erhalten)
#
# Aenderungsverlauf:
#   1.0 (vor 16.10.2026): Ursprungsversion
#   1.1 (16.10.2026): Kopfzeile nach Ditzler-Standard.
#                     Update-Phase: wurden Updates ohne Neustart-Indikator
#                     installiert, wurde die Phase bisher sofort als
#                     abgeschlossen markiert - nachgelagerte Updates (SSU ->
#                     CU, .NET usw.) wurden nie gesucht. Jetzt wird im selben
#                     Zyklus erneut gesucht ($MaxDurchgaenge).
#                     Obergrenze $MaxZyklen gegen Endlos-Neustartschleifen
#                     (z.B. dauerhaft fehlschlagendes Update mit RebootPending).
#                     Update-Filter: keine Feature-Upgrades, keine Previews,
#                     optionale KB-Sperrliste $AusgeschlosseneKBs.
#                     Graph-Scopes identisch zu Get-WindowsAutoPilotInfo 3.9
#                     (das Skript ruft intern selbst Connect-MgGraph mit
#                     diesen Scopes auf - abweichende Scopes erzwangen eine
#                     zweite Anmeldung). WindowsAutopilotIntune wird vorab
#                     installiert, Microsoft.Graph.DeviceManagement.Enrollment
#                     entfernt (nicht benoetigt).
#                     Neuer Parameter -GroupTag (optional, Standard leer).
#                     Lokale Kopie jetzt als erster Schritt und inkl.
#                     _launch_.cmd; Kopie wird bei der Bereinigung entfernt.
#                     Set-WinUserLanguageList entfernt (wirkte nur auf das
#                     temporaere OOBE-Konto). Get-WmiObject -> Get-CimInstance.
#   1.2 (30.10.2026): Neuer Schritt 3b: HP Image Assistant vor Windows
#                     Update (nur HP-Geraete). Windows Update liefert BIOS/
#                     Firmware praktisch nie und HP-Treiber oft veraltet.
#                     Im OOBE ist BitLocker noch nicht aktiv und kein
#                     Benutzer angemeldet - ideal fuer den BIOS-Flash.
#                     Online-Modus (Download direkt von HP): als SYSTEM
#                     ohne Domaene ist das Repository auf sv-sto-syno-01
#                     nicht erreichbar. HPIA-Binaries kommen aus dem Ordner
#                     "HPIA" neben dem Skript (USB-Stick) und werden in
#                     Schritt 1 lokal kopiert. Lauf im ersten Zyklus; ein
#                     zweiter Lauf nur, wenn sich die BIOS-Version danach
#                     geaendert hat (Status in hpia-status.json). Exit 3010
#                     -> Neustart ueber die bestehende Zyklus-Logik. Fehler
#                     sind nur Warnungen, das Onboarding wird nicht
#                     blockiert. Windows-Update-Treiber bleiben vorerst
#                     aktiv (Auswertung nach dem ersten Geraet).
#                     Fehlt der Ordner "HPIA" auf dem USB-Stick, wird die
#                     aktuelle Version von HP geladen (Link von der HP-Seite
#                     HPIA.html, sonst Ersatzversion), die HP-Signatur
#                     geprueft und still entpackt.
#                     Starter umbenannt: _launch_.cmd -> __launch_.cmd.
# ==========================================================

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    # Optionaler Autopilot Group Tag (leer = keiner)
    [string]$GroupTag = ''
)

#region Konfiguration
$LocalBase      = 'C:\Service\AutopilotSetup'
$LocalScript    = "$LocalBase\Autopilot-Vorbereitung.ps1"
$LocalLauncher  = "$LocalBase\__launch_.cmd"
$WorkDir        = "$LocalBase\Work"
$LogFile        = "$WorkDir\Autopilot-Vorbereitung.log"

# Speichert die Anzahl der bereits durchlaufenen Update-Zyklen (Neustarts)
$ZyklusDatei    = "$WorkDir\update-zyklus.txt"

# Gesetzt wenn alle Update-Zyklen abgeschlossen sind -> direkt zu Onboarding
$OnboardingFlag = "$WorkDir\onboarding-bereit.flag"

# Maximale Anzahl Neustart-Zyklen, danach wird trotzdem zum Onboarding gewechselt
$MaxZyklen      = 5

# Maximale Anzahl Such-/Installationsdurchgaenge innerhalb eines Zyklus (ohne Neustart)
$MaxDurchgaenge = 3

# HP Image Assistant: Binaries im Unterordner "HPIA" neben dem Skript (USB-Stick)
$HpiaOrdnerName  = 'HPIA'
$HpiaLokal       = "$LocalBase\HPIA"
$HpiaDownloads   = "$WorkDir\HPIA-Downloads"
$HpiaReports     = "$WorkDir\HPIA-Reports"
# Merkt sich Anzahl Laeufe und BIOS-Version vor dem letzten Lauf
$HpiaStatusDatei = "$WorkDir\hpia-status.json"
# Zweiter Lauf nur nach einem BIOS-Update (neue Treiber/Firmware fuer das neue BIOS)
$HpiaMaxLaeufe   = 2
$HpiaEndpunkte   = @('hpia.hpcloud.hp.com', 'ftp.hp.com')
# Download, falls kein HPIA auf dem USB-Stick: offizielle HP-Seite mit dem Link zur
# aktuellen Version; ist sie nicht lesbar, wird die Ersatzversion geladen
$HpiaInfoSeite      = 'https://ftp.ext.hp.com/pub/caps-softpaq/cmit/HPIA.html'
$HpiaErsatzVersion  = '5.3.7'
$HpiaDownloadMuster = 'https://hpia\.hpcloud\.hp\.com/downloads/hpia/hp-hpia-[\d\.]+\.exe'

# HPIA Exit Codes - Quelle: "HP Image Assistant User Guide" (April 2026), Tabelle 7-1
# (identisch zu "HP Client Treiber und Firmware updaten.ps1")
$HpiaExitCodeMap = @{
    0    = "Erfolg, keine Aktion noetig"
    256  = "Erfolg, die Analyse hat keine Empfehlungen ergeben"
    257  = "Erfolg, es wurden keine Empfehlungen fuer die Analyse ausgewaehlt"
    3010 = "Erfolg, Neustart erforderlich (HPIA startet NICHT selbst neu)"
    3011 = "Ein SoftPaq war nicht automatisch installierbar und wurde uebersprungen"
    3020 = "Installation fehlgeschlagen - mindestens eine SoftPaq-Installation ist gescheitert"
    4096 = "Plattform wird nicht unterstuetzt"
    4097 = "Ungueltige Parameter"
    4098 = "Keine Internetverbindung"
    4102 = "TLS 1.2 oder hoeher erforderlich"
    4103 = "Anfrage konnte nicht vollstaendig an den Server gesendet werden"
    8192 = "Vorgang fehlgeschlagen"
    8196 = "Download der Liste unterstuetzter Plattformen fehlgeschlagen"
    8199 = "SoftPaq-Download fehlgeschlagen"
    8200 = "SoftPaq-Extraktion fehlgeschlagen"
}

# Update-Filter: keine Feature-Upgrades, keine Vorschau-Updates (Titel DE/EN)
$WuFilter = @{
    MicrosoftUpdate = $true
    NotCategory     = 'Upgrades'
    NotTitle        = 'Preview|Vorschau'
}

# Sperrliste fuer bekannte Problem-Updates, z.B. @('KB5127648')
$AusgeschlosseneKBs = @()
if ($AusgeschlosseneKBs.Count -gt 0) { $WuFilter.NotKBArticleID = $AusgeschlosseneKBs }

# Exakt die Scopes, mit denen Get-WindowsAutoPilotInfo 3.9 intern Connect-MgGraph aufruft
# -> dessen Aufruf verwendet das bereits vorhandene Token, keine zweite Anmeldung
$GraphScopes = @(
    'DeviceManagementServiceConfig.ReadWrite.All',
    'DeviceManagementManagedDevices.ReadWrite.All',
    'Device.ReadWrite.All',
    'Group.ReadWrite.All',
    'GroupMember.ReadWrite.All'
)

$script:FehlerListe   = [System.Collections.Generic.List[string]]::new()
$script:WarnungsListe = [System.Collections.Generic.List[string]]::new()
#endregion

#region Hilfsfunktionen
function Write-Log {
    param([string]$Nachricht, [string]$Stufe = "INFO")
    $Zeile = "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')][$Stufe] $Nachricht"
    switch ($Stufe) {
        "FEHLER"  { Write-Host $Zeile -ForegroundColor Red }
        "WARNUNG" { Write-Host $Zeile -ForegroundColor Yellow }
        "ERFOLG"  { Write-Host $Zeile -ForegroundColor Green }
        default   { Write-Host $Zeile -ForegroundColor Cyan }
    }
    Add-Content -Path $LogFile -Value $Zeile -ErrorAction SilentlyContinue
}

function Stop-MitFehler {
    param([string]$Nachricht)
    Write-Log $Nachricht "FEHLER"
    $script:FehlerListe.Add($Nachricht)
    Write-Zusammenfassung
    exit 1
}

function Write-Zusammenfassung {
    Write-Log "=== Zusammenfassung ==="
    if ($script:FehlerListe.Count -gt 0) {
        Write-Log "Fehler ($($script:FehlerListe.Count)):" "FEHLER"
        foreach ($f in $script:FehlerListe) { Write-Log "  - $f" "FEHLER" }
    }
    if ($script:WarnungsListe.Count -gt 0) {
        Write-Log "Warnungen ($($script:WarnungsListe.Count)):" "WARNUNG"
        foreach ($w in $script:WarnungsListe) { Write-Log "  - $w" "WARNUNG" }
    }
    if ($script:FehlerListe.Count -eq 0 -and $script:WarnungsListe.Count -eq 0) {
        Write-Log "Keine Fehler oder Warnungen" "ERFOLG"
    }
    Write-Log "Protokoll: $LogFile"
}

# Prueft alle gaengigen Registry-Methoden auf ausstehenden Neustart
function Test-NeustartErforderlich {
    $Noetig = $false

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
        Write-Log "  Neustart-Indikator: CBS RebootPending" "WARNUNG"
        $Noetig = $true
    }

    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
        Write-Log "  Neustart-Indikator: WindowsUpdate RebootRequired" "WARNUNG"
        $Noetig = $true
    }

    $Pfro = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" `
        -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue).PendingFileRenameOperations
    if ($Pfro) {
        Write-Log "  Neustart-Indikator: PendingFileRenameOperations" "WARNUNG"
        $Noetig = $true
    }

    if (Get-Module -Name PSWindowsUpdate -ErrorAction SilentlyContinue) {
        try {
            if (Get-WURebootStatus -Silent -ErrorAction SilentlyContinue) {
                Write-Log "  Neustart-Indikator: PSWindowsUpdate WURebootStatus" "WARNUNG"
                $Noetig = $true
            }
        } catch { }
    }

    return $Noetig
}

# Sucht verfuegbare Updates mit Wiederholung (WU-Agent ist in der OOBE oft noch nicht bereit)
function Get-VerfuegbareUpdates {
    $MaxSuchversuche  = 3
    $SuchWartezeitSek = 30

    for ($Suchversuch = 1; $Suchversuch -le $MaxSuchversuche; $Suchversuch++) {
        try {
            Write-Log "  Suchversuch $Suchversuch/$MaxSuchversuche..."
            $Gefunden = @(Get-WindowsUpdate @WuFilter -ErrorAction Stop)
            Write-Log "  Suche erfolgreich: $($Gefunden.Count) Update(s) gefunden"
            return ,$Gefunden
        } catch {
            $FehlerText = $_.Exception.Message
            Write-Log "  Suchversuch $Suchversuch fehlgeschlagen: $FehlerText" "WARNUNG"
            if ($Suchversuch -lt $MaxSuchversuche) {
                Write-Log "  WU-Agent noch nicht bereit - warte ${SuchWartezeitSek}s..." "WARNUNG"
                Start-Sleep -Seconds $SuchWartezeitSek
                try {
                    Restart-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 10
                } catch { }
            } else {
                Stop-MitFehler "Windows Update Suche nach $MaxSuchversuche Versuchen fehlgeschlagen: $FehlerText"
            }
        }
    }
}

# Laedt HPIA von HP herunter, prueft die HP-Signatur und entpackt nach $HpiaLokal (wirft bei Fehler)
function Install-HpiaVonHp {
    # Fortschrittsanzeige von Invoke-WebRequest bremst den Download in PS 5.1 stark
    $ProgressPreference = 'SilentlyContinue'

    $Url = $null
    try {
        $Seite = Invoke-WebRequest -Uri $HpiaInfoSeite -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $Treffer = [regex]::Match($Seite.Content, $HpiaDownloadMuster)
        if ($Treffer.Success) { $Url = $Treffer.Value }
    } catch {
        Write-Log "  HP-Infoseite nicht lesbar: $($_.Exception.Message)" "WARNUNG"
    }
    if (-not $Url) {
        $Url = "https://hpia.hpcloud.hp.com/downloads/hpia/hp-hpia-$HpiaErsatzVersion.exe"
        Write-Log "  Kein Link gefunden - Ersatzversion $HpiaErsatzVersion" "WARNUNG"
    }

    $Installer = Join-Path $WorkDir (Split-Path $Url -Leaf)
    Write-Log "  Download: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Installer -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop

    # Nur von HP signierte Dateien ausfuehren
    $Signatur = Get-AuthenticodeSignature -FilePath $Installer
    if ($Signatur.Status -ne 'Valid' -or $Signatur.SignerCertificate.Subject -notmatch 'O=HP Inc\.') {
        Remove-Item -Path $Installer -Force -ErrorAction SilentlyContinue
        throw "Signatur ungueltig ($($Signatur.Status), $($Signatur.SignerCertificate.Subject))"
    }
    Write-Log "  Signatur OK: $($Signatur.SignerCertificate.Subject)" "ERFOLG"

    # SoftPaq-Schalter: /s still, /e nur entpacken, /f Zielordner
    $Prozess = Start-Process -FilePath $Installer -ArgumentList '/s', '/e', '/f', $HpiaLokal `
        -Wait -PassThru -ErrorAction Stop
    Remove-Item -Path $Installer -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path (Join-Path $HpiaLokal 'HPImageAssistant.exe'))) {
        throw "Entpacken fehlgeschlagen (Exit $($Prozess.ExitCode)), HPImageAssistant.exe fehlt in $HpiaLokal"
    }
    Write-Log "  HPIA entpackt nach: $HpiaLokal" "ERFOLG"
}

# Countdown-Neustart: speichert Zykluszahl auf Disk, zeigt 30s Countdown, rebootet
function Start-AutomatischerNeustart {
    param([int]$AktuellerZyklus)

    # Naechste Zykluszahl persistieren - wird nach Neustart gelesen
    Set-Content -Path $ZyklusDatei -Value ($AktuellerZyklus + 1) -Encoding UTF8
    Write-Log "Update-Zyklus $AktuellerZyklus abgeschlossen - naechster Zyklus: $($AktuellerZyklus + 1)/$MaxZyklen"

    Write-Log "================================================================" "WARNUNG"
    Write-Log "  NEUSTART WIRD IN 30 SEKUNDEN AUTOMATISCH AUSGEFUEHRT" "WARNUNG"
    Write-Log "  Update-Zyklus $AktuellerZyklus abgeschlossen" "WARNUNG"
    Write-Log "  Nach dem Neustart (OOBE): Shift+F10, dann erneut starten:" "WARNUNG"
    if (Test-Path $LocalLauncher) {
        Write-Log "  Lokal : $LocalLauncher" "WARNUNG"
    } elseif (Test-Path $LocalScript) {
        Write-Log "  Lokal : powershell -ExecutionPolicy Bypass -File `"$LocalScript`"" "WARNUNG"
    }
    Write-Log "  Oder  : __launch_.cmd vom USB-Stick" "WARNUNG"
    Write-Log "================================================================" "WARNUNG"

    for ($i = 30; $i -gt 0; $i--) {
        Write-Host "`r  Neustart in $i Sekunden... (CTRL+C zum Abbrechen)   " `
            -NoNewline -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
    Write-Host ""

    Write-Log "Neustart wird ausgefuehrt..." "WARNUNG"
    shutdown.exe /r /t 0
    exit 0
}
#endregion

#region Initialisierung
if (-not (Test-Path $WorkDir)) {
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
}

# Zykluszahl lesen (0 = erster Durchlauf)
$AktuellerZyklus = 0
if (Test-Path $ZyklusDatei) {
    try {
        $AktuellerZyklus = [int](Get-Content $ZyklusDatei -Raw).Trim()
    } catch {
        $AktuellerZyklus = 0
    }
}

Write-Log "=== Start Autopilot-Vorbereitung v1.2 (Update-Zyklus: $AktuellerZyklus/$MaxZyklen) ==="
$Serial = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
Write-Log "Seriennummer : $Serial"
Write-Log "Computername : $env:COMPUTERNAME"
Write-Log "Konto        : $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Log "Skriptpfad   : $($MyInvocation.MyCommand.Path)"
if ($GroupTag) { Write-Log "Group Tag    : $GroupTag" }
#endregion

# ============================================================================
# ONBOARDING-FLAG / ZYKLUS-OBERGRENZE PRUEFEN
# -> Update-Phase komplett ueberspringen
# ============================================================================
$UpdatePhaseAbgeschlossen = Test-Path $OnboardingFlag
if ($UpdatePhaseAbgeschlossen) {
    Write-Log "Onboarding-Flag gefunden - alle Update-Zyklen abgeschlossen"
} elseif ($AktuellerZyklus -ge $MaxZyklen) {
    $Meldung = "Maximale Anzahl Update-Zyklen ($MaxZyklen) erreicht - Update-Phase wird beendet, Patchstand evtl. unvollstaendig"
    Write-Log $Meldung "WARNUNG"
    $script:WarnungsListe.Add($Meldung)
    New-Item -Path $OnboardingFlag -ItemType File -Force | Out-Null
    $UpdatePhaseAbgeschlossen = $true
}

# ============================================================================
# UPDATE-PHASE
# ============================================================================
if (-not $UpdatePhaseAbgeschlossen) {

    #region Schritt 1: Skript lokal kopieren (USB-Stick wird nach Neustart evtl. entfernt)
    Write-Log "=== Schritt 1: Skript lokal kopieren ==="

    $AktuellerPfad = $MyInvocation.MyCommand.Path
    if ($AktuellerPfad -and ($AktuellerPfad -ne $LocalScript)) {
        try {
            Copy-Item -Path $AktuellerPfad -Destination $LocalScript -Force -ErrorAction Stop
            Write-Log "  Skript kopiert nach: $LocalScript" "ERFOLG"

            $Launcher = Join-Path (Split-Path $AktuellerPfad -Parent) '__launch_.cmd'
            if (Test-Path $Launcher) {
                Copy-Item -Path $Launcher -Destination $LocalLauncher -Force -ErrorAction Stop
                Write-Log "  Starter kopiert nach: $LocalLauncher" "ERFOLG"
            }

            $HpiaQuelle = Join-Path (Split-Path $AktuellerPfad -Parent) $HpiaOrdnerName
            if (Test-Path (Join-Path $HpiaQuelle 'HPImageAssistant.exe')) {
                robocopy "$HpiaQuelle" "$HpiaLokal" /MIR /R:2 /W:2 /NFL /NDL /NP /NJH /NJS | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "Robocopy HPIA Fehler ($LASTEXITCODE)" }
                Write-Log "  HPIA kopiert nach: $HpiaLokal" "ERFOLG"
            }
        } catch {
            $script:WarnungsListe.Add("Lokale Kopie fehlgeschlagen: $($_.Exception.Message)")
            Write-Log "  Lokale Kopie fehlgeschlagen: $($_.Exception.Message)" "WARNUNG"
            Write-Log "  -> Nach Neustart Skript erneut von USB starten" "WARNUNG"
        }
    } else {
        Write-Log "  Skript laeuft bereits lokal - keine Kopie noetig"
    }
    #endregion

    #region Schritt 2: Netzwerkverbindung pruefen
    Write-Log "=== Schritt 2: Netzwerkverbindung pruefen (Zyklus $AktuellerZyklus) ==="

    $Endpunkte = @(
        "graph.microsoft.com",
        "login.microsoftonline.com",
        "windowsupdate.microsoft.com"
    )
    $MaxWarten = 120

    foreach ($Endpunkt in $Endpunkte) {
        $Gewartet  = 0
        $Verbunden = $false

        while (-not $Verbunden) {
            try {
                $Ergebnis = Test-NetConnection -ComputerName $Endpunkt -Port 443 `
                    -ErrorAction Stop -WarningAction SilentlyContinue
                if ($Ergebnis.TcpTestSucceeded) {
                    Write-Log "  $Endpunkt : erreichbar (TCP 443)" "ERFOLG"
                    $Verbunden = $true
                } else {
                    throw "TCP 443 nicht erreichbar"
                }
            } catch {
                if ($Gewartet -ge $MaxWarten) {
                    Stop-MitFehler "$Endpunkt nicht erreichbar nach $MaxWarten Sekunden - Netzwerk pruefen"
                }
                Write-Log "  Warte auf Netzwerk - $Endpunkt ... ($Gewartet s)" "WARNUNG"
                Start-Sleep -Seconds 5
                $Gewartet += 5
            }
        }
    }
    Write-Log "Alle Endpunkte erreichbar" "ERFOLG"
    #endregion

    #region Schritt 3: PSWindowsUpdate bereitstellen
    Write-Log "=== Schritt 3: PSWindowsUpdate bereitstellen ==="
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue)) {
            Write-Log "  NuGet wird installiert..."
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers `
                -ErrorAction Stop | Out-Null
            Write-Log "  PSWindowsUpdate wird installiert..."
            Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -AllowClobber -ErrorAction Stop
            Write-Log "  PSWindowsUpdate installiert" "ERFOLG"
        } else {
            Write-Log "  PSWindowsUpdate bereits vorhanden"
        }
        Import-Module PSWindowsUpdate -Force -ErrorAction Stop
    } catch {
        Stop-MitFehler "PSWindowsUpdate konnte nicht installiert werden: $($_.Exception.Message)"
    }
    #endregion

    #region Schritt 3b: HP Image Assistant (Treiber, BIOS, Firmware)
    # Fehler hier sind nur Warnungen - Windows Update und Onboarding laufen trotzdem weiter
    Write-Log "=== Schritt 3b: HP Image Assistant (Zyklus $AktuellerZyklus) ==="
    $HpiaNeustart = $false

    $Hersteller  = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
    $BiosVersion = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SMBIOSBIOSVersion

    $HpiaStatus = $null
    if (Test-Path $HpiaStatusDatei) {
        try { $HpiaStatus = Get-Content $HpiaStatusDatei -Raw | ConvertFrom-Json } catch { $HpiaStatus = $null }
    }

    $HpiaAusfuehren = $false
    if ($Hersteller -notmatch '^(HP|Hewlett)') {
        Write-Log "  Hersteller '$Hersteller' - kein HP-Geraet, Schritt wird uebersprungen"
    } elseif (-not $HpiaStatus) {
        Write-Log "  Erster HPIA-Lauf (BIOS: $BiosVersion)"
        $HpiaAusfuehren = $true
    } elseif ([int]$HpiaStatus.Laeufe -ge $HpiaMaxLaeufe) {
        Write-Log "  HPIA bereits $($HpiaStatus.Laeufe)x gelaufen - uebersprungen"
    } elseif ($HpiaStatus.BiosVorher -ne $BiosVersion) {
        Write-Log "  BIOS aktualisiert ($($HpiaStatus.BiosVorher) -> $BiosVersion) - zweiter HPIA-Lauf" "ERFOLG"
        $HpiaAusfuehren = $true
    } else {
        Write-Log "  BIOS unveraendert ($BiosVersion) - kein weiterer HPIA-Lauf noetig"
    }

    if ($HpiaAusfuehren) {
        foreach ($Endpunkt in $HpiaEndpunkte) {
            $Ergebnis = Test-NetConnection -ComputerName $Endpunkt -Port 443 `
                -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            if ($Ergebnis.TcpTestSucceeded) {
                Write-Log "  $Endpunkt : erreichbar (TCP 443)" "ERFOLG"
            } else {
                $Meldung = "HPIA uebersprungen: $Endpunkt nicht erreichbar (TCP 443)"
                Write-Log "  $Meldung" "WARNUNG"
                $script:WarnungsListe.Add($Meldung)
                $HpiaAusfuehren = $false
                break
            }
        }
    }

    # Kein HPIA vom USB-Stick -> aktuelle Version direkt von HP herunterladen
    $HpiaExe = Join-Path $HpiaLokal 'HPImageAssistant.exe'
    if ($HpiaAusfuehren -and -not (Test-Path $HpiaExe)) {
        Write-Log "  HPIA nicht auf dem USB-Stick ('$HpiaOrdnerName') - Download von HP"
        try {
            Install-HpiaVonHp
        } catch {
            $Meldung = "HPIA-Download fehlgeschlagen: $($_.Exception.Message) - HP-Treiber/BIOS nicht aktualisiert"
            Write-Log "  $Meldung" "WARNUNG"
            $script:WarnungsListe.Add($Meldung)
            $HpiaAusfuehren = $false
        }
    }

    if ($HpiaAusfuehren) {
        $Laeufe = if ($HpiaStatus) { [int]$HpiaStatus.Laeufe + 1 } else { 1 }
        # Status VOR dem Lauf speichern: bricht HPIA ab oder startet der PC neu,
        # wird beim naechsten Zyklus nicht endlos erneut ausgefuehrt
        [PSCustomObject]@{ Laeufe = $Laeufe; BiosVorher = $BiosVersion } |
            ConvertTo-Json | Set-Content -Path $HpiaStatusDatei -Encoding UTF8

        foreach ($d in @($HpiaDownloads, $HpiaReports)) {
            if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        }

        $HpiaArgs = @(
            '/Operation:Analyze',
            '/Action:Install',
            '/Selection:All',
            "/SoftpaqDownloadFolder:$HpiaDownloads",
            "/ReportFolder:$HpiaReports",
            '/Noninteractive'
        )
        Write-Log "  HPIA-Lauf $Laeufe/$HpiaMaxLaeufe gestartet (dauert oft 10-30 Minuten, Bildschirm kann flackern)..."
        Write-Log "  Aufruf: $HpiaExe $($HpiaArgs -join ' ')"
        try {
            $Prozess = Start-Process -FilePath $HpiaExe -ArgumentList $HpiaArgs -WorkingDirectory $HpiaLokal `
                -Wait -PassThru -ErrorAction Stop
            $HpiaExit = $Prozess.ExitCode
            $Bedeutung = if ($HpiaExitCodeMap.ContainsKey($HpiaExit)) { $HpiaExitCodeMap[$HpiaExit] } else { "Unbekannter Exit Code" }

            if ($HpiaExit -in @(0, 256, 257)) {
                Write-Log "  HPIA beendet: $HpiaExit ($Bedeutung)" "ERFOLG"
            } elseif ($HpiaExit -eq 3010) {
                Write-Log "  HPIA beendet: $HpiaExit ($Bedeutung)" "ERFOLG"
                $HpiaNeustart = $true
            } else {
                $Meldung = "HPIA beendet mit $HpiaExit ($Bedeutung) - Report: $HpiaReports"
                Write-Log "  $Meldung" "WARNUNG"
                $script:WarnungsListe.Add($Meldung)
            }
        } catch {
            $Meldung = "HPIA konnte nicht gestartet werden: $($_.Exception.Message)"
            Write-Log "  $Meldung" "WARNUNG"
            $script:WarnungsListe.Add($Meldung)
        }
    }
    #endregion

    #region Schritt 4: Windows Updates installieren (mehrere Durchgaenge ohne Neustart)
    Write-Log "=== Schritt 4: Windows Update (Zyklus $AktuellerZyklus) ==="
    Write-Log "  Filter: keine Kategorie '$($WuFilter.NotCategory)', kein Titel '$($WuFilter.NotTitle)'"
    if ($AusgeschlosseneKBs.Count -gt 0) {
        Write-Log "  Gesperrte KBs: $($AusgeschlosseneKBs -join ', ')"
    }

    Write-Log "Windows Update Dienst initialisieren..."
    try {
        $WuDienst = Get-Service -Name wuauserv -ErrorAction Stop
        if ($WuDienst.Status -ne 'Running') {
            Write-Log "  wuauserv wird gestartet..."
            Start-Service -Name wuauserv -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
        Write-Log "  wuauserv laeuft: $((Get-Service wuauserv).Status)"
        New-Object -ComObject "Microsoft.Update.ServiceManager" -ErrorAction Stop | Out-Null
        Write-Log "  WUA ServiceManager initialisiert"
        Start-Sleep -Seconds 10
    } catch {
        Write-Log "  WU-Initialisierung: $($_.Exception.Message)" "WARNUNG"
    }

    # Neustart-Bedarf aus HPIA (Exit 3010) wird uebernommen
    $NeustartNoetig       = $HpiaNeustart
    $NochUpdatesOffen     = $false
    $BereitsFehlgeschlagen = [System.Collections.Generic.HashSet[string]]::new()

    for ($Durchgang = 1; $Durchgang -le $MaxDurchgaenge; $Durchgang++) {
        Write-Log "--- Durchgang $Durchgang/${MaxDurchgaenge}: Suche nach Updates ---"
        $VerfuegbareUpdates = Get-VerfuegbareUpdates

        if ($VerfuegbareUpdates.Count -eq 0) {
            Write-Log "Keine Updates verfuegbar" "ERFOLG"
            $NochUpdatesOffen = $false
            break
        }

        Write-Log "$($VerfuegbareUpdates.Count) Update(s) gefunden:"
        foreach ($Update in $VerfuegbareUpdates) {
            Write-Log "  - $($Update.Title) [$($Update.Size)]"
        }

        Write-Log "Installation wird gestartet..."
        $DurchgangInstalliert = $false
        try {
            $InstallErgebnis = @(Install-WindowsUpdate @WuFilter -AcceptAll -IgnoreReboot -ErrorAction Stop)

            $BereitsGeloggt = [System.Collections.Generic.HashSet[string]]::new()
            $Erfolgreich    = @('Installed', 'Succeeded')

            Write-Log "Installationsergebnis:"
            foreach ($Ergebnis in $InstallErgebnis) {
                $Schluessel = if ($Ergebnis.KB) { $Ergebnis.KB } else { $Ergebnis.Title }
                if (-not $BereitsGeloggt.Add($Schluessel)) { continue }

                if ($Ergebnis.Result -in $Erfolgreich) {
                    Write-Log "  OK   : $($Ergebnis.Title)" "ERFOLG"
                    $DurchgangInstalliert = $true
                } else {
                    Write-Log "  WARN : $($Ergebnis.Title) - $($Ergebnis.Result)" "WARNUNG"
                    # Gleiches Update nur einmal pro Zyklus als Warnung erfassen
                    if ($BereitsFehlgeschlagen.Add($Schluessel)) {
                        $script:WarnungsListe.Add("Update fehlgeschlagen: $($Ergebnis.Title) - $($Ergebnis.Result)")
                    }
                }
            }
            Write-Log "Durchgang $Durchgang abgeschlossen ($($BereitsGeloggt.Count) Update(s) verarbeitet)"
        } catch {
            Stop-MitFehler "Update-Installation fehlgeschlagen: $($_.Exception.Message)"
        }

        # Neustart-Pruefung nach jedem Durchgang
        if (Test-NeustartErforderlich) {
            $NeustartNoetig = $true
        } elseif (($InstallErgebnis | Out-String) -match "reboot is required") {
            Write-Log "  Neustart-Indikator: PSWindowsUpdate Output" "WARNUNG"
            $NeustartNoetig = $true
        }
        if ($NeustartNoetig) { break }

        if (-not $DurchgangInstalliert) {
            # Nur fehlgeschlagene Updates uebrig - erneutes Suchen bringt nichts
            Write-Log "Keine Installation erfolgreich in diesem Durchgang - Suche wird beendet" "WARNUNG"
            $NochUpdatesOffen = $false
            break
        }

        # Updates installiert ohne Neustart-Indikator -> nachgelagerte Updates suchen
        Write-Log "Updates installiert ohne Neustart-Indikator - erneute Suche"
        $NochUpdatesOffen = $true
    }
    #endregion

    #region Schritt 5: Neustart-Entscheidung
    Write-Log "=== Schritt 5: Neustart-Entscheidung (Zyklus $AktuellerZyklus) ==="

    if ($NeustartNoetig) {
        Start-AutomatischerNeustart -AktuellerZyklus $AktuellerZyklus
        # Kein Code wird nach Start-AutomatischerNeustart ausgefuehrt (exit 0 darin)
    }

    if ($NochUpdatesOffen) {
        # $MaxDurchgaenge ausgeschoepft und im letzten Durchgang noch installiert:
        # Neustart, damit der naechste Zyklus mit sauberem Stand weitersucht
        Write-Log "$MaxDurchgaenge Durchgaenge ausgeschoepft, evtl. weitere Updates offen - Neustart" "WARNUNG"
        Start-AutomatischerNeustart -AktuellerZyklus $AktuellerZyklus
    }

    Write-Log "System aktuell nach $AktuellerZyklus Neustart(en)" "ERFOLG"

    # Onboarding-Flag setzen und Zykluszaehler bereinigen
    New-Item -Path $OnboardingFlag -ItemType File -Force | Out-Null
    Write-Log "Onboarding-Flag gesetzt: $OnboardingFlag"

    if (Test-Path $ZyklusDatei) {
        Remove-Item -Path $ZyklusDatei -Force -ErrorAction SilentlyContinue
    }
    #endregion

} # Ende Update-Phase

# ============================================================================
# ONBOARDING-PHASE
# ============================================================================

#region Schritt 6: Module bereitstellen
# Alles vor dem Tastendruck installieren - das Browser-Anmeldefenster hat ein Timeout
Write-Log "=== Schritt 6: Get-WindowsAutoPilotInfo und Module bereitstellen ==="
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers `
            -ErrorAction Stop | Out-Null
    }

    if (-not (Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction SilentlyContinue)) {
        Write-Log "  Get-WindowsAutoPilotInfo wird installiert..."
        Install-Script -Name Get-WindowsAutoPilotInfo -Force -Scope AllUsers -ErrorAction Stop
        Write-Log "  Get-WindowsAutoPilotInfo installiert" "ERFOLG"
    } else {
        Write-Log "  Get-WindowsAutoPilotInfo bereits vorhanden"
    }

    $AutopilotScript = "C:\Program Files\WindowsPowerShell\Scripts\Get-WindowsAutoPilotInfo.ps1"
    if (-not (Test-Path $AutopilotScript)) {
        $Installiert = Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction SilentlyContinue
        if ($Installiert) {
            $AutopilotScript = Join-Path $Installiert.InstalledLocation "Get-WindowsAutoPilotInfo.ps1"
        }
    }
    if (-not (Test-Path $AutopilotScript)) {
        Stop-MitFehler "Get-WindowsAutoPilotInfo.ps1 nicht gefunden: $AutopilotScript"
    }
    Write-Log "  Skriptpfad: $AutopilotScript" "ERFOLG"

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication -ErrorAction SilentlyContinue)) {
        Write-Log "  Microsoft.Graph.Authentication wird installiert..."
        Install-Module -Name Microsoft.Graph.Authentication -Force -Scope AllUsers `
            -AllowClobber -ErrorAction Stop
        Write-Log "  Microsoft.Graph.Authentication installiert" "ERFOLG"
    } else {
        Write-Log "  Microsoft.Graph.Authentication bereits vorhanden"
    }

    # Wird von Get-WindowsAutoPilotInfo 3.9 benoetigt (MinimumVersion 5.4.0) - sonst
    # installiert das Skript es selbst, erst NACH dem Tastendruck
    $ApModul = Get-Module -ListAvailable -Name WindowsAutopilotIntune -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]'5.4.0' }
    if (-not $ApModul) {
        Write-Log "  WindowsAutopilotIntune wird installiert..."
        Install-Module -Name WindowsAutopilotIntune -MinimumVersion 5.4.0 -Force -Scope AllUsers `
            -AllowClobber -ErrorAction Stop
        Write-Log "  WindowsAutopilotIntune installiert" "ERFOLG"
    } else {
        Write-Log "  WindowsAutopilotIntune bereits vorhanden"
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Write-Log "  Module geladen" "ERFOLG"
} catch {
    Stop-MitFehler "Module/Skripte konnten nicht bereitgestellt werden: $($_.Exception.Message)"
}
#endregion

#region Schritt 7: Autopilot-Registrierung
Write-Log "=== Schritt 7: Autopilot-Registrierung ==="

$Serial = (Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue).SerialNumber
if (-not $Serial) { Stop-MitFehler "Seriennummer konnte nicht gelesen werden" }
Write-Log "Seriennummer: $Serial"

# WAM deaktivieren - Browser-Fenster erscheint im Vordergrund statt versteckt
$env:MSAL_DISABLE_WAM = "1"

# Pause unmittelbar vor Connect-MgGraph:
# Das Browser-Authentifizierungsfenster hat ein serverseitiges Timeout.
# Alle vorbereitenden Schritte (Module laden, WMI, etc.) sind bereits abgeschlossen.
# -> Tastendruck = Browser oeffnet sich sofort -> Operator meldet sich direkt an.
Write-Host ""
Write-Host ("=" * 64) -ForegroundColor Green
Write-Host "  BEREIT FUER AUTOPILOT-ONBOARDING" -ForegroundColor Green
Write-Host ("=" * 64) -ForegroundColor Green
Write-Host ""
Write-Host "  Vor dem Fortfahren sicherstellen:" -ForegroundColor Yellow
Write-Host "    - PC ist mit dem Internet verbunden" -ForegroundColor Yellow
Write-Host "    - M365-Admin-Zugangsdaten sind bereit" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Beliebige Taste druecken - Browser-Anmeldefenster wird" -ForegroundColor Cyan
Write-Host "  sofort geoeffnet. Sofort anmelden!" -ForegroundColor Cyan
Write-Host ""

# Tastaturpuffer leeren - verhindert dass gepufferte Tasten sofort durchlaufen
while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
# Blockiert ohne Timeout bis Operator eine Taste drueckt
[Console]::ReadKey($true) | Out-Null

Write-Log "Taste gedrueckt - Connect-MgGraph wird gestartet" "ERFOLG"

# Ab hier: kein weiterer Code vor Connect-MgGraph
try {
    Connect-MgGraph -Scopes $GraphScopes -NoWelcome -ErrorAction Stop
    $Kontext = Get-MgContext
    Write-Log "Angemeldet als : $($Kontext.Account)" "ERFOLG"
    Write-Log "Tenant         : $($Kontext.TenantId)" "ERFOLG"
} catch {
    Stop-MitFehler "Graph-Anmeldung fehlgeschlagen: $($_.Exception.Message)"
}

Write-Log "Hash wird hochgeladen und Profil zugewiesen..."
$ApParameter = @{ Online = $true; Assign = $true }
if ($GroupTag) { $ApParameter.GroupTag = $GroupTag }
try {
    & $AutopilotScript @ApParameter -ErrorAction Stop
    Write-Log "Get-WindowsAutoPilotInfo abgeschlossen" "ERFOLG"
} catch {
    Stop-MitFehler "Autopilot-Registrierung fehlgeschlagen: $($_.Exception.Message)"
}

Write-Log "Verifikation: Geraet wird in Intune gesucht..."
$Gefunden    = $false
$MaxVersuche = 5
$WarteSek    = 15

for ($Versuch = 1; $Versuch -le $MaxVersuche; $Versuch++) {
    Write-Log "  Suchversuch $Versuch/$MaxVersuche (warte ${WarteSek}s)..."
    Start-Sleep -Seconds $WarteSek

    try {
        $Uri     = "https://graph.microsoft.com/v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$Serial')"
        $Antwort = Invoke-MgGraphRequest -Uri $Uri -Method GET -ErrorAction Stop

        if ($Antwort.value -and $Antwort.value.Count -gt 0) {
            $Geraet   = $Antwort.value[0]
            $Gefunden = $true
            Write-Log "  Geraet gefunden:" "ERFOLG"
            Write-Log "    ID           : $($Geraet.id)"
            Write-Log "    Seriennummer : $($Geraet.serialNumber)"
            Write-Log "    Group Tag    : $($Geraet.groupTag)"
            Write-Log "    Profilstatus : $($Geraet.deploymentProfileAssignmentStatus)"
            break
        } else {
            Write-Log "  Noch nicht gefunden - naechster Versuch..." "WARNUNG"
        }
    } catch {
        Write-Log "  Verifikation fehlgeschlagen (Versuch $Versuch): $($_.Exception.Message)" "WARNUNG"
    }
}

Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
Write-Log "Graph-Verbindung getrennt"

if (-not $Gefunden) {
    Stop-MitFehler "Geraet '$Serial' nach $MaxVersuche Versuchen nicht in Intune gefunden"
}
#endregion

#region Schritt 8: Bereinigung
# Flags und lokale Skriptkopie entfernen, das Log in $WorkDir bleibt fuer die Nachvollziehbarkeit
Write-Log "=== Schritt 8: Bereinigung ==="

foreach ($Datei in @($OnboardingFlag, $ZyklusDatei, $HpiaStatusDatei, $LocalScript, $LocalLauncher)) {
    if (Test-Path $Datei) {
        try {
            Remove-Item -Path $Datei -Force -ErrorAction Stop
            Write-Log "  Geloescht: $Datei" "ERFOLG"
        } catch {
            Write-Log "  Loeschen fehlgeschlagen: $Datei - $($_.Exception.Message)" "WARNUNG"
            $script:WarnungsListe.Add("Bereinigung fehlgeschlagen: $Datei")
        }
    }
}

# HPIA-Binaries und heruntergeladene SoftPaqs (mehrere GB) entfernen, Reports bleiben
foreach ($Ordner in @($HpiaLokal, $HpiaDownloads)) {
    if (Test-Path $Ordner) {
        try {
            Remove-Item -Path $Ordner -Recurse -Force -ErrorAction Stop
            Write-Log "  Geloescht: $Ordner" "ERFOLG"
        } catch {
            Write-Log "  Loeschen fehlgeschlagen: $Ordner - $($_.Exception.Message)" "WARNUNG"
            $script:WarnungsListe.Add("Bereinigung fehlgeschlagen: $Ordner")
        }
    }
}
#endregion

#region Abschluss
Write-Zusammenfassung

Write-Log "================================================================" "ERFOLG"
Write-Log "  AUTOPILOT-REGISTRIERUNG ABGESCHLOSSEN" "ERFOLG"
Write-Log "  Seriennummer : $Serial" "ERFOLG"
Write-Log "  Naechster Schritt: PC herunterfahren" "ERFOLG"
Write-Log "  Der Benutzer startet den PC und meldet sich" "ERFOLG"
Write-Log "  mit seinem Microsoft 365 Konto an." "ERFOLG"
Write-Log "  Herunterfahren : shutdown /s /t 0" "ERFOLG"
Write-Log "  Oder Neustart  : shutdown /r /t 0" "ERFOLG"
Write-Log "================================================================" "ERFOLG"

exit 0
#endregion
