# TV-Dashboard (Bueroanzeige, Raspberry Pi)

Grosser Bildschirm im Buero mit Raspberry Pi, soll dauerhaft SuperOps- und PRTG-Alerts als
Volltext anzeigen. Dieser Ordner (`C:\Admin\Ditzler\Dashboard`, Teil des Repos
`Ditzler-PC-AdminScripts`) enthaelt die Generator-Skripte (laufen auf SV-OS-PRB-01) und die
Raspberry-Pi-Kiosk-Konfiguration. Urspruenglich im Repo `Ditzler-Scripts-Superops` entwickelt,
am 12.08.2026 hierher verschoben (kein direkter Bezug zu den uebrigen SuperOps-Monitoring-
Skripten dort; nutzt aber weiterhin dessen `Ditzler-Powershell-Lib.psm1`/`credentials.xml` auf
SV-OS-PRB-01 fuer den SuperOps-API-Zugriff).

Architektur am 12.08.2026 zweimal angepasst, nachdem sich zwei Annahmen als falsch/unnoetig
herausstellten - siehe Verlauf, damit nicht erneut in dieselbe Richtung geplant wird:

1. Erste Annahme: SuperOps TV View zeigt nur Zaehler, also braucht es fuer beide Quellen
   (SuperOps + PRTG) eine selbstgebaute Loesung, kombiniert in EINER HTML-Seite (um das
   gleichzeitige Anzeigen auf dem Pi zu vereinfachen).
2. Korrektur (per Screenshot des bestehenden Custom Reports "HAL 9000" von GIO): SuperOps hat
   tatsaechlich einen Report-Editor mit TV Mode und mehreren Widget-Typen (Tabellen, Zaehler) -
   aber **kein Widget mit rohem Alert-Text** (von GIO am 12.08.2026 bestaetigt). Fuer SuperOps
   bleibt also ein eigenes Generator-Skript noetig.
3. Fuer PRTG dagegen baut GIO selbst eine native PRTG-Map (PRTG-Bordmittel, liefert die URL
   nachtraeglich) - **kein Scraping der PRTG-API mehr**, zumal PRTG mittelfristig sowieso
   abgeloest werden soll (Wunsch von GIO: falls die Integration zu aufwendig waere, PRTG
   einfach weglassen statt Aufwand zu investieren).
4. Damit entfaellt auch der Grund fuer EINE kombinierte HTML-Seite: der Pi zeigt stattdessen
   ZWEI gekachelte Chromium-Kiosk-Fenster nebeneinander (eines pro Quelle, jede mit eigener
   Session/URL) statt eines serverseitig zusammengebauten Layouts.
5. GIO fragte an, ob die gesamte Loesung stattdessen komplett auf dem Pi laufen koennte (kein
   SV-OS-PRB-01/IIS noetig). Bewusst verworfen: der SuperOps-API-Schluessel hat vollen
   Kontozugriff (siehe Verwaltung der Zugangsdaten in Ditzler-Scripts-Superops/CLAUDE.md) und
   laesst sich nicht auf reinen Lesezugriff fuer Alerts einschraenken - ihn auf einem physisch
   im Buero stehenden Pi (kein DPAPI-Aequivalent, SD-Karte leicht entnehmbar) abzulegen waere
   eine Sicherheitsverschlechterung gegenueber der bestehenden DPAPI/CMS-Absicherung.
   Entscheidung von GIO (12.08.2026): bei der serverseitigen Generierung auf SV-OS-PRB-01
   bleiben, der Pi bekommt weiterhin nur bereits fertige Seiten zu sehen.
