#Requires -Version 5.1

# ==========================================================
# Test-SuperOpsTicketSchema.ps1
# Einmalig-Diagnosewerkzeug, DIREKT auf einem Server mit gueltiger
# credentials.xml ausfuehren (siehe Test-SuperOpsAlertSchema.ps1 fuer
# Details zum DPAPI-Verhalten von credentials.xml).
#
# Kein SuperOps-Skript und laeuft auch nicht per Aufgabenplanung - reines
# Einmalig-Werkzeug, danach loeschbar. Braucht nur lesenden Zugriff auf
# Ditzler-Powershell-Lib.psm1/credentials.xml in C:\ProgramData\Superops\Scripts.
# ==========================================================
# Autor    : GIO / Claude
# Version  : 1.0
# Datum    : 2026-08-12
#
# Zweck:
#   Fuer das TV-Dashboard soll zusaetzlich zu den Alerts eine Ticket-
#   Statistikzeile dazukommen: Anzahl offener Tickets, Anzahl ueberfaelliger
#   Tickets, Anzahl nicht zugewiesener Tickets (mit Titeln) - analog zu den
#   Views "Open Tickets"/"Overdue Tickets"/"Unassigned Tickets" in der
#   SuperOps-Oberflaeche (GIO, 12.08.2026, per Screenshot bestaetigt: 36
#   offene, 8 ueberfaellige, 5 nicht zugewiesene Tickets zum Zeitpunkt des
#   Screenshots).
#
#   Die Bibliothek kennt bisher nur New-SuperOpsTicket (createTicket
#   Mutation) - keine Abfrage zum AUFLISTEN/ZAEHLEN bestehender Tickets
#   wurde je empirisch bestaetigt.
#
#   Bei insgesamt 1295 Tickets (siehe Screenshot "All Tickets") ist ein
#   client-seitiger Filter (alles laden, dann in PowerShell filtern - so
#   wie bei Get-SuperOpsActiveAlerts geloest) unpraktikabel. Dieses Skript
#   sucht deshalb gezielt nach serverseitigen Filtermoeglichkeiten:
#   1. Query-Felder, deren Name "ticket" ODER "assign" ODER "overdue"
#      enthaelt (Gross-/Kleinschreibung egal) - falls es dedizierte
#      Zaehl-/View-Felder gibt (z.B. getTicketCount), tauchen sie hier auf.
#   2. Felder des Typs "Ticket" (Titel/Subject, Status, Technician,
#      Faelligkeit/Resolution Timer, Prioritized ID).
#   3. Eingabefelder ("inputFields") einiger naheliegender Filter-Typnamen
#      (TicketListInput, TicketFilterInput, ListInfoInput) - falls einer
#      davon existiert, zeigt das, ob nach Status/Technician/Faelligkeit
#      serverseitig gefiltert werden kann.
#   4. Probeweiser Aufruf getTicketList mit kleiner Seitengroesse.
#
#   Ergebnis bitte in Generate SuperOps Alert Dashboard.ps1 uebernehmen
#   (neue Funktion, analog zu Get-SuperOpsActiveAlerts).
#
# Verhalten:
#   - Rein lesend, keine Aenderung in SuperOps.
# ==========================================================

try { Clear-Host } catch { }

$SuperOpsScriptDir = "C:\ProgramData\Superops\Scripts"
$LibPath           = Join-Path $SuperOpsScriptDir "Ditzler-Powershell-Lib.psm1"
$CredFile          = Join-Path $SuperOpsScriptDir "credentials.xml"

Import-Module $LibPath -Force -ErrorAction Stop
Initialize-WorkDir

$AllCreds = Get-Credentials -FileName $CredFile
Initialize-SuperOpsCreds -AllCreds $AllCreds

Write-Host "=== 1. Query-Felder mit 'ticket'/'assign'/'overdue' im Namen ===" -ForegroundColor Cyan

$IntrospectQueryFields = @'
query {
  __schema {
    queryType {
      fields {
        name
        args { name type { name kind ofType { name kind } } }
      }
    }
  }
}
'@

