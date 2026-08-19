#Requires -Version 5.1

# ==========================================================
# Skript: Generate SuperOps Alert Dashboard
# Autor: GIO / Claude
# Version: 6.3
# Datum: 2026-08-19
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
#   Liegt deshalb bewusst NICHT unter C:\ProgramData\Superops\Scripts (das
#   ist SuperOps' eigenes Verzeichnis fuer von SuperOps ausgefuehrte/
#   verwaltete Skripte), sondern unter C:\Service\Scripts\DashboardSuperops
#   (eigener Unterordner, C:\Service\Scripts ist der uebliche Ablageort fuer
#   Skripte, die per Windows-Aufgabenplanung laufen, siehe GIO, 12.08.2026).
#   Importiert die Bibliothek/Zugangsdaten nur lesend aus dem SuperOps-
#   Verzeichnis, muss aber nicht dort liegen.
#
#   Muss auf einem Server mit gueltiger credentials.xml laufen (SV-OS-PRB-01,
#   nicht auf dem Raspberry Pi - der bekommt nie Zugangsdaten zu sehen,
#   siehe CLAUDE.md "Verwaltung der Zugangsdaten").
#
# Schema bestaetigt (12.08.2026, per Test-SuperOpsAlertSchema.ps1 auf SV-OS-PRB-01):
#   Feld heisst "id" (nicht "alertId"), "asset" ist vom Typ JSON (Skalar, Struktur nicht
#   bestaetigt - siehe Get-AssetDisplayName fuer die defensive Auswertung). Sobald echte
#   Alerts live beobachtet wurden, ggf. Get-AssetDisplayName auf das tatsaechliche Feld
#   vereinfachen statt der Fallback-Heuristik.
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
#   3.0 (2026-08-12): GraphQL-Schema gegen die echte API bestaetigt (Test-
#                      SuperOpsAlertSchema.ps1 auf SV-OS-PRB-01 ausgefuehrt):
#                      "alertId" -> "id", "asset { name }" (ungueltig, Typ
#                      JSON ist ein Skalar) -> "asset" + defensive
#                      Get-AssetDisplayName. Zusaetzlich client-seitiger
#                      Filter auf unresolved Alerts (resolvedTime leer),
#                      da kein dokumentierter Status-Filter in ListInfoInput
#                      gefunden wurde.
#   3.1 (2026-08-12): Live-Test zeigte 8x denselben Alert-Inhalt fuer
#                      denselben Dienst (SuperOps legt bei wiederkehrenden
#                      Zustaenden neue Alert-Datensaetze an statt einen
#                      bestehenden zu aktualisieren). Dedup nach (Asset,
#                      Severity, Text) hinzugefuegt, mit "xN"-Badge bei
#                      mehreren Vorkommen.
#   3.2 (2026-08-12): Layout auf Wunsch von GIO ("pas tres lisible") von
#                      Textbloecken auf eine kompakte Tabelle umgestellt:
#                      Anzahl | Severity | Device | Message (auf 30
#                      Zeichen gekuerzt, mit "...").
#   4.0 (2026-08-12): Ticket-Statistikzeile hinzugefuegt (offene/ueberfaellige
#                      Tickets als Zahl, nicht zugewiesene Tickets als Zahl +
#                      Titelliste). View-IDs (Open=13, Overdue=9007) per
#                      Browser-DevTools aus der SuperOps-Oberflaeche
#                      mitgeschnitten. "Unassigned Tickets" ist keine eigene
#                      View, sondern die Open-Tickets-Liste gefiltert auf
#                      technician == null (per Live-Vergleich bestaetigt).
#   4.1 (2026-08-12): Zwei Live-Bugs behoben (SV-OS-PRB-01, echter Lauf):
#                      (1) Die DevTools-Mitschnitte stammten von der INTERNEN
#                      GraphQL-API der Web-Oberflaeche (support.ditzler.ch),
#                      nicht von der oeffentlichen IT-API, die Invoke-
#                      SuperOpsGraphQL mit dem API-Key anspricht - Argument
#                      "listInfo" existiert dort nicht, richtig ist "input"
#                      (wie bei getAlertList), und "technician" ist wie
#                      "asset" ein JSON-Skalar, kein Objekt mit { name }.
#                      (2) Bei 0 unresolved Alerts loeste ein PowerShell-
#                      Standardverhalten (leeres Array wird beim Verlassen
#                      einer Funktion zu $null aufgeloest) faelschlich den
#                      "SuperOps nicht erreichbar"-Zweig samt unnoetigem
#                      kritischem SuperOps-Alert aus - behoben mit dem
#                      unaeren Komma-Operator ("return ,@(...)").
#   4.2 (2026-08-12): Das "view"-Feld (id 13/9007) existiert nicht in der
#                      oeffentlichen IT-API - live per Fehlermeldung bestaetigt
#                      ("field name 'view' that is not defined"). Per
#                      Ausschlussverfahren (GraphQL meldet bei ListInfoInput
#                      jeweils nur EIN ungueltiges Feld pro Aufruf, daher
#                      mehrere Testrunden) ermittelt: "condition" ist das
#                      einzige echte Filterfeld, Typ RuleConditionInput
#                      (verschachtelter Bedingungsbaum). Dessen Syntax stammte
#                      aus einem echten Browser-Mitschnitt eines manuell in der
#                      SuperOps-UI gesetzten Filters (nicht geraten). Get-
#                      SuperOpsTicketList nimmt jetzt -Condition statt -ViewId.
#                      Open Tickets: status isNot Closed AND isNot Resolved
#                      (37 vs. Ziel 36, Differenz durch Zeitversatz). Overdue
#                      Tickets: resolutionViolated is true (exakt 8, exakte
#                      Uebereinstimmung). Wichtig dabei gelernt: Werte muessen
#                      typkorrekt sein (PowerShell $true, nicht String "true"),
#                      sonst filtert die API praktisch nichts heraus.
#   4.3 (2026-08-12): Live-Test zeigte "Nicht zugewiesen: 0" trotz frueher
#                      beobachteter unassigned Tickets. Per rohem HTTP-Response-
#                      Vergleich (Invoke-WebRequest statt Invoke-RestMethod)
#                      nachgewiesen: der Server liefert ein LEERES "tickets"-
#                      Array zurueck, wenn NUR displayId/subject/technician
#                      abgefragt werden - totalCount bleibt dabei korrekt. Das
#                      hat NICHTS mit "condition" oder der Ergebnisgroesse zu
#                      tun (mehrere falsche Spuren verfolgt: isNot vs. is,
#                      1 vs. 2 Operanden, PS 5.1 vs. PS7 - keine davon war die
#                      Ursache). Fix: zusaetzlich "ticketId" und "status"
#                      mitabfragen (ungenutzt, aber noetig, damit der Server
#                      ueberhaupt Daten liefert) - siehe Get-SuperOpsTicketList.
#                      Nach dem Fix: totalCount und tickets.Count stimmen
#                      exakt ueberein (38/38), 7 nicht zugewiesene Tickets mit
#                      echten Titeln bestaetigt.
#   5.0 (2026-08-12): Auf Wunsch von GIO die 3-Zahlen-Statistikzeile durch eine
#                      Tabelle pro Techniker ersetzt (Techniker | Offene Tickets |
#                      Ueberfaellig), analog zum nativen SuperOps-Report "Tickets
#                      nach Mitarbeitenden". Techniker werden dynamisch aus den
#                      tatsaechlich vorkommenden "technician"-Werten ermittelt
#                      (kein hartcodiertes Namensarray, siehe Get-TechnicianStats)
#                      - neue Techniker tauchen automatisch auf. "Overdue Tickets"
#                      wird jetzt mit PageSize=100 (statt 1) abgefragt, da die
#                      volle Liste fuer die Aufschluesselung gebraucht wird, nicht
#                      nur der Zaehler. Die Titelliste der nicht zugewiesenen
#                      Tickets bleibt unveraendert unter der Tabelle.
#   6.0 (2026-08-12): Architekturwechsel auf Wunsch von GIO: PRTG-Map als
#                      <iframe> in DIESELBE Seite eingebettet (neuer Parameter
#                      -PrtgMapUrl), statt eines zweiten separaten Chromium-
#                      Kiosk-Fensters auf dem Pi. Grund: PRTGs mapshow.htm ist
#                      von Paessler explizit fuers Einbetten gedacht (kein
#                      X-Frame-Options-Problem zu erwarten), und ein einziges
#                      Kiosk-Fenster erspart dem Pi das fehleranfaellige
#                      X11-Fenstertuiling (siehe setup-kiosk.sh v3.0 - deutlich
#                      simpler, keine Fensterpositionierung mehr noetig). Seite
#                      ist jetzt zweispaltig (body: flex-direction row) -
#                      PRTG-Pane links, bisheriger Inhalt (Header/Techniker-
#                      Tabelle/Unassigned/Alerts) rechts in einer neuen
#                      .superops-pane. Bei leerem -PrtgMapUrl erscheint ein
#                      Platzhalter-Hinweis statt eines kaputten iframes.
#   6.1 (2026-08-12): Echte PRTG-Map-URL von GIO eingetragen (passend fuer
#                      das Split-Layout auf 960x1080 px erstellt, id=2914).
#   6.2 (2026-08-12): Layout auf Wunsch von GIO von nebeneinander (links/
#                      rechts) auf uebereinander umgestellt: SuperOps oben
#                      (2/3 der Hoehe), PRTG unten (1/3). Bei 1920x1080
#                      entspricht das ca. 1920x360 px fuer die PRTG-Map -
#                      muss dafuer neu erstellt werden (bisherige Map war
#                      fuer 960x1080 gedacht, siehe v6.1). Footer (Zeitstempel)
#                      von "position: fixed" (haette sonst die PRTG-Flaeche
#                      unten rechts ueberlappt) auf normalen Fluss am Ende
#                      von .superops-pane umgestellt.
#   6.3 (2026-08-19): Reihenfolge innerhalb .superops-pane auf Wunsch von GIO
#                      geaendert: Alerts zuerst (bisher zuletzt), danach nicht
#                      zugewiesene Tickets (Anzahl + Titelliste), danach die
#                      Techniker-Tabelle (bisher zuerst als $StatsBarHtml direkt
#                      unter dem Header). Reine HTML-Reihenfolge im body-String
#                      von New-DashboardHtml, keine Aenderung an den Daten/
#                      Abfragen/CSS-Klassen selbst.
# ==========================================================