6. **Zurueck zu EINER Seite/EINEM Kiosk-Fenster (12.08.2026, GIO):** Nachdem das Zwei-Fenster-
   Tuiling live auf dem Pi eingerichtet war (siehe `RaspberryPi-Dashboard/setup-kiosk.sh`
   Aenderungsverlauf v2.0-2.2 fuer alle dabei aufgetretenen Stolpersteine: Chromium-Binaryname,
   gnome-keyring-Dialog, fehlendes SAN im IIS-Zertifikat), entschied GIO, die PRTG-Map stattdessen
   als `<iframe>` DIREKT in die von SV-OS-PRB-01 generierte Seite einzubetten (`Generate SuperOps
   Alert Dashboard.ps1` v6.0, neuer Parameter `-PrtgMapUrl`) statt als zweites Kiosk-Fenster.
   Funktioniert, weil PRTGs `mapshow.htm` von Paessler explizit fuers Einbetten in Drittseiten
   gedacht ist (kein `X-Frame-Options`-Blocking zu erwarten - GIOs urspruengliches iframe-Beispiel
   fuer PRTG war genau dieselbe URL). Vorteil: nur noch EIN Chromium-Fenster auf dem Pi -
   `setup-kiosk.sh` v3.0 dadurch stark vereinfacht (keine Aufloesungsermittlung/
   Fensterpositionierung mehr, X11-vs-Wayland-Frage damit hinfaellig fuer die Darstellung).

Der Pi selbst bekommt nie SuperOps-Zugangsdaten zu sehen - er zeigt nur die bereits fertige,
oeffentlich erreichbare Seite an (SuperOps-Alerts/Ticket-Statistiken + eingebettete native
PRTG-Map, beides serverseitig auf SV-OS-PRB-01 zusammengefuehrt).

## Ablageort auf SV-OS-PRB-01

