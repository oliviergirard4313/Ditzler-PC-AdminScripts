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

Der Pi selbst bekommt in beiden Faellen nie SuperOps-Zugangsdaten zu sehen - er zeigt nur bereits
fertige, oeffentlich erreichbare Seiten an (die generierte SuperOps-Seite bzw. die native
PRTG-Map-URL).

## Dateien

- `Test-SuperOpsAlertSchema.ps1`: Einmalig-Diagnoseskript, DIREKT auf SV-OS-PRB-01 ausfuehren
  (Get-Credentials scheitert auf einer normalen Admin-Arbeitsstation ohne eigene frische
  credentials.xml mit einem DPAPI-Fehler - bestaetigt am 12.08.2026 bei einem Testlauf von einer
  Admin-Arbeitsstation). Fragt per GraphQL-Introspection nach, wie die SuperOps-Abfrage zum
  AUFLISTEN bestehender Alerts mit Volltext tatsaechlich heisst (die Bibliothek in
  Ditzler-Scripts-Superops kennt bisher nur die Mutation `createAlert`, keine Listenabfrage).
- `Generate SuperOps Alert Dashboard.ps1`: Rendert `dashboard.html` (dunkles Design, grosse
  Schrift, `<meta refresh>` alle 60s, NUR SuperOps) nach
  `C:\ProgramData\Superops\Scripts\DashboardWeb\`. Importiert weiterhin
  `Ditzler-Powershell-Lib.psm1` aus dem Superops-Repo (via fixem Pfad auf SV-OS-PRB-01, siehe
  Skriptkopf) - reine Lesenutzung, kein Code-Duplikat. Die SuperOps-Abfrage (`getAlertList`,
  Funktion `Get-SuperOpsActiveAlerts`) ist eine Analogiebildung zu `getAssetList`/`getUserList`
  und **noch nicht empirisch bestaetigt** - vor dem produktiven Einsatz mit
  `Test-SuperOpsAlertSchema.ps1` validieren und bei Bedarf anpassen. Schlaegt der Abruf fehl,
  zeigt die Seite einen Hinweistext UND es wird ein kritischer SuperOps-Alert gesendet (der
  Bildschirm soll nie unbemerkt veraltet bleiben).
- `Register-DashboardTask.ps1`: Einmalig-Werkzeug, richtet auf SV-OS-PRB-01 eine normale Windows-
  Aufgabenplanung ein (jede Minute, als SYSTEM) - bewusst KEIN SuperOps Recurring Script, da die
  gewuenschte Taktung (30-60s) ausserhalb des ueblichen SuperOps-Rhythmus liegt und dieses Skript
  kein Monitoring/Alerting ist, sondern nur eine Anzeige erzeugt.
- `RaspberryPi-Dashboard/import-root-ca.sh`: Importiert das interne Root-CA-Zertifikat sowohl in
  den systemweiten CA-Speicher als auch in den NSS-Zertifikatsspeicher unter `~/.pki/nssdb`, den
  Chromium unter Linux fuer https-Pruefungen nutzt (der systemweite Speicher allein reicht dafuer
  NICHT aus). VOR `setup-kiosk.sh` ausfuehren. Das Root-Zertifikat selbst muss GIO vorher manuell
  exportieren (z.B. aus dem Windows-Zertifikatsspeicher von SV-OS-PRB-01, Stammzertifizierungs-
  stellen -> Zertifikat -> Exportieren OHNE privaten Schluessel) und auf den Pi kopieren.
- `RaspberryPi-Dashboard/setup-kiosk.sh`: Startet ueber ein Wrapper-Skript ZWEI Chromium-Kiosk-
  Fenster nebeneinander (links SuperOps-Seite ueber https, rechts PRTG-Map), per XDG-Autostart
  (`~/.config/autostart/`). Fensterkachelung per `--window-position`/`--window-size` ist unter
  X11 zuverlaessig, unter Wayland/labwc (Standard auf Raspberry Pi OS Bookworm) NICHT garantiert
  - das Skript weist beim Ausfuehren darauf hin, falls die aktuelle Sitzung kein X11 ist
  (Empfehlung: `raspi-config` -> Advanced Options -> Wayland -> X11 umstellen). Sichert eine
  vorhandene, kaputte alte Kiosk-Konfiguration nach `~/kiosk-backup-<Datum>/` statt sie zu
  loeschen. `SUPEROPS_URL` und `PRTG_URL` im Skript muessen vor der Ausfuehrung gesetzt werden.

## IIS auf SV-OS-PRB-01

**Bestaetigt per Screenshot von GIO, 12.08.2026:** Eine einzige Site "Default Web Site"
(Bindings `*:80` http und `*:443` https, physischer Pfad `D:\inetpub\wwwroot`), darunter je ein
Unterordner pro Anwendung: `BGInfo`, `Bitdefender`, `Nutanix`. Das Dashboard soll als VIERTE
Anwendung unter derselben Default Web Site eingerichtet werden (IIS Manager -> Default Web Site
-> Add Application -> Alias `dashboard`, physischer Pfad
`C:\ProgramData\Superops\Scripts\DashboardWeb`, Laufwerksgrenze C:/D: ist fuer IIS
unproblematisch) - NICHT als eigene neue Site, um die Bindings/das Zertifikat der bestehenden
Site wiederzuverwenden. Das https-Zertifikat dieser Site stammt aus der internen Ditzler-
Zertifizierungsstelle (nicht oeffentlich signiert) - das Root-Zertifikat muss deshalb separat
auf dem Raspberry Pi importiert werden, sonst blockiert Chromium die Seite mit einer
Zertifikatswarnung (siehe `import-root-ca.sh` oben). Deshalb auch `SUPEROPS_URL` im Kiosk-Skript
auf `https://` gesetzt.

## Noch offen

- Anwendung `dashboard` unter der Default Web Site auf SV-OS-PRB-01 anlegen (Pfad siehe oben).
- `Test-SuperOpsAlertSchema.ps1` auf SV-OS-PRB-01 ausfuehren und `Get-SuperOpsActiveAlerts`
  entsprechend anpassen.
- PRTG-Map von GIO erstellen lassen und deren URL in `RaspberryPi-Dashboard/setup-kiosk.sh`
  eintragen.
- Internes Root-CA-Zertifikat von SV-OS-PRB-01 exportieren (ohne privaten Schluessel) und mit
  `import-root-ca.sh` auf den Pi bringen.

## Git-Workflow

- Lebt im Repo `Ditzler-PC-AdminScripts` (https://github.com/oliviergirard4313/Ditzler-PC-AdminScripts),
  Branch `main`, nicht im Repo `Ditzler-Scripts-Superops`.
- Zwei Maschinen (Heim-PC + Arbeitslaptop) — bei Ankunft pullen, beim Verlassen pushen (siehe
  Sync-Mechanismus in `Sync-DitzlerRepos.ps1`, gilt fuer den Parent-Repo `C:\Admin\Ditzler`).
