#Requires -Version 5.1

# ==========================================================
# Skript: Generate SuperOps Alert Dashboard
# Autor: GIO / Claude
# Version: 1.0
# Datum: 2026-08-12
#
# Zweck:
#   Erzeugt eine HTML-Seite mit dem VOLLTEXT aktiver SuperOps-Alerts, fuer
#   den TV-Dashboard am grossen Bildschirm im Buero (Raspberry Pi im
#   Kiosk-Modus, siehe RaspberryPi-Dashboard/). Noetig, weil der SuperOps
#   Report-Editor (z.B. der bestehende Report "HAL 9000") nur Tabellen/
#   Zaehler-Widgets kennt, aber kein Widget mit dem rohen Alert-Text
#   anbietet (bestaetigt durch GIO am 12.08.2026).
#
#   Architektur (angepasst 12.08.2026, siehe CLAUDE.md):
#   - PRTG wird HIER NICHT mehr integriert. GIO baut dafuer stattdessen
#     eine eigene PRTG-Map (natives PRTG-Feature), deren URL direkt in
#     einem zweiten, separaten Chromium-Kiosk-Fenster auf dem Pi
#     angezeigt wird. Kein Scraping/API-Aufruf gegen PRTG mehr noetig,
#     zumal PRTG mittelfristig sowieso abgeloest werden soll.
#   - Auf dem Pi laufen daher ZWEI gekachelte Chromium-Kiosk-Fenster
#     nebeneinander (eines pro Quelle) statt einer einzigen kombinierten
#     Seite - dieses Skript rendert nur noch die SuperOps-Haelfte.
#
#   Laeuft NICHT als SuperOps Recurring Script (siehe Register-
#   DashboardTask.ps1 - dafuer eine normale Windows-Aufgabenplanung, da
#   dieses Skript kein Monitoring/Alerting ist, sondern nur eine Anzeige
#   erzeugt, und die gewuenschte Taktung von 30-60s ausserhalb des
#   ueblichen SuperOps-Rhythmus liegt).
#
#   Muss auf einem Server mit gueltiger credentials.xml laufen (SV-OS-PRB-01,
#   nicht auf dem Raspberry Pi - der bekommt nie Zugangsdaten zu sehen,
#   siehe CLAUDE.md "Verwaltung der Zugangsdaten").
#
# ZU VALIDIEREN (siehe Test-SuperOpsAlertSchema.ps1):
#   Die SuperOps-GraphQL-Abfrage in Get-SuperOpsActiveAlerts (getAlertList)
#   ist eine Analogiebildung zu getAssetList/getUserList - noch NICHT
#   empirisch gegen die echte API bestaetigt. Vor dem produktiven Einsatz
#   Test-SuperOpsAlertSchema.ps1 auf SV-OS-PRB-01 ausfuehren und diese
#   Funktion bei Bedarf an die echten Feldnamen anpassen.
#
# Verhalten bei Ausfall:
#   Wenn SuperOps nicht erreichbar ist, zeigt die Seite einen Hinweistext
#   statt fehlzuschlagen, UND es wird ein kritischer SuperOps-Alert
#   gesendet (der Bildschirm soll nie unbemerkt veraltet bleiben).
#
# Aenderungsverlauf:
#   1.0 (2026-08-12): Erste Version (kombiniert SuperOps+PRTG)
#   2.0 (2026-08-12): PRTG-Teil entfernt - PRTG laeuft ab jetzt als
#                      eigenes, natives Kiosk-Fenster (eigene PRTG-Map,
#                      kein Scraping mehr). Siehe Aenderungsverlauf oben.
# ==========================================================

param(
    [int]$RefreshSeconds = 60,
    [switch]$DebugMode
)

# ------------------ PFADE ----------------------
$SuperOpsScriptDir = "C:\ProgramData\Superops\Scripts"
$LibPath           = Join-Path $SuperOpsScriptDir "Ditzler-Powershell-Lib.psm1"
$CredFile          = Join-Path $SuperOpsScriptDir "credentials.xml"