Klare Trennung (Praezisierung von GIO, 12.08.2026): `C:\ProgramData\Superops\Scripts` gehoert
SuperOps selbst (Skripte, die vom SuperOps-Agent ausgefuehrt/verwaltet werden -
`Ditzler-Powershell-Lib.psm1`, `credentials.xml`, die eigentlichen Monitoring-Skripte aus dem
Repo `Ditzler-Scripts-Superops`). Skripte, die stattdessen per **Windows-Aufgabenplanung**
laufen - wie der Dashboard-Generator hier - gehoeren NICHT dorthin, sondern nach
`C:\Service\Scripts` (uebliche Konvention fuer per Aufgabenplanung ausgefuehrte Skripte, siehe
z.B. auch `C:\Service\NutanixCmdlets`). `Generate SuperOps Alert Dashboard.ps1` liegt deshalb
unter `C:\Service\Scripts\DashboardSuperops\` (eigener Unterordner, benannt wie die IIS-
Anwendung weiter unten) und importiert `Ditzler-Powershell-Lib.psm1`/`credentials.xml` nur
lesend aus dem SuperOps-Verzeichnis (Pfad ist im Skriptkopf fix hinterlegt, kein
Code-Duplikat). Falls `C:\Service\Scripts\DashboardSuperops` auf SV-OS-PRB-01 noch nicht
existiert, muss es beim ersten Deployment angelegt werden.

## Dateien

- `Test-SuperOpsAlertSchema.ps1`: Einmalig-Diagnoseskript, DIREKT auf SV-OS-PRB-01 ausfuehren
  (Get-Credentials scheitert auf einer normalen Admin-Arbeitsstation ohne eigene frische
  credentials.xml mit einem DPAPI-Fehler - bestaetigt am 12.08.2026 bei einem Testlauf von einer
  Admin-Arbeitsstation). Fragt per GraphQL-Introspection nach, wie die SuperOps-Abfrage zum
  AUFLISTEN bestehender Alerts mit Volltext tatsaechlich heisst (die Bibliothek in
  Ditzler-Scripts-Superops kennt bisher nur die Mutation `createAlert`, keine Listenabfrage).
- `Generate SuperOps Alert Dashboard.ps1`: Liegt auf SV-OS-PRB-01 unter
  `C:\Service\Scripts\DashboardSuperops` (siehe Abschnitt "Ablageort" oben). Rendert
  `dashboard.html` (dunkles Design, grosse Schrift,
  `<meta refresh>` alle 60s, NUR SuperOps - die Seite steuert ihr eigenes Neuladen selbst, keine
  Konfiguration auf dem Raspberry Pi noetig) nach `D:\inetpub\wwwroot\DashboardSuperops\`
  (physischer Pfad der IIS-Anwendung, siehe Abschnitt "IIS auf SV-OS-PRB-01" unten). Importiert
  `Ditzler-Powershell-Lib.psm1` aus dem SuperOps-Verzeichnis (via fixem Pfad, siehe Skriptkopf)
  - reine Lesenutzung, kein Code-Duplikat. Die SuperOps-Abfrage (`getAlertList`, Funktion
  `Get-SuperOpsActiveAlerts`) wurde am 12.08.2026 per `Test-SuperOpsAlertSchema.ps1` auf
  SV-OS-PRB-01 gegen die echte API bestaetigt (`id` statt `alertId`, `asset` ist ein
  JSON-Skalar ohne bestaetigte Struktur - `Get-AssetDisplayName` wertet ihn defensiv aus,
  ggf. spaeter vereinfachen sobald echte Alerts live beobachtet wurden). Filtert client-seitig
  auf unresolved Alerts (`resolvedTime` leer), da `ListInfoInput` keinen dokumentierten
  Status-Filter hat. Schlaegt der Abruf fehl, zeigt die Seite einen Hinweistext UND es wird ein
  kritischer SuperOps-Alert gesendet (der Bildschirm soll nie unbemerkt veraltet bleiben).
  Seit v4.0 zusaetzlich Ticket-Statistiken (Funktion `Get-SuperOpsTicketList`). Seit v5.0 als
  Tabelle pro Techniker dargestellt (Techniker | Offene Tickets | Ueberfaellig, analog zum
  nativen SuperOps-Report "Tickets nach Mitarbeitenden") statt einer 3-Zahlen-Aggregatzeile -
  siehe Funktion `Get-TechnicianStats`. Techniker werden dynamisch aus den tatsaechlichen
  `technician`-Werten der offenen/ueberfaelligen Tickets ermittelt (kein hartcodiertes
  Namensarray) - "Nicht zugewiesen" ist dabei einfach der Fall `technician == null`, immer als
  letzte Zeile. Die Titelliste der nicht zugewiesenen Tickets bleibt unveraendert darunter.
  Seit v6.0 zusaetzlich Parameter `-PrtgMapUrl`: bettet die native PRTG-Map als `<iframe>` in
  dieselbe Seite ein (`.superops-pane`/`.prtg-pane`) - der Pi braucht dadurch nur noch EIN
  Kiosk-Fenster statt zwei (siehe Architektur-Historie oben, Punkt 6, und `setup-kiosk.sh`
  v3.0). Leerer `-PrtgMapUrl` zeigt einen Platzhalter-Hinweis statt eines kaputten iframes.
  **Layout seit v6.2 (GIO-Wunsch):** uebereinander statt nebeneinander - SuperOps oben
  (`flex: 2`, 2/3 der Hoehe), PRTG unten (`flex: 1`, 1/3 der Hoehe). Bei 1920x1080 entspricht
  das ca. **1920x360 px** fuer die PRTG-Map (volle Breite, ein Drittel der Hoehe). GIO hat die
  Map in PRTG auf diese Groesse angepasst (19.08.2026, per PRTGs Embed-Panel bestaetigt) - `id`
  und `mapid` blieben dabei unveraendert, nur die physische Groesse wurde angepasst, daher war
  **keine Aenderung** am Vorgabewert von `-PrtgMapUrl` (`id=2914`) noetig.
  **Reihenfolge seit v6.3 (GIO-Wunsch):** innerhalb `.superops-pane` erst Alerts, dann nicht
  zugewiesene Tickets (Anzahl + Titelliste), dann die Techniker-Tabelle (`$StatsBarHtml`) - vorher
  stand die Techniker-Tabelle direkt unter dem Header. Zusaetzlich Schriftgroesse der
  Techniker-Tabelle verkleinert (`.stats-bar th`/`td`), da sie zu viel Platz beanspruchte.

  **Entstehungsgeschichte des Filtermechanismus (12.08.2026, mehrere Korrekturen - siehe
  Skriptkopf-Aenderungsverlauf v4.0-4.2 fuer die volle Chronologie):** Erster Versuch nutzte
  SuperOps-"Views" (`Open Tickets` = id `13`, `Overdue Tickets` = id `9007`) samt Argumentname
  `listInfo`, direkt aus den Browser-DevTools (Network-Tab) von `support.ditzler.ch`
  mitgeschnitten. Stellte sich als Sackgasse heraus: `support.ditzler.ch` nutzt die INTERNE
  GraphQL-API der Web-Oberflaeche, waehrend `Invoke-SuperOpsGraphQL` die OEFFENTLICHE IT-API
  (`euapi.superops.ai/it`) verwendet - beide bieten `getTicketList` an, aber mit
  unterschiedlichen Konventionen (Argument `input` statt `listInfo`; `technician` ist wie
  `asset` ein JSON-Skalar statt eines Objekts `{ name }`) UND das "view"-Feld existiert in der
  oeffentlichen API ueberhaupt nicht (per Live-Fehler bestaetigt: `"field name 'view' that is
  not defined for input object type 'ListInfoInput'"`).

  **Tatsaechlich funktionierender Mechanismus:** `condition` (Typ `RuleConditionInput`, per
  Fehlermeldung bestaetigt - Introspection dieser Bibliothek ist fuer diesen Typ unzuverlaessig,
  siehe Abschnitt unten). Ein verschachtelter Bedingungsbaum
  (`joinOperator`/`operands`/`attribute`/`operator`/`value`), dessen Syntax NICHT geraten wurde,
  sondern aus einem echten Browser-Mitschnitt eines manuell in der SuperOps-UI gesetzten
  Ad-hoc-Filters stammt (Filter-Button in der Ticketliste, nicht eine gespeicherte View) -
  dieselbe `condition`-Struktur funktioniert auf BEIDEN APIs (geteilter Filter-Mechanismus im
  Hintergrund). Andere Top-Level-Feldnamen wurden durch Ausschlussverfahren verworfen (`filter`,
  `filters`, `where`, `search`, `status`, `ticketStatus`, `statusList`, `technicianId`,
  `unassigned`, `query`, `view` - alle von der API als unbekannt zurueckgewiesen; GraphQL meldet
  bei `ListInfoInput` jeweils nur EIN ungueltiges Feld pro Aufruf, daher mehrere Testrunden
  noetig). Wichtige Falle dabei: Werte muessen typkorrekt sein (PowerShell `$true` fuer Booleans,
  nicht der String `"true"` - sonst matcht der Filter praktisch alles statt exakt zu filtern,
  live beobachtet bei `resolutionViolated`).
  - Open Tickets: `status isNot "Closed"` UND `status isNot "Resolved"` -> 37 (Ziel laut
    Screenshot: 36, Differenz durch neu erstelltes Ticket zwischen Messung und Test).
  - Overdue Tickets: `resolutionViolated is true` -> exakt 8, exakte Uebereinstimmung mit dem
    Screenshot.
  - `pageSize` ist serverseitig auf 100 gedeckelt (auch wenn 2000 angefragt wird) - fuer die
    aktuellen Zahlen (max. ~40 offene Tickets) ausreichend, muesste bei starkem Wachstum
    ueberwacht werden (`hasMore` in der Antwort, wird geloggt falls `true`).

  **Zweiter Bug, live auf SV-OS-PRB-01 gefunden (v4.3):** Nach dem `condition`-Fix zeigte das
  Dashboard "Nicht zugewiesen: 0", obwohl frueher unassigned Tickets beobachtet wurden. Ueber
  eine ganze Testreihe (verschiedene Operatoren, 1 vs. mehrere `operands`, PS 5.1 vs. PS7,
  `condition` vs. keine `condition`) blieb `tickets` leer, waehrend `listInfo.totalCount` immer
  korrekt war - **bestaetigt per rohem HTTP-Response-Vergleich** (`Invoke-WebRequest` statt
  `Invoke-RestMethod`, um PowerShells automatisches JSON-Parsing zu umgehen): der Server selbst
  sendet `"tickets":[]` zurueck, kein Client-seitiges Parsing-Problem. Ursache war am Ende simpel
  und hatte nichts mit `condition` oder der Ergebnisgroesse zu tun: **die Feldauswahl
  `{ displayId subject technician }` allein liefert ein leeres Array; sobald zusaetzlich
  `ticketId` und `status` mitabgefragt werden (auch wenn ungenutzt), liefert derselbe Aufruf die
  vollstaendigen Daten.** Vermutlich ein Server-seitiger Bug/Sonderfall im Feld-Resolver der
  oeffentlichen IT-API. **Konsequenz:** `Get-SuperOpsTicketList` fragt deshalb immer `ticketId`
  und `status` mit ab, obwohl beide im PowerShell-Code nicht verwendet werden - nicht entfernen.
  Nach dem Fix: `totalCount` und tatsaechlich zurueckgegebene Tickets stimmen exakt ueberein
  (38/38), 7 nicht zugewiesene Tickets mit echten Titeln bestaetigt.

  `Unassigned Tickets` ist KEINE eigene `condition`, sondern die Open-Tickets-Liste
    client-seitig auf `technician` leer gefiltert (per Live-Vergleich in der Web-UI bestaetigt:
    identische Ticket-IDs) - spart eine dritte Server-Anfrage.
