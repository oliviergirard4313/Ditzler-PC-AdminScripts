# ==========================================================
# CHECK ENROLLMENT PC
# Prueft Hybrid Azure AD Join und Intune Enrollment des lokalen PCs
# nach abgeschlossenem Autopilot-Onboarding.
# Start: _check_.cmd (als Enrollment-Benutzer, OHNE Adminrechte)
# ==========================================================
# Autor    : GIO / Claude
# Version  : 2.1
# Datum    : 2026
# Geaendert: 16.10.2026
#
# Zweck:
#   Prueft folgende Punkte:
#   - On-Premises Active Directory Mitgliedschaft
#   - Azure AD Join Status (Hybrid Joined)
#   - Primary Refresh Token (PRT) des angemeldeten Benutzers
#   - Azure AD Geraete-Zertifikat (MS-Organization-Access)
#   - Intune MDM Enrollment (Registry + MDM-Zertifikat)
#   - Windows-Dienste (MDM)
#   - Intune Sync-Status
#
# Ausfuehrungskontext:
#   - Als normaler Enrollment-Benutzer starten (z.B. vorname.nachname@ditzler.ch):
#     dsregcmd liefert den PRT nur fuer den aktuell angemeldeten Benutzer.
#   - Keine Adminrechte, kein WinRM, keine Admin-Credentials noetig: alle
#     Pruefungen sind lesend (Cert:\LocalMachine\My ohne private Schluessel,
#     HKLM\SOFTWARE lesbar fuer Benutzer). Ist ein Bereich nicht lesbar,
#     wird eine Warnung ausgegeben statt eines Fehlers.
#   - Kein SuperOps/keine Lib: rein interaktive Konsolenausgabe.
#
# Aenderungsverlauf:
#   2.0 (2026)      : Version mit Admin-Bloecken via Invoke-Command localhost
#   2.1 (16.10.2026): Kopfzeile nach Ditzler-Standard.
#                     Admin-Credentials + WinRM/TrustedHosts entfernt: es
#                     wurden Domain-Admin-Zugangsdaten auf einem Client
#                     eingegeben (Tiering) und WinRM musste auf jedem Client
#                     aktiviert werden. Alle Pruefungen laufen jetzt im
#                     Benutzerkontext.
#                     Dienste: 'DeviceManagement' und 'AADBrokerPlugin' sind
#                     keine Windows-Dienste -> ersetzt durch DmEnrollmentSvc;
#                     Trigger-Start-Dienste nur noch als INFO.
#                     MdmUrl aus dsregcmd als zusaetzlicher Enrollment-Hinweis.
#                     Rueckgabe-Hashtable nur noch mit -PassThru.
#                     Umlaute/franzoesische Kommentare bereinigt.
# ==========================================================

#Requires -Version 5.1

[CmdletBinding()]
param(
    # Gibt am Ende eine Hashtable mit dem Ergebnis zurueck (fuer Skript-Verkettung)
    [switch]$PassThru
)

Set-StrictMode -Off

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

function Write-Header {
    param([string]$Titel)
    $linie = '-' * 60
    Write-Host ""
    Write-Host $linie -ForegroundColor DarkGray
    Write-Host "  $Titel" -ForegroundColor Cyan
    Write-Host $linie -ForegroundColor DarkGray
}

function Write-Result {
    param(
        [string]$Bezeichnung,
        [string]$Wert,
        [ValidateSet('OK','FEHLER','WARNUNG','INFO')]
        [string]$Status = 'INFO'
    )
    $farbe = switch ($Status) {
        'OK'      { 'Green'  }
        'FEHLER'  { 'Red'    }
        'WARNUNG' { 'Yellow' }
        'INFO'    { 'Gray'   }
    }
    $symbol = switch ($Status) {
        'OK'      { '[OK]  ' }
        'FEHLER'  { '[ERR] ' }
        'WARNUNG' { '[WARN]' }
        'INFO'    { '[INFO]' }
    }
    Write-Host ("  {0} {1,-38} {2}" -f $symbol, $Bezeichnung, $Wert) -ForegroundColor $farbe
}