# Zielordner fuer die generierte Seite - muss als IIS-Site/-Anwendung auf
# SV-OS-PRB-01 eingerichtet sein (einmalig, siehe CLAUDE.md, Abschnitt
# TV-Dashboard). Wird hier NICHT automatisch angelegt/konfiguriert.
$OutputDir  = "C:\ProgramData\Superops\Scripts\DashboardWeb"
$OutputFile = Join-Path $OutputDir "dashboard.html"

if (-not (Test-Path -LiteralPath $LibPath)) {
    Write-Error "Bibliothek nicht gefunden: $LibPath"
    exit 1
}

Import-Module $LibPath -Force -ErrorAction Stop
Initialize-LocalLog -ScriptName "Dashboard-Generator" -DebugMode:$DebugMode -SendAlerts
Write-LocalLog -Level "INFO" -Message "=========================================================="
Write-LocalLog -Level "INFO" -Message "Dashboard-Generator gestartet, RefreshSeconds=$RefreshSeconds"

Initialize-WorkDir

try {
    $AllCreds = Get-Credentials -FileName $CredFile
    Initialize-SuperOpsCreds -AllCreds $AllCreds
    Write-LocalLog -Level "INFO" -Message "Credentials geladen"
}
catch {
    Write-ExceptionDetails -ErrorRecord $_ -Context "Credentials laden"
    Stop-Script -Step "Init" -Message "Dashboard-Generator: Credentials konnten nicht geladen werden: $($_.Exception.Message)"
}

# ==========================================================
# HILFSFUNKTIONEN
# ==========================================================