- `Register-DashboardTask.ps1`: Einmalig-Werkzeug, richtet auf SV-OS-PRB-01 eine normale Windows-
  Aufgabenplanung ein (jede Minute, als SYSTEM) - bewusst KEIN SuperOps Recurring Script, da die
  gewuenschte Taktung (30-60s) ausserhalb des ueblichen SuperOps-Rhythmus liegt und dieses Skript
  kein Monitoring/Alerting ist, sondern nur eine Anzeige erzeugt. Standard-`$ScriptPath` zeigt auf
  `C:\Service\Scripts\DashboardSuperops\Generate SuperOps Alert Dashboard.ps1`.
- `RaspberryPi-Dashboard/import-root-ca.sh`: Importiert das interne Root-CA-Zertifikat sowohl in
  den systemweiten CA-Speicher als auch in den NSS-Zertifikatsspeicher unter `~/.pki/nssdb`.
  **Seit setup-kiosk.sh v2.1 optional** (nicht mehr zwingend): `setup-kiosk.sh` nutzt jetzt
  `--ignore-certificate-errors`, siehe Erklaerung dort. Das Root-Zertifikat wurde am 12.08.2026
  per PowerShell aus dem Zertifikatspeicher exportiert (kein `certlm.msc` noetig - die
  echte ausstellende CA wurde per TLS-Handshake-Inspektion gegen SV-OS-PRB-01 bestaetigt:
  `CN=ditzler-CA, DC=ditzlernet, DC=local`, nicht `DITZLER_ROOT` oder die andere
  `ditzler-CA`-Variante im Zertifikatspeicher - mehrere Kandidaten mit aehnlichem Namen
  vorhanden, ohne Live-Pruefung waere das Raten gewesen).