function Get-DsregOutput {
    # dsregcmd /status im aktuellen Benutzerkontext ausfuehren
    # Gibt Hashtable der Schluessel-Wert-Paare zurueck
    $rohdaten = dsregcmd /status 2>&1
    $ergebnis = @{}
    foreach ($zeile in $rohdaten) {
        if ($zeile -match '^\s+(.+?)\s*:\s*(.+)$') {
            $ergebnis[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    return $ergebnis
}

# ---------------------------------------------------------------------------
# Titelzeile
# ---------------------------------------------------------------------------

$linie = '=' * 60
Write-Host ""
Write-Host $linie -ForegroundColor DarkGray
Write-Host "  HYBRID JOIN & INTUNE ENROLLMENT - PRUEFUNG" -ForegroundColor White
Write-Host "  Louis Ditzler AG - IT-Administration" -ForegroundColor Gray
Write-Host $linie -ForegroundColor DarkGray
Write-Host ""

$aktuellBenutzer = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$istAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ("  Ausfuehrender Benutzer : {0}" -f $aktuellBenutzer) -ForegroundColor Gray
Write-Host ("  Adminkontext           : {0}" -f $(if ($istAdmin) { 'JA (PRT-Ergebnis koennte falsch sein!)' } else { 'NEIN (korrekt)' })) `
    -ForegroundColor $(if ($istAdmin) { 'Yellow' } else { 'Gray' })
Write-Host ""

# Warnung und Abbruchoption wenn als Admin gestartet
if ($istAdmin) {
    Write-Host "  [WARNUNG] Skript laeuft mit erhoehten Rechten." -ForegroundColor Yellow
    Write-Host "  dsregcmd gibt den PRT-Status des Admin-Kontos zurueck, nicht den" -ForegroundColor Yellow
    Write-Host "  des Enrollment-Benutzers." -ForegroundColor Yellow
    Write-Host "  Empfehlung: Skript ohne Adminrechte als Enrollment-Benutzer starten." -ForegroundColor Yellow
    Write-Host ""
    $weiter = Read-Host "  Trotzdem fortfahren? (j/n)"
    if ($weiter -notmatch '^[jJyY]') {
        Write-Host "  Abgebrochen. Bitte als Enrollment-Benutzer neu starten." -ForegroundColor Red
        exit 1
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Ergebnis-Tracking
# ---------------------------------------------------------------------------
$gesamtFehler    = 0
$gesamtWarnungen = 0

# ---------------------------------------------------------------------------
# 1. On-Premises AD Mitgliedschaft
# ---------------------------------------------------------------------------
Write-Header "1. On-Premises Active Directory"

$domainJoined = $false
try {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    if ($cs.PartOfDomain) {
        $domainJoined = $true
        Write-Result "AD-Mitgliedschaft"  "Ja"              'OK'
        Write-Result "Domain"             $cs.Domain        'OK'
        Write-Result "Computername"       $env:COMPUTERNAME 'INFO'
        try {
            $dc = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().FindDomainController()
            Write-Result "DC erreichbar"  $dc.Name          'OK'
        } catch {
            Write-Result "DC erreichbar"  "Nicht erreichbar" 'WARNUNG'
            $gesamtWarnungen++
        }
    } else {
        Write-Result "AD-Mitgliedschaft"  "NICHT in einer Domain" 'FEHLER'
        $gesamtFehler++
    }
} catch {
    Write-Result "AD-Mitgliedschaft"  ("Fehler: {0}" -f $_.Exception.Message) 'FEHLER'
    $gesamtFehler++
}

# ---------------------------------------------------------------------------
# 2. Azure AD / Hybrid Join Status (dsregcmd Benutzerkontext)
# ---------------------------------------------------------------------------
Write-Header "2. Azure AD Hybrid Join (dsregcmd)"

$dsreg        = Get-DsregOutput
$hybridJoined = $false

$azureADJoined     = $dsreg['AzureADJoined']
$domainJoinedDsreg = $dsreg['DomainJoined']

if ($azureADJoined -eq 'YES') {
    Write-Result "AzureADJoined"      "YES"   'OK'
} else {
    Write-Result "AzureADJoined"      $(if ($azureADJoined) { $azureADJoined } else { 'N/A' })  'FEHLER'
    $gesamtFehler++
}

if ($domainJoinedDsreg -eq 'YES') {
    Write-Result "DomainJoined"       "YES"   'OK'
} else {
    Write-Result "DomainJoined"       $(if ($domainJoinedDsreg) { $domainJoinedDsreg } else { 'N/A' })  'FEHLER'
    $gesamtFehler++
}

if ($azureADJoined -eq 'YES' -and $domainJoinedDsreg -eq 'YES') {
    $hybridJoined = $true
    Write-Result "Hybrid Join Status" "HYBRID JOINED"       'OK'
} else {
    Write-Result "Hybrid Join Status" "NICHT hybrid joined" 'FEHLER'
    $gesamtFehler++
}

$enterpriseJoined = $dsreg['EnterpriseJoined']
if ($enterpriseJoined -eq 'NO' -or [string]::IsNullOrEmpty($enterpriseJoined)) {
    Write-Result "EnterpriseJoined"   "NO (erwartet)"  'OK'
} else {
    Write-Result "EnterpriseJoined"   $enterpriseJoined  'WARNUNG'
    $gesamtWarnungen++
}

$workplaceJoined = $dsreg['WorkplaceJoined']
if ($workplaceJoined -eq 'NO' -or [string]::IsNullOrEmpty($workplaceJoined)) {
    Write-Result "WorkplaceJoined"    "NO (erwartet)"  'OK'
} else {
    Write-Result "WorkplaceJoined"    $workplaceJoined  'WARNUNG'
    $gesamtWarnungen++
}

if ($dsreg['TenantName']) { Write-Result "TenantName" $dsreg['TenantName'] 'INFO' }
if ($dsreg['TenantId'])   { Write-Result "TenantId"   $dsreg['TenantId']   'INFO' }
if ($dsreg['DeviceId'])   { Write-Result "DeviceId"   $dsreg['DeviceId']   'INFO' }

# ---------------------------------------------------------------------------
# 3. Primary Refresh Token (dsregcmd Benutzerkontext)
# ---------------------------------------------------------------------------
Write-Header "3. Primary Refresh Token (PRT)"

# dsregcmd /status gibt immer den PRT des aktuell angemeldeten Benutzers zurueck.
# Korrekte Pruefung erfordert, dass das Skript als Enrollment-Benutzer laeuft,
# nicht als lokaler Admin.

$prtUserIdentity  = $dsreg['User Identity']
$azurePRT         = $dsreg['AzureAdPrt']
$wamDefaultSet    = $dsreg['WamDefaultSet']
$prtAttemptStatus = $dsreg['Attempt Status']
$prtServerErrCode = $dsreg['Server Error Code']
$prtServerErrDesc = $dsreg['Server Error Description']

# Erkenne ob der dsreg-Kontext ein nicht-routbarer on-prem UPN ist
$prtKontextLokal = $false
if ($prtUserIdentity -match '@(.+)$') {
    $suffix = $Matches[1]
    $lokaleEndungen = @('.local','.intern','.internal','.lan','.corp','.intra')
    $prtKontextLokal = [bool]($lokaleEndungen | Where-Object { $suffix -like "*$_" })
}

if ($prtUserIdentity) {
    Write-Result "dsreg-Benutzerkontext"  $prtUserIdentity  'INFO'
}

if ($prtKontextLokal) {
    # Skript laeuft unter on-prem Konto - PRT-Ergebnis ist nicht aussagekraeftig
    Write-Result "AzureAdPrt"  "N/A - on-prem Konto (nicht auswertbar)"  'WARNUNG'
    Write-Host ""
    Write-Host "  [HINWEIS] dsreg zeigt den PRT-Status von: $prtUserIdentity" -ForegroundColor Yellow
    Write-Host "  Dieses Konto existiert nicht in Azure AD." -ForegroundColor Yellow
    Write-Host "  Skript als Enrollment-Benutzer (@ditzler.ch) neu starten" -ForegroundColor Yellow
    Write-Host "  fuer eine aussagekraeftige PRT-Pruefung." -ForegroundColor Yellow
    $gesamtWarnungen++
} else {
    # Cloud-Benutzerkontext - PRT-Ergebnis direkt auswertbar
    if ($azurePRT -eq 'YES') {
        Write-Result "AzureAdPrt"  "YES"  'OK'
    } else {
        Write-Result "AzureAdPrt"  $(if ($azurePRT) { $azurePRT } else { 'N/A' })  'FEHLER'
        $gesamtFehler++
    }

    if ($dsreg['AzureAdPrtUpdateTime']) {
        Write-Result "PRT letzte Aktual."  $dsreg['AzureAdPrtUpdateTime']  'INFO'
    }
    if ($dsreg['AzureAdPrtExpiryTime']) {
        Write-Result "PRT Ablaufzeit"      $dsreg['AzureAdPrtExpiryTime']  'INFO'
    }

    # WAM-Status pruefen
    if ($wamDefaultSet -and $wamDefaultSet -notmatch '^(YES|OK)$') {
        Write-Result "WamDefaultSet"  ("$wamDefaultSet (Fehler!)") 'FEHLER'
        $gesamtFehler++
    } elseif ($wamDefaultSet) {
        Write-Result "WamDefaultSet"  $wamDefaultSet  'OK'
    }

    # Fehlerdiagnose bei fehlendem PRT
    if ($azurePRT -ne 'YES') {
        Write-Host ""
        Write-Host "  DIAGNOSE - PRT konnte nicht ausgestellt werden:" -ForegroundColor Magenta

        if ($prtAttemptStatus) { Write-Result "Letzter Fehlercode"  $prtAttemptStatus  'FEHLER' }
        if ($prtServerErrCode) { Write-Result "Server Error Code"   $prtServerErrCode  'FEHLER' }

        # Szenario: AADSTS90002 - nicht-routbarer Tenant-Suffix beim PRT-Renewal
        # Typische Ursache: Geraet laenger ausgeschaltet, PRT abgelaufen,
        # Erneuerungsversuch mit internem UPN-Suffix statt cloud-UPN
        if ($prtServerErrCode -eq 'invalid_request' -and $prtServerErrDesc -like '*AADSTS90002*') {
            Write-Host ""
            Write-Host "  URSACHE: AADSTS90002 - Tenant-Suffix nicht erkannt" -ForegroundColor Yellow
            Write-Host "  Moegliche Ursache: Geraet war laenger ausgeschaltet," -ForegroundColor Yellow
            Write-Host "  PRT ist abgelaufen und Erneuerung schlug mit on-prem UPN fehl." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  KORREKTUR (der Reihe nach versuchen):" -ForegroundColor Cyan
            Write-Host "  [1] dsregcmd /RefreshPrt  (als dieser Benutzer)" -ForegroundColor White
            Write-Host "  [2] Ab- und wieder anmelden" -ForegroundColor White
            Write-Host "  [3] Anmeldeinformationsverwaltung > Windows-Anmeldeinf. >" -ForegroundColor White
            Write-Host "      Eintraege mit 'MicrosoftOffice' oder 'AAD' loeschen > Neuanmeldung" -ForegroundColor White
            Write-Host "  [4] Als Admin: dsregcmd /leave > Neustart > gpupdate /force" -ForegroundColor White
        }

        # Szenario: WAM-Fehler 0x80070520 - Schluesselsatz beschaedigt
        if ($wamDefaultSet -like '*0x80070520*') {
            Write-Host ""
            Write-Host "  URSACHE: WAM 0x80070520 - Token-Cache beschaedigt" -ForegroundColor Yellow
            Write-Host "  KORREKTUR:" -ForegroundColor Cyan
            Write-Host "  [1] Anmeldeinformationsverwaltung leeren (alle AAD-Eintraege)" -ForegroundColor White
            Write-Host "  [2] Als Admin: dsregcmd /leave > Neustart > dsregcmd /join" -ForegroundColor White
        }

        Write-Host ""
    }
}

# ---------------------------------------------------------------------------
# 4. Azure AD Geraete-Zertifikat (Cert:\LocalMachine\My, lesend ohne Admin)
# ---------------------------------------------------------------------------
Write-Header "4. Azure AD Geraete-Zertifikat"

try {
    $cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction Stop |
        Where-Object { $_.Issuer -like '*MS-Organization-Access*' } |
        Sort-Object NotAfter -Descending | Select-Object -First 1

    if ($cert) {
        Write-Result "AAD Zertifikat"  "Vorhanden"                         'OK'
        Write-Result "Aussteller"      $cert.Issuer                        'INFO'
        Write-Result "Gueltig bis"     $cert.NotAfter.ToString('dd.MM.yyyy') 'INFO'
        $r = ($cert.NotAfter - (Get-Date)).Days
        if ($r -lt 0) {
            Write-Result "Restlaufzeit"  "ABGELAUFEN"                   'FEHLER'
            $gesamtFehler++
        } elseif ($r -lt 30) {
            Write-Result "Restlaufzeit"  "$r Tage (bald ablaufend!)"    'WARNUNG'
            $gesamtWarnungen++
        } else {
            Write-Result "Restlaufzeit"  "$r Tage"                      'OK'
        }
    } else {
        Write-Result "AAD Zertifikat"  "NICHT vorhanden"                'FEHLER'
        $gesamtFehler++
    }
} catch {
    Write-Result "AAD Zertifikat"  ("Nicht lesbar: {0}" -f $_.Exception.Message)  'WARNUNG'
    $gesamtWarnungen++
}

# ---------------------------------------------------------------------------
# 5. Intune MDM Enrollment (HKLM + Cert:\LocalMachine, lesend ohne Admin)
# ---------------------------------------------------------------------------
Write-Header "5. Intune MDM Enrollment"

$intuneEnrolled = $false

# MdmUrl aus dsregcmd (Tenant Details) - zusaetzlicher Hinweis, kein Beweis
if ($dsreg['MdmUrl']) { Write-Result "MdmUrl (dsregcmd)"  $dsreg['MdmUrl']  'INFO' }

$enrollInfo     = $null
$enrollLesbar   = $true
$basisPfad      = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
try {
    if (Test-Path $basisPfad) {
        foreach ($ordner in (Get-ChildItem -Path $basisPfad -ErrorAction Stop)) {
            $eig = Get-ItemProperty -Path $ordner.PSPath -ErrorAction SilentlyContinue
            if ($eig.MDMServiceUrl -like '*manage.microsoft.com*' -or $eig.ProviderID -like '*MS DM Server*') {
                $enrollInfo = @{
                    GUID       = $ordner.PSChildName
                    UPN        = $eig.UPN
                    ServiceUrl = $eig.MDMServiceUrl
                }
                break
            }
        }
    }
} catch {
    $enrollLesbar = $false
    Write-Result "HKLM Enrollments"  ("Nicht lesbar: {0}" -f $_.Exception.Message)  'WARNUNG'
    $gesamtWarnungen++
}

if ($enrollInfo) {
    $intuneEnrolled = $true
    Write-Result "Intune Enrollment"  "ENROLLED"  'OK'
    if ($enrollInfo.UPN)        { Write-Result "Enrollment UPN"  $enrollInfo.UPN        'INFO' }
    if ($enrollInfo.ServiceUrl) { Write-Result "MDM Service URL" $enrollInfo.ServiceUrl 'INFO' }
    if ($enrollInfo.GUID)       { Write-Result "Enrollment GUID" $enrollInfo.GUID       'INFO' }
} else {
    # Fallback: Enrollment-Task im Task Scheduler
    $intuneTask = Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like '*Schedule*' } | Select-Object -First 1

    if ($intuneTask) {
        $intuneEnrolled = $true
        Write-Result "Intune Enrollment"  "ENROLLED (via Task Scheduler)"  'OK'
        Write-Result "Task"               $intuneTask.TaskName             'INFO'
    } elseif ($enrollLesbar) {
        Write-Result "Intune Enrollment"  "NICHT enrolled"                 'FEHLER'
        $gesamtFehler++
    } else {
        Write-Result "Intune Enrollment"  "Nicht feststellbar"             'WARNUNG'
        $gesamtWarnungen++
    }
}

# MDM Enrollment-Zertifikat
try {
    $mdmCert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction Stop |
        Where-Object { $_.Issuer   -like '*Microsoft Intune MDM Device CA*' -or
                       $_.Subject  -like '*Microsoft.Management.Services.IntuneWindowsAgent*' } |
        Sort-Object NotAfter -Descending | Select-Object -First 1

    if ($mdmCert) {
        $r = ($mdmCert.NotAfter - (Get-Date)).Days
        Write-Result "MDM Zertifikat"  "Vorhanden"  'OK'
        if ($r -lt 0) {
            Write-Result "MDM Cert Restlaufzeit"  "ABGELAUFEN"                 'FEHLER'
            $gesamtFehler++
        } elseif ($r -lt 30) {
            Write-Result "MDM Cert Restlaufzeit"  "$r Tage (bald ablaufend!)"  'WARNUNG'
            $gesamtWarnungen++
        } else {
            Write-Result "MDM Cert Restlaufzeit"  "$r Tage"                    'OK'
        }
    } else {
        Write-Result "MDM Zertifikat"  "Nicht gefunden (evtl. normal)"  'WARNUNG'
    }
} catch {
    Write-Result "MDM Zertifikat"  ("Nicht lesbar: {0}" -f $_.Exception.Message)  'WARNUNG'
    $gesamtWarnungen++
}

# ---------------------------------------------------------------------------
# 6. Windows-Dienste (MDM)
# ---------------------------------------------------------------------------
Write-Header "6. Windows-Dienste (MDM)"

# dmwappushservice und DmEnrollmentSvc sind Trigger-Start-Dienste: "Stopped" ist normal
$dienste = @(
    @{ Name = 'dmwappushservice';          Anzeige = 'DMWAPPush Service'         ; Pflicht = $false },
    @{ Name = 'DmEnrollmentSvc';           Anzeige = 'Device Mgmt Enrollment Svc'; Pflicht = $false },
    @{ Name = 'IntuneManagementExtension'; Anzeige = 'Intune Mgmt Extension'     ; Pflicht = $true  }
)

foreach ($dienst in $dienste) {
    $svc = Get-Service -Name $dienst.Name -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq 'Running') {
            Write-Result $dienst.Anzeige  "Running"               'OK'
        } elseif ($dienst.Pflicht) {
            Write-Result $dienst.Anzeige  $svc.Status.ToString()  'WARNUNG'
            $gesamtWarnungen++
        } else {
            Write-Result $dienst.Anzeige  ("{0} (Trigger-Start, normal)" -f $svc.Status)  'INFO'
        }
    } else {
        if ($dienst.Pflicht) {
            Write-Result $dienst.Anzeige  "Nicht installiert"  'WARNUNG'
            $gesamtWarnungen++
        } else {
            Write-Result $dienst.Anzeige  "Nicht gefunden"     'INFO'
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Intune Sync-Status
# ---------------------------------------------------------------------------
Write-Header "7. Intune Sync-Status"

# IME-Log in ProgramData - ohne Admin lesbar
$imeLog = "$env:ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneManagementExtension.log"
if (Test-Path $imeLog) {
    $syncZeile = Get-Content $imeLog -Tail 100 -ErrorAction SilentlyContinue |
        Where-Object { $_ -like '*Completed*sync*' -or $_ -like '*Session completed*' } |
        Select-Object -Last 1
    if ($syncZeile) {
        Write-Result "IME letzter Sync"  $syncZeile.Substring(0, [Math]::Min(70, $syncZeile.Length))  'INFO'
    } else {
        Write-Result "IME Log"           "Vorhanden (kein Sync-Eintrag)"  'INFO'
    }
} else {
    Write-Result "IME Log"  "Nicht gefunden"  'INFO'
}

# Sync-Zeitstempel aus HKLM (lesend)
$syncZeit = $null
$pfad = 'HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked'
if (Test-Path $pfad) {
    $key = Get-ChildItem $pfad -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($key) {
        $syncZeit = (Get-ItemProperty -Path $key.PSPath -Name 'LastSyncTime' -ErrorAction SilentlyContinue).LastSyncTime
    }
}
if ($syncZeit) {
    Write-Result "Letzter Sync (Registry)"  $syncZeit  'INFO'
} else {
    Write-Result "Sync-Zeit (Registry)"  "Kein Eintrag gefunden"  'INFO'
}

# ---------------------------------------------------------------------------
# Zusammenfassung
# ---------------------------------------------------------------------------
$linie = '=' * 60
Write-Host ""
Write-Host $linie -ForegroundColor DarkGray
Write-Host "  ZUSAMMENFASSUNG" -ForegroundColor White
Write-Host $linie -ForegroundColor DarkGray

if ($hybridJoined -and $intuneEnrolled -and $gesamtFehler -eq 0) {
    Write-Host "  [OK]  Hybrid Join OK - Intune enrolled - Keine Fehler" -ForegroundColor Green
} elseif ($gesamtFehler -gt 0) {
    Write-Host ("  [ERR] {0} Fehler gefunden - Massnahmen erforderlich!" -f $gesamtFehler) -ForegroundColor Red
} else {
    Write-Host "  [WARN] Konfiguration unvollstaendig oder Warnungen vorhanden" -ForegroundColor Yellow
}

Write-Host ("  Fehler:      {0}" -f $gesamtFehler)    -ForegroundColor $(if ($gesamtFehler    -gt 0) { 'Red'    } else { 'Gray' })
Write-Host ("  Warnungen:   {0}" -f $gesamtWarnungen) -ForegroundColor $(if ($gesamtWarnungen -gt 0) { 'Yellow' } else { 'Gray' })
Write-Host ""

if (-not $hybridJoined) {
    Write-Host "  HINWEISE HYBRID JOIN:" -ForegroundColor Yellow
    Write-Host "  - Entra Connect Sync pruefen (Start-ADSyncSyncCycle -PolicyType Delta)" -ForegroundColor DarkYellow
    Write-Host "  - Computer-OU im Sync-Scope? -> dsregcmd /debug" -ForegroundColor DarkYellow
    Write-Host ""
}

if (-not $intuneEnrolled) {
    Write-Host "  HINWEISE INTUNE ENROLLMENT:" -ForegroundColor Yellow
    Write-Host "  - Autopilot-Profil zugewiesen? (Intune Portal)" -ForegroundColor DarkYellow
    Write-Host "  - Enrollment: dsregcmd /leave -> Neustart -> OOBE" -ForegroundColor DarkYellow
    Write-Host "  - EventViewer: DeviceManagement-Enterprise-Diagnostics-Provider" -ForegroundColor DarkYellow
    Write-Host ""
}

Write-Host $linie -ForegroundColor DarkGray

# Rueckgabewert nur auf Anforderung (sonst erscheint die Hashtable in der Konsole)
if ($PassThru) {
    return @{
        HybridJoined   = $hybridJoined
        IntuneEnrolled = $intuneEnrolled
        Fehleranzahl   = $gesamtFehler
        Warnanzahl     = $gesamtWarnungen
    }
}