try {
    $Result = Invoke-SuperOpsGraphQL -Query $IntrospectQueryFields
    $TicketFields = $Result.data.__schema.queryType.fields | Where-Object { $_.name -match '(?i)ticket|assign|overdue' }

    if (-not $TicketFields) {
        Write-Host "Keine passenden Query-Felder gefunden." -ForegroundColor Yellow
    }
    else {
        foreach ($Field in $TicketFields) {
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

# Die volle Introspection (mit type/ofType-Verschachtelung) schlaegt bei
# Invoke-SuperOpsGraphQL manchmal mit "No parameterless constructor..."
# fehl (bestaetigt bereits bei Alert/Ticket/ListInfoInput - vermutlich ein
# Deserialisierungs-Sonderfall in der Bibliothek, kein API-Problem). Als
# Fallback hier eine minimale Variante, die nur die Feldnamen abfragt
# (ohne Typinfo) - deutlich weniger verschachtelt, faellt seltener um.
function Get-TypeFieldNamesOnly {
    param([string]$TypeName, [switch]$IsInputType)

    $SelectionField = if ($IsInputType) { "inputFields" } else { "fields" }
    $Query = @"
query {
  __type(name: "$TypeName") {
    name
    $SelectionField { name }
  }
}
"@
    try {
        $Result = Invoke-SuperOpsGraphQL -Query $Query
        if ($Result.data.__type) {
            return @($Result.data.__type.$SelectionField | ForEach-Object { $_.name })
        }
    }
    catch {
        Write-Host "  Auch die minimale Introspection von $TypeName ist fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
    }
    return @()
}

Write-Host "`n=== 2. Felder des Typs 'Ticket' ===" -ForegroundColor Cyan

$IntrospectTicketType = @'
query {
  __type(name: "Ticket") {
    name
    fields {
      name
      type { name kind ofType { name kind } }
    }
  }
}
'@

try {
    $Result = Invoke-SuperOpsGraphQL -Query $IntrospectTicketType

    if (-not $Result.data.__type) {
        Write-Host "Typ 'Ticket' nicht gefunden - evtl. anderer Typname." -ForegroundColor Yellow
    }
    else {
        foreach ($Field in $Result.data.__type.fields) {
            $TypeName = if ($Field.type.name) { $Field.type.name } else { $Field.type.ofType.name }
            Write-Host "$($Field.name): $TypeName" -ForegroundColor Green
        }
    }
}
catch {
    Write-Host "Introspection des Typs 'Ticket' fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Versuche minimale Introspection (nur Feldnamen, ohne Typinfo)..." -ForegroundColor Yellow
    $Names = Get-TypeFieldNamesOnly -TypeName "Ticket"
    if ($Names) { Write-Host ($Names -join ", ") -ForegroundColor Green }
}

Write-Host "`n=== 3. Eingabefelder moeglicher Filter-Typen ===" -ForegroundColor Cyan

foreach ($InputTypeName in @("TicketListInput", "TicketFilterInput", "ListInfoInput", "TicketInput")) {
    $IntrospectInputType = @"
query {
  __type(name: "$InputTypeName") {
    name
    inputFields { name type { name kind ofType { name kind } } }
  }
}
"@
    try {
        $Result = Invoke-SuperOpsGraphQL -Query $IntrospectInputType
        if ($Result.data.__type) {
            Write-Host "--- $InputTypeName ---" -ForegroundColor Yellow
            foreach ($Field in $Result.data.__type.inputFields) {
                $TypeName = if ($Field.type.name) { $Field.type.name } else { $Field.type.ofType.name }
                Write-Host "  $($Field.name): $TypeName" -ForegroundColor Green
            }
        }
    }
    catch {
        Write-Host "Introspection von $InputTypeName fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Versuche minimale Introspection (nur Feldnamen, ohne Typinfo)..." -ForegroundColor Yellow
        $Names = Get-TypeFieldNamesOnly -TypeName $InputTypeName -IsInputType
        if ($Names) { Write-Host "--- $InputTypeName (nur Namen) ---`n$($Names -join ', ')" -ForegroundColor Green }
    }
}

Write-Host "`n=== 4. Probeweiser Aufruf getTicketList (kleine Seite) ===" -ForegroundColor Cyan

$ProbeQuery = @'
query getTicketList($input: ListInfoInput!) {
  getTicketList(input: $input) {
    tickets {
      ticketId
      displayId
      subject
      status
      technician
      requester
      createdTime
      updatedTime
      priority
      dueBy
      resolutionDeadline
      isOverdue
      slaBreached
      resolutionStatus
      timer
      ticketTimer
      breached
      escalated
      slaStatus
      responseDueDate
      resolutionTime
    }
  }
}
'@

try {
    $Result = Invoke-SuperOpsGraphQL -Query $ProbeQuery -Variables @{ input = @{ page = 1; pageSize = 5 } }

    if ($Result.errors) {
        Write-Host "getTicketList lieferte Fehler (das ist bei einer Ratequery normal):" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        Write-Host "getTicketList hat funktioniert! Rohergebnis:" -ForegroundColor Green
        $Result | ConvertTo-Json -Depth 10
    }
}
catch {
    Write-Host "Probeaufruf getTicketList fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 5. Moegliche Filterfelder in ListInfoInput (oeffentliche IT-API) ===" -ForegroundColor Cyan
Write-Host "Live am 12.08.2026 bestaetigt: 'view' existiert NICHT in der oeffentlichen API (nur" -ForegroundColor Yellow
Write-Host "in der internen App-API von support.ditzler.ch). Testet hier mehrere Kandidaten auf" -ForegroundColor Yellow
Write-Host "einmal - GraphQL meldet unbekannte Eingabefelder pro Aufruf (evtl. nur das erste," -ForegroundColor Yellow
Write-Host "dann eher einzeln testen)." -ForegroundColor Yellow

$FilterProbeQuery = @'
query getTicketList($input: ListInfoInput!) {
  getTicketList(input: $input) {
    listInfo { totalCount }
  }
}
'@

$CandidateInput = @{
    page          = 1
    pageSize      = 1
    condition     = $null
}

try {
    $Result = Invoke-SuperOpsGraphQL -Query $FilterProbeQuery -Variables @{ input = $CandidateInput }

    if ($Result.errors) {
        Write-Host "Fehler (zeigt, welche Kandidaten-Feldnamen ungueltig sind):" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        Write-Host "Alle Kandidatenfelder wurden akzeptiert (ungewoehnlich - totalCount pruefen):" -ForegroundColor Green
        $Result | ConvertTo-Json -Depth 10
    }
}
catch {
    Write-Host "Filterfeld-Probe fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 6. Form von 'condition' ermitteln (Versuch A: einfacher String) ===" -ForegroundColor Cyan

try {
    $Result = Invoke-SuperOpsGraphQL -Query $FilterProbeQuery -Variables @{ input = @{ page = 1; pageSize = 1; condition = "status = 'Open'" } }
    if ($Result.errors) {
        Write-Host "Fehler (zeigt evtl. den erwarteten Typnamen):" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        Write-Host "String wurde akzeptiert! totalCount:" -ForegroundColor Green
        $Result | ConvertTo-Json -Depth 10
    }
}
catch {
    Write-Host "Fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 6b. Form von 'condition' ermitteln (Versuch B: strukturiertes Objekt) ===" -ForegroundColor Cyan

try {
    $ConditionObject = @{
        attribute = "status"
        operator  = "EQUALS"
        value     = "Open"
    }
    $Result = Invoke-SuperOpsGraphQL -Query $FilterProbeQuery -Variables @{ input = @{ page = 1; pageSize = 1; condition = $ConditionObject } }
    if ($Result.errors) {
        Write-Host "Fehler (zeigt evtl. den erwarteten Typnamen/Feldnamen):" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        Write-Host "Objekt wurde akzeptiert! totalCount:" -ForegroundColor Green
        $Result | ConvertTo-Json -Depth 10
    }
}
catch {
    Write-Host "Fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 7. Maximale pageSize testen (condition-Filter aufgegeben, client-seitig geplant) ===" -ForegroundColor Cyan
Write-Host "Ziel: alle ca. 1295 Tickets in moeglichst wenigen Aufrufen laden, dann in PowerShell" -ForegroundColor Yellow
Write-Host "nach status/technician filtern (beides bestaetigt gueltige Ticket-Felder)." -ForegroundColor Yellow

$FullProbeQuery = @'
query getTicketList($input: ListInfoInput!) {
  getTicketList(input: $input) {
    listInfo { totalCount hasMore pageSize page }
    tickets { ticketId status technician }
  }
}
'@

try {
    $Result = Invoke-SuperOpsGraphQL -Query $FullProbeQuery -Variables @{ input = @{ page = 1; pageSize = 2000 } }
    if ($Result.errors) {
        Write-Host "Fehler bei pageSize=2000 mit tickets-Liste:" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        $Tickets = @($Result.data.getTicketList.tickets)
        Write-Host "pageSize=2000: listInfo=$($Result.data.getTicketList.listInfo | ConvertTo-Json -Compress), tatsaechlich zurueckgegebene Tickets=$($Tickets.Count)" -ForegroundColor Green
        $OpenCount = @($Tickets | Where-Object { $_.status -ne "Closed" -and $_.status -ne "Resolved" }).Count
        $UnassignedCount = @($Tickets | Where-Object { -not $_.technician }).Count
        Write-Host "Client-seitig gefiltert: nicht Closed/Resolved=$OpenCount, ohne technician=$UnassignedCount" -ForegroundColor Green
        Write-Host "Vorkommende Status-Werte: $((@($Tickets | Select-Object -ExpandProperty status -Unique)) -join ', ')" -ForegroundColor Green
    }
}
catch {
    Write-Host "Fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 8. Feld 'sort' testen + Tickets nach createdTime DESC (neueste zuerst) ===" -ForegroundColor Cyan
Write-Host "Bisher nie isoliert bestaetigt, ob 'sort' auf der oeffentlichen API existiert." -ForegroundColor Yellow

try {
    $SortInput = @{
        page     = 1
        pageSize = 100
        sort     = @(@{ attribute = "createdTime"; order = "DESC" })
    }
    $Result = Invoke-SuperOpsGraphQL -Query $FullProbeQuery -Variables @{ input = $SortInput }
    if ($Result.errors) {
        Write-Host "Fehler (zeigt, ob 'sort' oder seine Unterfelder ungueltig sind):" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        $Tickets = @($Result.data.getTicketList.tickets)
        Write-Host "sort=createdTime DESC hat funktioniert. Tickets=$($Tickets.Count)" -ForegroundColor Green
        $OpenCount = @($Tickets | Where-Object { $_.status -ne "Closed" -and $_.status -ne "Resolved" }).Count
        $UnassignedCount = @($Tickets | Where-Object { -not $_.technician }).Count
        Write-Host "Client-seitig gefiltert (in diesen 100 neuesten): nicht Closed/Resolved=$OpenCount, ohne technician=$UnassignedCount" -ForegroundColor Green
        Write-Host "Vorkommende Status-Werte: $((@($Tickets | Select-Object -ExpandProperty status -Unique)) -join ', ')" -ForegroundColor Green
    }
}
catch {
    Write-Host "Fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 9. Echte 'condition'-Struktur aus dem Browser-Mitschnitt testen ===" -ForegroundColor Cyan
Write-Host "Struktur (support.ditzler.ch, interne API): verschachtelter Bedingungsbaum mit" -ForegroundColor Yellow
Write-Host "joinOperator/operands/attribute/operator/value. Testet hier, ob dieselbe Struktur" -ForegroundColor Yellow
Write-Host "auch von der oeffentlichen IT-API akzeptiert wird (gleicher Filter-Mechanismus?)." -ForegroundColor Yellow

try {
    $RealCondition = @{
        joinOperator = "AND"
        operands     = @(
            @{
                joinOperator = "AND"
                operands     = @(
                    @{
                        value     = "Open"
                        operator  = "is"
                        attribute = "status"
                    }
                )
            }
        )
    }
    $TicketInput = @{
        page      = 1
        pageSize  = 100
        sort      = @(@{ attribute = "createdTime"; order = "DESC" })
        condition = $RealCondition
    }
    $Result = Invoke-SuperOpsGraphQL -Query $FullProbeQuery -Variables @{ input = $TicketInput }

    if ($Result.errors) {
        Write-Host "Fehler:" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        $Tickets = @($Result.data.getTicketList.tickets)
        Write-Host "ECHTE CONDITION HAT FUNKTIONIERT!" -ForegroundColor Green
        Write-Host "listInfo: $($Result.data.getTicketList.listInfo | ConvertTo-Json -Compress)" -ForegroundColor Green
        Write-Host "Zurueckgegebene Tickets: $($Tickets.Count)" -ForegroundColor Green
        Write-Host "Vorkommende Status-Werte: $((@($Tickets | Select-Object -ExpandProperty status -Unique)) -join ', ')" -ForegroundColor Green
    }
}
catch {
    Write-Host "Fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 10. status 'isNot' Closed UND 'isNot' Resolved (soll 36 ergeben) ===" -ForegroundColor Cyan

try {
    $OpenCondition = @{
        joinOperator = "AND"
        operands     = @(
            @{ joinOperator = "AND"; operands = @(@{ value = "Closed"; operator = "isNot"; attribute = "status" }) }
            @{ joinOperator = "AND"; operands = @(@{ value = "Resolved"; operator = "isNot"; attribute = "status" }) }
        )
    }
    $TicketInput = @{ page = 1; pageSize = 100; sort = @(@{ attribute = "createdTime"; order = "DESC" }); condition = $OpenCondition }
    $Result = Invoke-SuperOpsGraphQL -Query $FullProbeQuery -Variables @{ input = $TicketInput }

    if ($Result.errors) {
        Write-Host "Fehler:" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        Write-Host "totalCount: $($Result.data.getTicketList.listInfo.totalCount) (Ziel: 36)" -ForegroundColor Green
    }
}
catch {
    Write-Host "Fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n=== 11. Feld 'resolutionViolated' als Ticket-Auswahlfeld + als condition testen ===" -ForegroundColor Cyan

$ResolutionViolatedFieldQuery = @'
query getTicketList($input: ListInfoInput!) {
  getTicketList(input: $input) {
    listInfo { totalCount }
    tickets { displayId status resolutionViolated }
  }
}
'@

try {
    $Result = Invoke-SuperOpsGraphQL -Query $ResolutionViolatedFieldQuery -Variables @{ input = @{ page = 1; pageSize = 5 } }
    if ($Result.errors) {
        Write-Host "Fehler (Feld 'resolutionViolated' evtl. ungueltig):" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        Write-Host "Feld 'resolutionViolated' ist gueltig! totalCount=$($Result.data.getTicketList.listInfo.totalCount), Tickets zurueckgegeben=$(@($Result.data.getTicketList.tickets).Count)" -ForegroundColor Green
        $Result.data.getTicketList.tickets | ForEach-Object { Write-Host "  $($_.displayId): status=$($_.status), resolutionViolated=$($_.resolutionViolated)" }
    }
}
catch {
    Write-Host "Fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

try {
    $OverdueCondition = @{
        joinOperator = "AND"
        operands     = @(@{ joinOperator = "AND"; operands = @(@{ value = $true; operator = "is"; attribute = "resolutionViolated" }) })
    }
    $TicketInput = @{ page = 1; pageSize = 5; condition = $OverdueCondition }
    $Result = Invoke-SuperOpsGraphQL -Query $FullProbeQuery -Variables @{ input = $TicketInput }
    if ($Result.errors) {
        Write-Host "condition mit resolutionViolated Fehler:" -ForegroundColor Yellow
        $Result.errors | ForEach-Object { Write-Host "  $($_.message)" -ForegroundColor Yellow }
    }
    else {
        Write-Host "condition mit resolutionViolated=true totalCount: $($Result.data.getTicketList.listInfo.totalCount) (Ziel: 8)" -ForegroundColor Green
    }
}
catch {
    Write-Host "Fehlgeschlagen: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`nFertig. Ergebnisse in Generate SuperOps Alert Dashboard.ps1 uebernehmen (neue Funktion fuer Ticket-Statistiken)." -ForegroundColor Cyan