- `RaspberryPi-Dashboard/setup-kiosk.sh`: Startet ueber ein Wrapper-Skript EIN Chromium-Kiosk-
  Fenster (die kombinierte Seite von SV-OS-PRB-01, PRTG-Map + SuperOps in einer Seite, siehe
  oben), per XDG-Autostart (`~/.config/autostart/`). Seit v3.0 nur noch ein Fenster - vorher
  (v2.0-2.2) zwei gekachelte Fenster, siehe Architektur-Historie oben Punkt 6 fuer den Wechsel
  und die Begruendung. Sichert eine vorhandene, kaputte alte Kiosk-Konfiguration nach
  `~/kiosk-backup-<Datum>/` statt sie zu loeschen. `DASHBOARD_URL` im Skript muss vor der
  Ausfuehrung stimmen (Standardwert passt bereits zur aktuellen IIS-Adresse). **Stolpersteine
  aus dem Live-Test 12.08.2026 auf sv-os-HAL9000 (echter Pi-Hostname), alle in v2.1/2.2 behoben
  und in v3.0 weiterhin gueltig:** (1) Chromium-Binary heisst auf aktuellen Raspberry Pi OS
  Versionen nur noch `chromium`, `chromium-browser` ist ein leeres Uebergangspaket - Binaryname
  wird per `command -v` ermittelt. (2) `--password-store=basic` verhindert nur, dass Chromiums
  Passwortmanager den Systemschluesselbund nutzt, NICHT den generellen `gnome-keyring`-Autostart
  - der blockierende "Unlock Keyring"-Dialog kam trotzdem, behoben per XDG-Autostart-Override
  (`Hidden=true` fuer `gnome-keyring-pkcs11/secrets/ssh.desktop`). (3) Das urspruengliche IIS-
  Zertifikat auf SV-OS-PRB-01 hatte kein gueltiges SAN (`NET::ERR_CERT_COMMON_NAME_INVALID`) -
  seit v2.2 mit neu ausgestelltem Zertifikat behoben (siehe "Noch offen" unten), kein
  `--ignore-certificate-errors` mehr noetig.