param(
    [int]$RefreshSeconds = 60,
    [switch]$DebugMode,

    # Native PRTG-Map-Ansicht (mapshow.htm), als <iframe> in dieselbe Seite
    # eingebettet - seit v6.0 (siehe Aenderungsverlauf) statt eines zweiten
    # Chromium-Kiosk-Fensters auf dem Pi. Map von GIO passend fuer das
    # Split-Layout auf 960x1080 px erstellt (linke Haelfte eines
    # 1920x1080-Bildschirms). Leer lassen zeigt einen Platzhalter-Hinweis
    # statt eines kaputten iframes.
    [string]$PrtgMapUrl = "https://sv-os-prtg-01.ditzlernet.local/public/mapshow.htm?id=2914&mapid=9135FB6C-9FE1-4A07-BDB3-3B575603DFF4"
)

# ------------------ PFADE ----------------------
# Bibliothek/Zugangsdaten gehoeren SuperOps (nur lesend genutzt) - liegen
# und bleiben deshalb im SuperOps-Verzeichnis, unabhaengig davon, wo dieses
# Skript selbst liegt.
$SuperOpsScriptDir = "C:\ProgramData\Superops\Scripts"
$LibPath           = Join-Path $SuperOpsScriptDir "Ditzler-Powershell-Lib.psm1"
$CredFile          = Join-Path $SuperOpsScriptDir "credentials.xml"