function ConvertTo-SafeHtml {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

# ZU VALIDIEREN - siehe Kopfkommentar. getAlertList/alertId/message/
# description/severity/status sind eine Analogiebildung, keine bestaetigte
# API-Antwort. Bei Fehlschlag wird $null zurueckgegeben (Seite zeigt
# stattdessen einen Hinweistext, siehe New-DashboardHtml).
function Get-SuperOpsActiveAlerts {
    $Query = @'
query getAlertList($input: ListInfoInput!) {
  getAlertList(input: $input) {
    alerts {
      alertId
      message
      description
      severity
      status
      createdTime
      asset { name }
    }
  }
}
'@

    try {
        $Result = Invoke-SuperOpsGraphQL -Query $Query -Variables @{ input = @{ page = 1; pageSize = 50 } }

        if ($Result.errors) {
            $ErrorText = ($Result.errors | ForEach-Object { $_.message }) -join " | "
            Write-LocalLog -Level "WARN" -Message "getAlertList lieferte GraphQL-Fehler: $ErrorText"
            return $null
        }

        $Alerts = @($Result.data.getAlertList.alerts)
        Write-LocalLog -Level "INFO" -Message "SuperOps Alerts geladen: $($Alerts.Count)"
        return $Alerts
    }
    catch {
        Write-ExceptionDetails -ErrorRecord $_ -Context "Get-SuperOpsActiveAlerts"
        return $null
    }
}

function Get-SeverityColor {
    param([string]$Severity)

    switch -Regex ($Severity) {
        '(?i)critical' { return "#e53935" }
        '(?i)high'     { return "#fb8c00" }
        '(?i)medium'   { return "#fdd835" }
        '(?i)low'      { return "#43a047" }
        default        { return "#9e9e9e" }
    }
}

function New-DashboardHtml {
    param(
        [object[]]$SuperOpsAlerts,
        [int]$RefreshSeconds
    )

    $GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $Rows = New-Object System.Text.StringBuilder
    if ($null -eq $SuperOpsAlerts) {
        [void]$Rows.Append('<div class="empty">SuperOps nicht erreichbar.</div>')
    }
    elseif ($SuperOpsAlerts.Count -eq 0) {
        [void]$Rows.Append('<div class="empty">Keine aktiven SuperOps-Alerts.</div>')
    }
    else {
        foreach ($Alert in $SuperOpsAlerts) {
            $Color = Get-SeverityColor -Severity $Alert.severity
            $AssetName = if ($Alert.asset.name) { $Alert.asset.name } else { "" }
            $Text = if ($Alert.description) { $Alert.description } else { $Alert.message }

            [void]$Rows.Append(@"
<div class="row">
  <span class="badge" style="background:$Color">$(ConvertTo-SafeHtml $Alert.severity)</span>
  <div class="row-text">
    <div class="row-title">$(ConvertTo-SafeHtml $AssetName)</div>
    <div class="row-message">$(ConvertTo-SafeHtml $Text)</div>
  </div>
</div>
"@)
        }
    }

    return @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="$RefreshSeconds">
<title>SuperOps Alerts</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { width: 100%; height: 100%; overflow: hidden; background: #121212; color: #eee; font-family: "Segoe UI", Arial, sans-serif; }
  .header { padding: 1.5vh 2vw; font-size: 2.8vh; font-weight: 600; background: #1c1c1c; border-bottom: 2px solid #333; }
  .body { height: calc(100vh - 8vh); overflow: hidden; padding: 1vh 2vw; }
  .row { display: flex; align-items: flex-start; gap: 1.2vw; padding: 1.1vh 0; border-bottom: 1px solid #2a2a2a; }
  .badge { flex: 0 0 auto; padding: 0.4vh 1vw; border-radius: 4px; font-size: 1.8vh; font-weight: 700; color: #111; white-space: nowrap; }
  .row-text { min-width: 0; }
  .row-title { font-size: 2.2vh; font-weight: 600; }
  .row-message { font-size: 2vh; color: #bbb; }
  .empty { padding: 3vh 0; font-size: 2.4vh; color: #777; }
  .footer { position: fixed; bottom: 0; right: 0; padding: 0.5vh 1vw; font-size: 1.4vh; color: #555; }
</style>
</head>
<body>
<div class="header">SuperOps Alerts</div>
<div class="body">$($Rows.ToString())</div>
<div class="footer">Aktualisiert: $GeneratedAt</div>
</body>
</html>
"@
}

# ==========================================================
# HAUPTLOGIK
# ==========================================================
try {
    $SuperOpsAlerts = Get-SuperOpsActiveAlerts

    if ($null -eq $SuperOpsAlerts) {
        Send-SuperOpsAlert -Severity "Critical" -Title "Dashboard-Generator: SuperOps nicht erreichbar" `
            -Message "Get-SuperOpsActiveAlerts ist fehlgeschlagen - die TV-Dashboard-Seite wird mit einem Hinweistext statt aktuellen Daten geschrieben." `
            -AssetName $env:COMPUTERNAME
    }

    $Html = New-DashboardHtml -SuperOpsAlerts $SuperOpsAlerts -RefreshSeconds $RefreshSeconds

    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null
    }

    # PS 5.1 kennt Set-Content -Encoding utf8NoBOM nicht (erst PS7+),
    # daher direkt ueber .NET schreiben (kein BOM, wie bereits in
    # Monitoring Nutanix Alerts.ps1 fuer denselben Zweck geloest).
    [System.IO.File]::WriteAllText($OutputFile, $Html, [System.Text.UTF8Encoding]::new($false))

    Write-LocalLog -Level "INFO" -Message "Dashboard-Seite geschrieben: $OutputFile"
    Write-LocalLog -Level "INFO" -Message "Dashboard-Generator regulaer beendet"
    Complete-Script -ExitCode 0
}
catch {
    Write-ExceptionDetails -ErrorRecord $_ -Context "Hauptlogik"
    Stop-Script -Step "Hauptlogik" -Message "Dashboard-Generator: Skriptfehler: $($_.Exception.Message)"
}