## IIS auf SV-OS-PRB-01

**Bestaetigt per Screenshot von GIO, 12.08.2026:** Eine einzige Site "Default Web Site"
(Bindings `*:80` http und `*:443` https, physischer Pfad `D:\inetpub\wwwroot`), darunter je ein
Unterordner pro Anwendung: `BGInfo`, `Bitdefender`, `Nutanix`. Das Dashboard ist als VIERTE
Anwendung unter derselben Default Web Site eingerichtet (IIS Manager -> Default Web Site ->
Add Application -> Alias `DashboardSuperops`, physischer Pfad
`D:\inetpub\wwwroot\DashboardSuperops` - direkt neben den anderen drei Anwendungen, gleiche
Laufwerksebene wie `D:\inetpub\wwwroot`, kein Drive-Letter-Sprung mehr wie in der ersten Version
mit `C:\Service\Scripts\DashboardWeb`) - NICHT als eigene neue Site, um die Bindings/das
Zertifikat der bestehenden Site wiederzuverwenden. Das https-Zertifikat dieser Site stammt aus
der internen Ditzler-Zertifizierungsstelle (nicht oeffentlich signiert) - das Root-Zertifikat
muss deshalb separat auf dem Raspberry Pi importiert werden, sonst blockiert Chromium die Seite
mit einer Zertifikatswarnung (siehe `import-root-ca.sh` oben). Deshalb auch `SUPEROPS_URL` im
Kiosk-Skript auf `https://` gesetzt.

**Default Document:** Das Skript schreibt `dashboard.html`, nicht `index.html`. Ohne
zusaetzliche Konfiguration liefert `https://.../DashboardSuperops/` daher einen 403 (Directory
Browsing ist i.d.R. deaktiviert) - bestaetigt am 12.08.2026 auf SV-OS-PRB-01. `SUPEROPS_URL` im
Kiosk-Skript enthaelt deshalb bewusst den vollen Dateinamen
(`.../DashboardSuperops/dashboard.html`), um unabhaengig von der IIS-Default-Document-Konfiguration
zuverlaessig zu funktionieren. Wer die "nackte" URL ohne Dateiname bevorzugt, kann zusaetzlich in
der IIS-Anwendung `DashboardSuperops` unter Default Document `dashboard.html` eintragen (an den
Anfang der Liste) - optional, nicht erforderlich.

## Bekannte Bibliotheks-Eigenheit: Introspection unzuverlaessig

`Invoke-SuperOpsGraphQL` (in `Ditzler-Powershell-Lib.psm1`) wirft bei GraphQL-Introspection-
Abfragen (`__type(name: "...") { fields { ... } }`) fuer manche Typen (bestaetigt: `Ticket`,
`ListInfoInput`, intermittierend auch `Alert`) den Fehler `No parameterless constructor defined
for type of 'System.String'` - vermutlich ein Deserialisierungs-Bug (PowerShell 5.1
`ConvertFrom-Json`), kein API-Problem. Betrifft auch die MINIMALE Variante (nur Feldnamen, ohne
Typinfo) - liegt also nicht an der Verschachtelungstiefe der Abfrage.

**Korrektur (12.08.2026):** Die urspruengliche Vermutung, die Introspection habe zusaetzlich den
Argumentnamen falsch als `input` angezeigt (echtes Argument angeblich `listInfo`), war FALSCH -
`input` war die ganze Zeit richtig fuer die oeffentliche IT-API; `listInfo` stammte aus einem
Mitschnitt der ANDEREN (internen) SuperOps-API und war schlicht nicht anwendbar, kein
Introspection-Bug (siehe Abschnitt "Ticket-Statistikzeile" oben fuer die volle Geschichte). Der
Introspection-Bug beschraenkt sich also auf die `__type`-Abfrage selbst (kompletter Fehlschlag),
nicht auf falsch angezeigte Feld-/Argumentnamen innerhalb erfolgreicher Abfragen.