# Zielordner fuer die generierte Seite - physischer Pfad der IIS-Anwendung
# "DashboardSuperops" auf SV-OS-PRB-01 (siehe CLAUDE.md, Abschnitt
# TV-Dashboard). Wird hier NICHT automatisch angelegt/konfiguriert.
$OutputDir  = "D:\inetpub\wwwroot\DashboardSuperops"
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

# Schema per Introspection bestaetigt (Test-SuperOpsAlertSchema.ps1, 12.08.2026 auf
# SV-OS-PRB-01): Feld heisst "id" (nicht "alertId"), "asset" ist vom Typ JSON (Skalar - keine
# GraphQL-Sub-Selektion moeglich, daher als einfaches Feld abgefragt und in PowerShell defensiv
# ausgewertet, siehe New-DashboardHtml). "resolvedTime" gibt es zusaetzlich - wird unten genutzt,
# um aufgeloeste Alerts client-seitig herauszufiltern (ListInfoInput bietet laut Introspection
# keinen dokumentierten Status-Filter).
function Get-SuperOpsActiveAlerts {
    $Query = @'
query getAlertList($input: ListInfoInput!) {
  getAlertList(input: $input) {
    alerts {
      id
      message
      description
      severity
      status
      createdTime
      resolvedTime
      asset
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

        $Alerts = @($Result.data.getAlertList.alerts) | Where-Object { [string]::IsNullOrEmpty($_.resolvedTime) }
        Write-LocalLog -Level "INFO" -Message "SuperOps Alerts geladen (unresolved): $($Alerts.Count)"

        # Live am 12.08.2026 beobachtet (0 unresolved Alerts): PowerShell "rollt"
        # ein leeres Array beim Verlassen einer Funktion ueber den Ausgabestrom
        # automatisch auf - "return @()" liefert beim Aufrufer $null statt eines
        # leeren Arrays (Standard-PowerShell-Verhalten, nicht auf diesen Fall
        # beschraenkt). Dadurch loeste die Hauptlogik-Pruefung "$null -eq
        # $SuperOpsAlerts" faelschlich den "SuperOps nicht erreichbar"-Zweig aus
        # (inkl. unnoetigem kritischen SuperOps-Alert), obwohl der Abruf simply
        # 0 Ergebnisse hatte. Fix: der unaere Komma-Operator "return ,@(...)"
        # zwingt PowerShell, den Rueckgabewert als EIN Array-Objekt zu behandeln
        # statt ihn aufzuloesen - siehe auch der finale return unten.
        if ($Alerts.Count -eq 0) {
            return ,@()
        }

        # Live am 12.08.2026 beobachtet: SuperOps legt fuer denselben wiederkehrenden Zustand
        # (z.B. ein Dienst, der bei jedem Check-Intervall erneut als fehlerhaft gemeldet wird)
        # mehrere separate Alert-Datensaetze mit identischem Inhalt an, statt einen bestehenden
        # zu aktualisieren/occurrenceCount hochzuzaehlen. Ohne Dedup wuerde die TV-Seite dieselbe
        # Meldung x-mal untereinander zeigen. Nach (Asset, Severity, Text) gruppieren, den
        # neuesten Datensatz je Gruppe behalten und die Anzahl als Badge anzeigen.
        $Groups = $Alerts | Group-Object -Property {
            $Text = if ($_.description) { $_.description } else { $_.message }
            "$($_.asset | ConvertTo-Json -Compress -Depth 3)|$($_.severity)|$Text"
        }

        $Deduped = foreach ($Group in $Groups) {
            $Latest = $Group.Group | Sort-Object -Property createdTime -Descending | Select-Object -First 1
            $Latest | Add-Member -NotePropertyName "OccurrenceCount" -NotePropertyValue $Group.Count -Force -PassThru
        }

        return ,@($Deduped)
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

# "asset" ist laut Schema vom Typ JSON (beliebiger Skalar, keine feste Struktur bestaetigt -
# siehe Get-SuperOpsActiveAlerts). Defensiv auswerten: haeufige Feldnamen probieren, sonst als
# Text darstellen, sonst leer. Sobald echte Alerts live beobachtet wurden, ggf. auf das
# tatsaechliche Feld vereinfachen.
function Get-AssetDisplayName {
    param($Asset)

    if ($null -eq $Asset) { return "" }
    if ($Asset -is [string]) { return $Asset }
    foreach ($PropName in @("name", "assetName", "displayName", "hostname")) {
        if ($Asset.PSObject.Properties.Name -contains $PropName -and $Asset.$PropName) {
            return [string]$Asset.$PropName
        }
    }
    return ($Asset | ConvertTo-Json -Compress -Depth 3)
}

function Get-TruncatedText {
    param([string]$Text, [int]$MaxLength = 30)

    if ([string]::IsNullOrEmpty($Text)) { return "" }
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, $MaxLength).TrimEnd() + "..."
}

# Filtermechanismus per Live-Test auf SV-OS-PRB-01 am 12.08.2026 ermittelt (siehe
# CLAUDE.md fuer die volle Geschichte - View-IDs aus dem Browser-Mitschnitt funktionierten
# NICHT auf der oeffentlichen IT-API, "view" existiert dort nicht in ListInfoInput).
# Der tatsaechlich funktionierende Mechanismus ist "condition" (Typ RuleConditionInput,
# per Fehlermeldung bestaetigt, nicht per Introspection): ein verschachtelter
# Bedingungsbaum mit joinOperator/operands/attribute/operator/value. WICHTIG: Werte
# muessen typkorrekt sein (z.B. $true als PowerShell-Bool, nicht "true" als String -
# sonst matcht der Filter fast alles statt exakt zu filtern, live beobachtet).
#   - Open Tickets: status ist weder "Closed" noch "Resolved" -> 37 (Ziel It. GIOs
#     Screenshot: 36 - Differenz durch neu erstelltes Ticket zwischen Messung und Test,
#     kein Bug).
#   - Overdue Tickets: resolutionViolated ist true -> 8 (exakte Uebereinstimmung mit
#     GIOs Screenshot).
# "Unassigned Tickets" ist keine eigene Bedingung, sondern die Open-Tickets-Liste
# client-seitig auf technician == null gefiltert (identisch mit den 5 Tickets aus der
# SuperOps-UI-Ansicht "Unassigned Tickets", per Live-Vergleich bestaetigt).
$Script:OpenTicketsCondition = @{
    joinOperator = "AND"
    operands     = @(
        @{ joinOperator = "AND"; operands = @(@{ value = "Closed"; operator = "isNot"; attribute = "status" }) }
        @{ joinOperator = "AND"; operands = @(@{ value = "Resolved"; operator = "isNot"; attribute = "status" }) }
    )
}
$Script:OverdueTicketsCondition = @{
    joinOperator = "AND"
    operands     = @(
        @{ joinOperator = "AND"; operands = @(@{ value = $true; operator = "is"; attribute = "resolutionViolated" }) }
    )
}

function Get-SuperOpsTicketList {
    param(
        [hashtable]$Condition,
        [int]$PageSize = 100
    )

    # WICHTIG (12.08.2026, live auf SV-OS-PRB-01 nachgewiesen per rohem HTTP-
    # Response-Vergleich, siehe CLAUDE.md): Fragt man NUR displayId/subject/
    # technician ab, liefert der Server ein leeres "tickets"-Array zurueck,
    # obwohl "listInfo.totalCount" korrekt bleibt (bestaetigter Server-Bug,
    # unabhaengig von "condition" oder Ergebnisgroesse - reine Feldauswahl-
    # Eigenheit). Werden zusaetzlich "ticketId" und "status" mitabgefragt
    # (auch wenn ungenutzt), liefert derselbe Aufruf die vollstaendige Liste.
    # NICHT entfernen, auch wenn ticketId/status im Code unten nicht
    # verwendet werden.
    $Query = @'
query ($input: ListInfoInput!) {
  getTicketList(input: $input) {
    listInfo {
      totalCount
      hasMore
    }
    tickets {
      ticketId
      status
      displayId
      subject
      technician
    }
  }
}
'@

    $Variables = @{
        input = @{
            page      = 1
            pageSize  = $PageSize
            sort      = @(@{ attribute = "createdTime"; order = "DESC" })
            condition = $Condition
        }
    }

    try {
        $Result = Invoke-SuperOpsGraphQL -Query $Query -Variables $Variables

        if ($Result.errors) {
            $ErrorText = ($Result.errors | ForEach-Object { $_.message }) -join " | "
            Write-LocalLog -Level "WARN" -Message "getTicketList lieferte GraphQL-Fehler: $ErrorText"
            return $null
        }

        $ListData = $Result.data.getTicketList
        if ($ListData.listInfo.hasMore) {
            Write-LocalLog -Level "WARN" -Message "getTicketList: weitere Seiten vorhanden (PageSize=$PageSize reicht nicht) - totalCount stimmt, aber die geladene Ticketliste ist unvollstaendig."
        }
        return $ListData
    }
    catch {
        Write-ExceptionDetails -ErrorRecord $_ -Context "Get-SuperOpsTicketList"
        return $null
    }
}

# Baut eine Zeile pro Techniker (dynamisch aus den tatsaechlich vorkommenden
# "technician"-Werten, kein hartcodiertes Namensarray - erscheint automatisch
# ein neuer Techniker in offenen/ueberfaelligen Tickets, taucht er hier auf).
# $OpenTickets liefert die "Offene Tickets"-Spalte, $OverdueTickets die
# "Ueberfaellig"-Spalte - unterschiedliche Ticket-Mengen (ein Ticket kann
# ueberfaellig UND bereits geschlossen sein, siehe CLAUDE.md), daher zwei
# getrennte Listen statt einer gemeinsamen Gruppierung.
function Get-TechnicianStats {
    param(
        [object[]]$OpenTickets,
        [object[]]$OverdueTickets
    )

    $Stats = @{}

    function Add-Counts {
        param([object[]]$Tickets, [string]$Field)
        foreach ($Ticket in @($Tickets)) {
            $TechName = if ($Ticket.technician) { Get-AssetDisplayName -Asset $Ticket.technician } else { "Nicht zugewiesen" }
            if (-not $Stats.ContainsKey($TechName)) {
                $Stats[$TechName] = [pscustomobject]@{ Name = $TechName; Open = 0; Overdue = 0 }
            }
            $Stats[$TechName].$Field++
        }
    }

    Add-Counts -Tickets $OpenTickets -Field "Open"
    Add-Counts -Tickets $OverdueTickets -Field "Overdue"

    # "Nicht zugewiesen" immer ans Ende, der Rest absteigend nach offenen Tickets sortiert.
    $Rows = $Stats.Values | Where-Object { $_.Name -ne "Nicht zugewiesen" } | Sort-Object -Property Open -Descending
    if ($Stats.ContainsKey("Nicht zugewiesen")) {
        $Rows = @($Rows) + $Stats["Nicht zugewiesen"]
    }
    return ,@($Rows)
}

function New-DashboardHtml {
    param(
        [object[]]$SuperOpsAlerts,
        [object[]]$TechnicianStats,
        [object[]]$UnassignedTickets,
        [int]$RefreshSeconds,
        [string]$PrtgMapUrl
    )

    $PrtgPaneHtml = if ([string]::IsNullOrWhiteSpace($PrtgMapUrl)) {
        '<div class="prtg-placeholder">PRTG-Map-URL noch nicht konfiguriert<br><span>-PrtgMapUrl Parameter setzen, sobald die Map in PRTG erstellt ist</span></div>'
    }
    else {
        "<iframe src=`"$(ConvertTo-SafeHtml $PrtgMapUrl)`" allowfullscreen></iframe>"
    }

    $GeneratedAt = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $UnassignedCount = if ($UnassignedTickets) { @($UnassignedTickets).Count } else { 0 }

    $TechRows = New-Object System.Text.StringBuilder
    if ($TechnicianStats -and $TechnicianStats.Count -gt 0) {
        foreach ($Tech in $TechnicianStats) {
            $RowClass = if ($Tech.Name -eq "Nicht zugewiesen") { " class=`"tech-unassigned`"" } else { "" }
            [void]$TechRows.Append(@"
<tr$RowClass>
  <td class="col-tech">$(ConvertTo-SafeHtml $Tech.Name)</td>
  <td class="col-tech-num">$($Tech.Open)</td>
  <td class="col-tech-num$(if ($Tech.Overdue -gt 0) { ' col-tech-overdue' })">$($Tech.Overdue)</td>
</tr>
"@)
        }
    }
    else {
        [void]$TechRows.Append('<tr><td colspan="3" class="empty">Ticket-Statistiken nicht verfuegbar.</td></tr>')
    }

    $UnassignedRows = New-Object System.Text.StringBuilder
    if ($UnassignedTickets -and $UnassignedTickets.Count -gt 0) {
        foreach ($Ticket in $UnassignedTickets) {
            [void]$UnassignedRows.Append(@"
<div class="ticket-row"><span class="ticket-id">#$(ConvertTo-SafeHtml $Ticket.displayId)</span> $(ConvertTo-SafeHtml $Ticket.subject)</div>
"@)
        }
    }

    $Rows = New-Object System.Text.StringBuilder
    $HasAlerts = $false
    if ($null -eq $SuperOpsAlerts) {
        [void]$Rows.Append('<div class="empty">SuperOps nicht erreichbar.</div>')
    }
    elseif ($SuperOpsAlerts.Count -eq 0) {
        [void]$Rows.Append('<div class="empty">Keine aktiven SuperOps-Alerts.</div>')
    }
    else {
        $HasAlerts = $true
        foreach ($Alert in $SuperOpsAlerts) {
            $Color = Get-SeverityColor -Severity $Alert.severity
            $AssetName = Get-AssetDisplayName -Asset $Alert.asset
            $Text = if ($Alert.description) { $Alert.description } else { $Alert.message }
            $ShortText = Get-TruncatedText -Text $Text -MaxLength 30
            $Count = if ($Alert.OccurrenceCount) { $Alert.OccurrenceCount } else { 1 }

            [void]$Rows.Append(@"
<tr>
  <td class="col-count">x$Count</td>
  <td class="col-severity"><span class="badge" style="background:$Color">$(ConvertTo-SafeHtml $Alert.severity)</span></td>
  <td class="col-device">$(ConvertTo-SafeHtml $AssetName)</td>
  <td class="col-message">$(ConvertTo-SafeHtml $ShortText)</td>
</tr>
"@)
        }
    }

    $StatsBarHtml = @"
<div class="stats-bar"><table><thead><tr>
  <th class="col-tech">Techniker</th>
  <th class="col-tech-num">Offene Tickets</th>
  <th class="col-tech-num">Ueberfaellig</th>
</tr></thead><tbody>$($TechRows.ToString())</tbody></table></div>
"@

    $UnassignedHtml = ""
    if ($UnassignedCount -gt 0) {
        $UnassignedHtml = "<div class=`"unassigned`"><div class=`"unassigned-title`">Nicht zugewiesene Tickets</div>$($UnassignedRows.ToString())</div>"
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
  /* Seit v6.0: body ist EINE Spalte statt einer separaten Zeile pro Quelle -
     beide Quellen in EINER Seite/EINEM Kiosk-Fenster statt zwei separaten
     Chromium-Fenstern auf dem Pi (spart das fehleranfaellige X11-
     Fenstertuiling, siehe CLAUDE.md). Seit v6.2: uebereinander (SuperOps
     oben 2/3, PRTG unten 1/3) statt nebeneinander - auf Wunsch von GIO. */
  body { display: flex; flex-direction: column; }
  .superops-pane { flex: 2; width: 100%; min-height: 0; display: flex; flex-direction: column; overflow: hidden; }
  .prtg-pane { flex: 1; width: 100%; min-height: 0; background: #0a0a0a; border-top: 2px solid #333; }
  .prtg-pane iframe { width: 100%; height: 100%; border: none; display: block; }
  .prtg-placeholder { width: 100%; height: 100%; display: flex; flex-direction: column; align-items: center; justify-content: center; text-align: center; color: #666; font-size: 2.2vh; padding: 2vw; }
  .prtg-placeholder span { font-size: 1.6vh; color: #555; margin-top: 1vh; }
  /* Farbige Punkte + Verlaufslinie unter dem Header, angelehnt an das
     DITZLER-Logo (bunte Punkte ueber den Buchstaben) - der Rest bleibt
     bewusst dunkel/funktional fuer Lesbarkeit aus Bueroentfernung. */
  .header {
    flex: 0 0 auto; padding: 1.8vh 2vw; font-size: 3.6vh; font-weight: 700;
    background: #1c1c1c; border-bottom: 3px solid transparent;
    border-image: linear-gradient(90deg, #e63946, #f4a261, #e9c46a, #2a9d8f, #457b9d) 1;
    display: flex; align-items: center; gap: 1vw; letter-spacing: 0.02em;
  }
  .logo-dots { display: inline-flex; gap: 0.4vw; }
  .logo-dots span { width: 1.7vh; height: 1.7vh; border-radius: 50%; display: inline-block; }
  .stats-bar { flex: 0 0 auto; padding: 0.8vh 2vw; background: #181818; border-bottom: 2px solid #333; }
  .stats-bar th { text-align: left; padding: 0.4vh 1vw; font-size: 1.3vh; color: #999; text-transform: uppercase; letter-spacing: 0.05em; border-bottom: 1px solid #333; }
  .stats-bar th.col-tech-num { text-align: center; }
  .stats-bar td { padding: 0.35vh 1vw; font-size: 1.8vh; border-bottom: none; }
  .col-tech { width: 50%; font-weight: 600; }
  .col-tech-num { width: 25%; text-align: center; font-weight: 700; }
  .col-tech-overdue { color: #fb8c00; }
  .tech-unassigned { color: #999; font-style: italic; }
  .unassigned { flex: 0 0 auto; padding: 1vh 2vw; border-bottom: 2px solid #333; }
  .unassigned-title { font-size: 1.7vh; color: #999; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.5vh; }
  .ticket-row { font-size: 2.3vh; color: #ddd; padding: 0.3vh 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .ticket-id { color: #888; margin-right: 0.5vw; font-weight: 600; }
  .body { flex: 1; min-height: 0; overflow: hidden; padding: 1vh 2vw; }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 1.1vh 1vw; border-bottom: 1px solid #2a2a2a; font-size: 2.5vh; vertical-align: middle; }
  .col-count { width: 6%; color: #888; font-weight: 700; white-space: nowrap; }
  .col-severity { width: 16%; }
  .col-device { width: 26%; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .col-message { color: #bbb; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .badge { display: inline-block; padding: 0.5vh 1.2vw; border-radius: 999px; font-size: 2.2vh; font-weight: 700; color: #111; white-space: nowrap; }
  .empty { padding: 3vh 0; font-size: 2.8vh; color: #777; }
  .footer { flex: 0 0 auto; text-align: right; padding: 0.4vh 1vw; font-size: 1.6vh; color: #555; }
</style>
</head>
<body>
<div class="superops-pane">
<div class="header"><span class="logo-dots"><span style="background:#e63946"></span><span style="background:#f4a261"></span><span style="background:#e9c46a"></span><span style="background:#2a9d8f"></span><span style="background:#457b9d"></span></span>SuperOps Alerts</div>
$(
    if ($HasAlerts) { "<div class=`"body`"><table><tbody>$($Rows.ToString())</tbody></table></div>" }
    else { "<div class=`"body`">$($Rows.ToString())</div>" }
)
$UnassignedHtml
$StatsBarHtml
<div class="footer">Aktualisiert: $GeneratedAt</div>
</div>
<div class="prtg-pane">$PrtgPaneHtml</div>
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

    # "Open Tickets" (condition: status isNot Closed/Resolved) liefert die
    # Ticketliste, aus der sowohl die Techniker-Statistik (Get-TechnicianStats)
    # als auch die nicht zugewiesenen (technician == null) client-seitig
    # herausgefiltert werden. "Overdue Tickets" braucht jetzt die volle Liste
    # (nicht nur den Zaehler, PageSize=1 reichte fuer die alte Aggregatzahl,
    # fuer die Techniker-Aufschluesselung wird die tatsaechliche Liste
    # gebraucht - 8 Tickets aktuell, PageSize=100 mit viel Reserve).
    $OpenTicketsList = Get-SuperOpsTicketList -Condition $Script:OpenTicketsCondition -PageSize 100
    $OverdueTicketsList = Get-SuperOpsTicketList -Condition $Script:OverdueTicketsCondition -PageSize 100

    # Kein "if/else"-Ausdruck fuer die Zuweisung - ein leeres Array als
    # Ergebnis eines if/else-Zweigs wird beim Zuweisen zu $null aufgeloest
    # (siehe Kommentar in Get-SuperOpsActiveAlerts zum selben PowerShell-
    # Verhalten). Beide Variablen werden unten per Truthy-Check verwendet,
    # daher unschaedlich, aber zur Konsistenz sauber als garantiertes Array
    # aufgebaut.
    $UnassignedTickets = @()
    if ($OpenTicketsList) {
        $UnassignedTickets = @($OpenTicketsList.tickets | Where-Object { -not $_.technician })
    }

    if (-not $OpenTicketsList -or -not $OverdueTicketsList) {
        Write-LocalLog -Level "WARN" -Message "Ticket-Statistiken konnten nicht vollstaendig geladen werden (Open geladen=$([bool]$OpenTicketsList), Overdue geladen=$([bool]$OverdueTicketsList))."
    }

    $TechnicianStats = Get-TechnicianStats -OpenTickets $OpenTicketsList.tickets -OverdueTickets $OverdueTicketsList.tickets

    $Html = New-DashboardHtml -SuperOpsAlerts $SuperOpsAlerts `
        -TechnicianStats $TechnicianStats `
        -UnassignedTickets $UnassignedTickets -RefreshSeconds $RefreshSeconds `
        -PrtgMapUrl $PrtgMapUrl

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
