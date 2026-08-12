#Requires -Version 5.1

# ==========================================================
# Test-SuperOpsAlertSchema.ps1
# Einmalig-Diagnosewerkzeug, DIREKT auf einem Server mit gueltiger
# credentials.xml ausfuehren (z.B. SV-OS-PRB-01 - dort wird die Datei
# von Update-DevolutionsCredentials im richtigen SYSTEM-Kontext gepflegt).
# Auf einer normalen Admin-Arbeitsstation schlaegt Get-Credentials mit
# einem DPAPI-Fehler fehl, wenn dort keine eigene, frische credentials.xml
# existiert (siehe CLAUDE.md, Abschnitt Verwaltung der Zugangsdaten).
# ==========================================================
# Autor    : GIO / Claude
# Version  : 1.0
# Datum    : 2026-08-12
#
# Zweck:
#   Fuer das TV-Dashboard (Raspberry Pi + grosser Bildschirm im Buero,
#   siehe geplantes Generate SuperOps PRTG Dashboard.ps1) wird eine
#   GraphQL-Abfrage benoetigt, die aktive SuperOps-Alerts MIT Volltext
#   liefert (nicht nur Zaehler wie im TV View Report). Die Bibliothek
#   kennt bisher nur die Mutation createAlert (Alert-Typ hat mindestens
#   message/severity/description/assetId/id, siehe
#   Ditzler-Powershell-Lib.psm1 Send-SuperOpsAlert) - eine Abfrage zum
#   AUFLISTEN bestehender Alerts wurde noch nie empirisch bestaetigt.
#
#   Dieses Skript:
#   1. Fragt per Introspection alle Query-Felder ab, deren Name "alert"
#      enthaelt (Gross-/Kleinschreibung egal).
#   2. Fragt per Introspection alle Felder des Typs "Alert" ab.
#   3. Versucht probeweise einen naheliegenden Aufruf (getAlertList,
#      analog zu getAssetList/getUserList) und gibt das Rohergebnis aus.
#
#   Ergebnis bitte in Generate SuperOps PRTG Dashboard.ps1 uebernehmen
#   (Funktion Get-SuperOpsActiveAlerts) - dort ist der aktuelle
#   Platzhalter klar als ZU VALIDIEREN markiert.
#
# Verhalten:
#   - Rein lesend, keine Aenderung in SuperOps.
# ==========================================================

$SuperOpsScriptDir = "C:\ProgramData\Superops\Scripts"
$LibPath           = Join-Path $SuperOpsScriptDir "Ditzler-Powershell-Lib.psm1"
$CredFile          = Join-Path $SuperOpsScriptDir "credentials.xml"

Import-Module $LibPath -Force -ErrorAction Stop
Initialize-WorkDir

$AllCreds = Get-Credentials -FileName $CredFile
Initialize-SuperOpsCreds -AllCreds $AllCreds

Write-Host "=== 1. Query-Felder mit 'alert' im Namen ===" -ForegroundColor Cyan

$IntrospectQueryFields = @'
query {
  __schema {
    queryType {
      fields {
        name
        args { name type { name kind ofType { name kind } } }
        type { name kind ofType { name kind } }
      }
    }
  }
}
'@

try {
    $Result = Invoke-SuperOpsGraphQL -Query $IntrospectQueryFields
    $AlertFields = $Result.data.__schema.queryType.fields | Where-Object { $_.name -match '(?i)alert' }

    if (-not $AlertFields) {
        Write-Host "Keine Query-Felder mit 'alert' im Namen gefunden." -ForegroundColor Yellow
    }
    else {
        foreach ($Field in $AlertFields) {
            $ArgsText = ($Field.args | ForEach-Object {
                $TypeName = if ($_.type.name) { $_.type.name } else { $_.type.ofType.name }
                "$($_.name): $TypeName"
            }) -join ", "
            Write-Host "$($Field.name)($ArgsText)" -ForegroundColor Green
        }
    }
}
catch {
    Write-Host "Introspection der Query-Felder fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 2. Felder des Typs 'Alert' ===" -ForegroundColor Cyan

$IntrospectAlertType = @'
query {
  __type(name: "Alert") {
    name
    fields {
      name
      type { name kind ofType { name kind } }
    }
  }
}
'@

try {
    $Result = Invoke-SuperOpsGraphQL -Query $IntrospectAlertType

    if (-not $Result.data.__type) {
        Write-Host "Typ 'Alert' nicht gefunden - evtl. anderer Typname (z.B. AlertResponse, MonitoringAlert)." -ForegroundColor Yellow
    }
    else {
        foreach ($Field in $Result.data.__type.fields) {
            $TypeName = if ($Field.type.name) { $Field.type.name } else { $Field.type.ofType.name }
            Write-Host "$($Field.name): $TypeName" -ForegroundColor Green
        }
    }
}
catch {
    Write-Host "Introspection des Typs 'Alert' fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 3. Probeweiser Aufruf getAlertList (Analogie zu getAssetList/getUserList) ===" -ForegroundColor Cyan

$ProbeQuery = @'
query getAlertList($input: ListInfoInput!) {
  getAlertList(input: $input) {
    alerts {
      alertId
      message
      description
      severity
      status
      createdTime
      asset { assetId name }
    }
  }
}
'@

try {
    $Result = Invoke-SuperOpsGraphQL -Query $ProbeQuery -Variables @{ input = @{ page = 1; pageSize = 5 } }

    if ($Result.errors) {
        Write-Host "getAlertList lieferte Fehler (das ist bei einer Ratequery normal):" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        Write-Host "getAlertList hat funktioniert! Rohergebnis:" -ForegroundColor Green
        $Result | ConvertTo-Json -Depth 10
    }
}
catch {
    Write-Host "Probeaufruf getAlertList fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`nFertig. Ergebnisse oben in Generate SuperOps PRTG Dashboard.ps1 (Get-SuperOpsActiveAlerts) uebernehmen." -ForegroundColor Cyan