**Ersatzmethoden, wenn Introspection ausfaellt:**
- (a) Mit einer breiten Kandidatenliste gegen die echte Query proben. Fuer SELECTION-Felder
  (z.B. welche Felder hat der Typ `Ticket`) meldet GraphQL alle ungueltigen Namen auf einmal.
  Fuer INPUT-OBJECT-Felder (z.B. welche Felder hat `ListInfoInput`) meldet die API dagegen nur
  EIN ungueltiges Feld pro Aufruf - dort sind mehrere Testrunden noetig (siehe
  `Test-SuperOpsTicketSchema.ps1`, Schritt 5-Historie).
- (b) Die echte Anfrage direkt aus den Browser-DevTools (Network-Tab, `graphql`-Requests)
  mitschneiden, waehrend die SuperOps-Oberflaeche die gewuenschte Ansicht laedt/ein Filter gesetzt
  wird. Vorsicht: SuperOps hat MEHRERE GraphQL-APIs (die interne App-API von
  `support.ditzler.ch` UND die oeffentliche IT-API, die dieses Skript per API-Key nutzt) - ein
  Mitschnitt aus dem Browser gilt nicht automatisch 1:1 fuer die oeffentliche API (Argumentnamen
  und Feldtypen koennen abweichen), aber gemeinsame Backend-Mechanismen wie der
  `condition`-Filterbaum (Typ `RuleConditionInput`) funktionieren auf beiden. Am Ende die
  entscheidende Methode, um die `condition`-Syntax fuer die Ticket-Statistikzeile zu finden -
  reines Raten der Feldwerte (Methode a) fuehrte bei `condition` nur zu unhilfreichen "Internal
  Server Error"-Meldungen ohne Strukturhinweis.

## Bekannte PowerShell-Falle: leeres Array wird zu $null

Live am 12.08.2026 auf SV-OS-PRB-01 beobachtet: Wenn eine Funktion ein leeres Array `@()` ueber
den normalen Ausgabestrom zurueckgibt (`return @()` oder als letzter Ausdruck), "rollt" PowerShell
das beim Verlassen der Funktion automatisch auf - der Aufrufer erhaelt `$null`, nicht ein leeres
Array (Standardverhalten, nicht spezifisch fuer dieses Skript). `Get-SuperOpsActiveAlerts` nutzte
das Ergebnis als Unterscheidungsmerkmal zwischen "API nicht erreichbar" (`$null`) und "0 aktive
Alerts" (leeres Array) - durch das Aufloesungsverhalten wurden beide Faelle ununterscheidbar, und
0 Alerts loeste faelschlich einen kritischen SuperOps-Alert aus. **Fix:** der unaere Komma-Operator
erzwingt, dass der Rueckgabewert als EIN Array-Objekt behandelt wird statt aufgeloest zu werden -
`return ,@(...)` statt `return @(...)`. Gilt auch fuer Zuweisungen ueber `if/else`-Ausdruecke
(`$x = if (...) { @() } else { @(1,2) }` hat dieselbe Falle) - dort hilft der Komma-Operator nicht
direkt, stattdessen das Array in einer eigenen Anweisung aufbauen statt ueber eine if/else-Kette
(siehe `$UnassignedTickets` im Skript fuer das Muster).

## Noch offen

- ~~`C:\Service\Scripts` auf SV-OS-PRB-01 anlegen~~ - existiert. `Generate SuperOps Alert
  Dashboard.ps1` liegt im Unterordner `C:\Service\Scripts\DashboardSuperops\` und wird nach jeder
  Aenderung manuell dorthin kopiert (`C:\Admin\Ditzler\Dashboard` ist die Git-Quelle).
- ~~Anwendung `DashboardSuperops` unter der Default Web Site auf SV-OS-PRB-01 anlegen~~ - erledigt
  (12.08.2026), erreichbar unter `https://sv-os-prb-01.ditzlernet.local/DashboardSuperops/dashboard.html`
  (die "nackte" URL ohne Dateiname liefert bewusst einen 403 - Directory Browsing bleibt
  deaktiviert, `SUPEROPS_URL` im Kiosk-Skript enthaelt deshalb immer den vollen Dateinamen).
- ~~`Test-SuperOpsAlertSchema.ps1` ausfuehren~~ - erledigt (12.08.2026), `Get-SuperOpsActiveAlerts`
  entsprechend angepasst. ~~Mit echten Alerts live pruefen~~ - erledigt (12.08.2026, auf
  SV-OS-DEV-01 - `credentials.xml` liess sich dort entschluesseln, siehe Abschnitt "Verwaltung
  der Zugangsdaten"/Memory `feedback_superops_credentials_dpapi`): `Get-AssetDisplayName` findet
  den Asset-Namen korrekt (`name`-Feld). Dabei aber entdeckt: SuperOps legt bei wiederkehrenden
  identischen Zustaenden mehrere Alert-Datensaetze an statt einen zu aktualisieren - v3.1
  dedupliziert das jetzt (siehe Skriptkopf).
- ~~Ticket-Statistikzeile live pruefen~~ - erledigt (12.08.2026, SV-OS-PRB-01, v4.3): Open/Overdue-
  Zaehler und Unassigned-Titelliste liefern korrekte, mit der SuperOps-UI uebereinstimmende Werte
  (siehe Abschnitt "Ticket-Statistikzeile" oben fuer die volle Debugging-Geschichte).
- ~~PRTG-Map fuer Nebeneinander-Layout erstellen~~ - erledigt (12.08.2026, v6.1, 960x1080 px,
  `id=2914`).
- ~~PRTG-Map fuer Uebereinander-Layout (v6.2) anpassen~~ - erledigt (19.08.2026). GIO hat
  dieselbe Map (`id=2914`) in PRTG auf ca. 1920x360 px angepasst statt eine neue zu erstellen -
  `id`/`mapid` unveraendert, daher keine Aenderung an `-PrtgMapUrl` noetig.
- ~~Internes Root-CA-Zertifikat exportieren~~ - erledigt (12.08.2026, per PowerShell statt
  `certlm.msc`, siehe `import-root-ca.sh`-Eintrag oben).
- ~~IIS-Zertifikat mit gueltigem SAN neu ausstellen~~ - erledigt (12.08.2026). Das urspruengliche
  Zertifikat hatte nur CN gesetzt, kein SAN (`NET::ERR_CERT_COMMON_NAME_INVALID`). Per `certreq`
  neu angefordert ueber `ditzler-CA` (Enterprise-CA auf `sv-os-dc-01`, Template `WebServer` -
  ohne Template-Angabe im INF schlaegt die Anfrage mit `CERTSRV_E_NO_CERT_TYPE` fehl), mit SAN
  fuer `sv-os-prb-01.ditzlernet.local` UND `sv-os-prb-01` (Kurzname), per
  `[Extensions] 2.5.29.17` im Request-INF. SAN wurde von der CA anstandslos uebernommen (kein
  `EDITF_ATTRIBSUBJECTALTNAME2`-Flag noetig, das manche Enterprise-CAs sonst verlangen, um SAN
  aus der Anfrage zu akzeptieren). Neues Zertifikat per Thumbprint in IIS gebunden
  (`(Get-WebBinding ...).AddSslCertificate(<thumbprint>, "my")`, praeziser als die Auswahl per
  Anzeigename in IIS Manager, da altes/neues Zertifikat denselben Anzeigenamen haben). Live auf
  dem Pi bestaetigt: keine Zertifikatswarnung mehr. `--ignore-certificate-errors` dadurch nicht
  mehr noetig, in `setup-kiosk.sh` v2.2 wieder entfernt.
  **Kleine bekannte Unschoenheit:** Das `Locality`-Feld (`L=`) im Zertifikats-Subject hat einen
  Encoding-Fehler (`MÃ¶hlin` statt `Möhlin`, UTF-8/ANSI-Problem zwischen PowerShell `Out-File`
  und `certreq.exe` beim "ö"). Rein kosmetisch, keine funktionale Auswirkung (SAN/CN/Template
  korrekt) - bewusst nicht neu ausgestellt, GIO kann das bei Bedarf spaeter nachziehen.

## Git-Workflow

- Lebt im Repo `Ditzler-PC-AdminScripts` (https://github.com/oliviergirard4313/Ditzler-PC-AdminScripts),
  Branch `main`, nicht im Repo `Ditzler-Scripts-Superops`.
- Zwei Maschinen (Heim-PC + Arbeitslaptop) — bei Ankunft pullen, beim Verlassen pushen (siehe
  Sync-Mechanismus in `Sync-DitzlerRepos.ps1`, gilt fuer den Parent-Repo `C:\Admin\Ditzler`).
