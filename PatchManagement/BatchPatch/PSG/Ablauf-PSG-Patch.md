# PSG: Windows-Updates mit BatchPatch (CIMPLICITY / Historian)

Server (Domäne grundstoff.ditzler.ch, VLAN PSG_VLAN101):

| Server | Rolle | IP |
|---|---|---|
| SV-PSG-CIM-01 | CIMPLICITY MASTER (Primary) | 10.100.101.21 |
| SV-PSG-CIM-02 | CIMPLICITY SLAVE (Secondary) | 10.100.101.22 |
| SV-PSG-HIST-01 | Proficy Historian, Proficy-Lizenzserver, WebSpace | 10.100.101.23 |

Wichtig:

- Das Projekt **CIP_MASTER** bleibt während der **gesamten** Aktualisierung gestoppt.
- Auf CIM-01 und CIM-02 ist in *CIMPLICITY Options → Startup Options* „Start projects“ mit CIP_MASTER eingestellt. Das Projekt startet also nach jedem Neustart von selbst. Darum setzt `Stop-PsgProjekt.ps1` den Dienst **CIMPLICITY** während der Updates auf *Deaktiviert*.
- Auf den PSG-Servern wird **nichts automatisch** heruntergeladen oder installiert (GPO `GPO_CPT_WSUS-Servers`: AUOptions=2). Installiert wird nur über BatchPatch.

## Ablauf

| # | Schritt | Wer |
|---|---|---|
| 0 | Wartungsmodus SuperOps | **manuell** |
| 1 | Projekt CIP_MASTER stoppen | **manuell** |
| 2 | **Lauf A** (parallel auf den 3 Servern, Job Queue `PSG-Patch`): `Stop-PsgProjekt.ps1` (CIM) bzw. `Test-PsgProjekt.ps1` (HIST) → kalter Snapshot → Updates + Neustarts, bis keine Updates mehr | BatchPatch |
| 3 | **Lauf B** (nacheinander HIST-01 → CIM-01 → CIM-02, Job Queue `PSG-Nachher`): `Start-PsgProjekt.ps1` (CIM) bzw. Test (HIST) → `Test-PsgProjekt.ps1` | BatchPatch |
| 4 | Sichtkontrollen | **manuell** |
| 5 | Wartungsmodus beenden, Produktion informieren | **manuell** |

Raster auf SV-OS-WSUS-01 (BatchPatch, angemeldet als `DITZLERNET\svc_batchpatch`): `C:\Service\BatchPatch\Grids\PSG-Samstag.bps`.

| Zeile | Remote Command 1 | Remote Command 2 | Remote Command 3 | Local Command 1 | Advanced Multi-Row Queue |
|---|---|---|---|---|---|
| SV-PSG-HIST-01 | Test | Test | Test | Snapshot | PSG-Nachher:1 |
| SV-PSG-CIM-01 | Stop | Start | Test | Snapshot | PSG-Nachher:2 |
| SV-PSG-CIM-02 | Stop | Start | Test | Snapshot | PSG-Nachher:3 |
| PSG-Nachher-Start | – | – | – | – | PSG-Nachher:ExecutionRow |

`PSG.bps` ist das Testraster: alle Befehle mit `-DryRun`. Damit wird nichts geändert.

### 0. Wartungsmodus SuperOps (manuell)

1. In SuperOps die Assets SV-PSG-CIM-01, SV-PSG-CIM-02 und SV-PSG-HIST-01 öffnen.
2. Jeweils **Maintenance Mode** aktivieren, Dauer: geplantes Ende der Arbeiten plus 2 Stunden.
3. Damit werden keine Alarme durch die Neustarts ausgelöst.

### 1. Projekt CIP_MASTER stoppen (manuell)

1. Mit RDP an **SV-PSG-CIM-01** anmelden.
2. Den **CIMPLICITY Workbench** mit dem Projekt CIP_MASTER öffnen (Verknüpfung *CIP_MASTER* auf dem Desktop).
3. In der Symbolleiste auf **Stop** (rotes Quadrat) klicken.
4. Im Fenster *Stop Redundant Project* die Option **Primary & Secondary** wählen und **Stop** klicken.
5. Kontrolle: unten in der Statusleiste steht nicht mehr *Run*. In *CIMPLICITY Options → Projects* (auf CIM-01 und CIM-02) ist die Liste *Running projects* leer.
6. Erst danach BatchPatch starten. Läuft das Projekt noch, bricht `Stop-PsgProjekt.ps1` ab (ExitCode 10) und ändert nichts.

### 2. Lauf A: Snapshot und Updates (BatchPatch)

1. Auf SV-OS-WSUS-01 als `svc_batchpatch` anmelden und BatchPatch starten.
2. **File → Open** → `C:\Service\BatchPatch\Grids\PSG-Samstag.bps`.
3. Kontrolle: Die Spalte *Job Queue* zeigt bei den 3 Servern `* PSG-Patch *`.
4. Die **3 Server-Zeilen** markieren (nicht `PSG-Nachher-Start`).
5. **Actions → Job queue (multi-step execution) → Execute job queue** → bestätigen.

Die 3 Server laufen parallel:

1. CIM: Projekt-Prüfung + Dienst CIMPLICITY deaktivieren. HIST: Test.
2. Herunterfahren, Recovery Point `BatchPatch_Update_<JJJJMMTT>`, Einschalten.
3. Updates suchen, installieren, neu starten. Das wiederholt sich (höchstens 6 Durchgänge), bis keine Updates mehr gefunden werden.

Dauer: etwa 1 bis 2 Stunden.

**Fertig**, wenn in *Job Queue Activity* bei allen 3 Servern *Execution complete* steht. Bei einem Fehler hält die Queue an:

- *Job Queue Activity* zeigt den Schritt.
- *All Messages* zeigt den Exitcode (Tabelle unten).

### 3. Lauf B: Projekt starten und prüfen (BatchPatch)

Erst starten, wenn Lauf A auf **allen 3 Servern** fertig ist.

1. Die **3 Server-Zeilen** markieren.
2. **Actions → Job queue → Create/modify job queue**.
3. Unter *Saved Queues* `PSG-Nachher` doppelklicken. Die Liste *Queue* zeigt 4 Schritte (Remote command 2, abort advanced…, Remote command 3, abort advanced…).
4. **Apply queue to row(s) without executing** → **Close**. Die Spalte *Job Queue* zeigt jetzt `* PSG-Nachher *`.
5. **Nur** die Zeile `PSG-Nachher-Start` markieren.
6. **Actions → Job queue → Execute advanced multi-row queue sequence** → bestätigen.

Die Server laufen nacheinander:

1. HIST-01 (Test);
2. CIM-01 (Dienst CIMPLICITY aktivieren und starten → Projekt startet von selbst, dann Test);
3. CIM-02 (ebenso).

Jeder Server startet erst, wenn der vorherige fertig ist. Bei einem Fehler bricht die ganze Sequenz ab.

Dauer: etwa 10 bis 30 Minuten.

**Fertig**, wenn `PSG-Nachher-Start` *Completed advanced multi-row queue* zeigt.

### Protokolle und Exitcodes

Protokolle:

| Was | Wo |
|---|---|
| Snapshot | SV-OS-WSUS-01: `C:\Service\BatchPatch\Logs\NutanixSnapshot_<VM>_<Datum>.log` |
| PSG-Skripte | jeweiliger Server: `C:\Service\BatchPatch\PSG\Logs\` |

Recovery Points: `BatchPatch_Update_<JJJJMMTT>`, Ablauf nach 6 Tagen (siehe KB „Nutanix: Manueller Snapshot (Recovery Point) vor Updates“).

Exitcodes:

| Skript | Code | Bedeutung / Massnahme |
|---|---|---|
| Stop-PsgProjekt | 10 | Projekt läuft noch → Schritt 1 wiederholen, dann Lauf A erneut starten (nur die betroffene Zeile) |
| Stop-PsgProjekt | 20 | Dienst CIMPLICITY nicht deaktivierbar → nicht weiterpatchen, prüfen |
| Snapshot | 20 | VM fährt nicht herunter (kein hartes Ausschalten) → in Prism Central prüfen |
| Snapshot | 30 | Recovery Point fehlgeschlagen, VM bleibt AUS → in Prism Central prüfen, VM manuell einschalten |
| Snapshot | 40 / 50 | VM startet nicht / nicht erreichbar → Konsole in Prism Central |
| Start-PsgProjekt | 20 | Projekt startet nicht von selbst → **CIP_MASTER manuell starten** (siehe unten), danach Test auf CIM-01/02 (Remote command 3) |
| Start-PsgProjekt | 30 | Historian-Collector startet nicht → im Historian Administrator prüfen |
| Test-PsgProjekt | 10 | mindestens eine Prüfung FEHLER → Protokoll lesen |

**Projekt manuell starten** (nur falls nötig):

1. Auf SV-PSG-CIM-01 im Workbench CIP_MASTER auf **Run** (grüner Pfeil) klicken.
2. Die Option **Primary & Secondary** wählen und bestätigen.
3. Danach in BatchPatch die Zeilen CIM-01 und CIM-02 markieren und **Remote command 3** (Test) ausführen.

### 4. Sichtkontrollen (manuell)

1. **Projekt grün**: Workbench auf CIM-01, Statusleiste zeigt *Run SV-PSG-CIM-01 SV-PSG-CIM-02*.
2. **Historian**: auf SV-PSG-HIST-01 den *Proficy Historian Administrator* öffnen → *Collectors*:
   - SV-PSG-CIM-01_OPC_… und SV-PSG-CIM-02_OPC_… stehen auf **Running**;
   - Redundancy: einer **Active**, der andere **Standby**;
   - SV-PSG-CIM-02_OPCAE_… „Unknown“ (rot) war schon vorher so und ist kein Fehler dieser Aktualisierung.
3. **Redundanz**: auf SV-PSG-CIM-02 das Bild *GefRedundancy* öffnen (Verknüpfung auf dem Desktop). MASTER und SLAVE müssen beide **Online** sein.
4. **Lizenz KEPServerEX** (auf CIM-01 und CIM-02):
   1. Rechtsklick auf das KEPServerEX-Symbol in der Taskleiste → **License Utility**.
   2. *Siemens Suite* muss Status **Good** haben.

### 5. Abschluss (manuell)

1. Wartungsmodus in SuperOps beenden.
2. Produktion informieren, dass die Anlage wieder bereit ist.
3. Nach einigen Tagen ohne Probleme: Recovery Points `BatchPatch_Update_<JJJJMMTT>` der 3 VMs in Prism Central löschen (VM → Recovery Points → markieren → Actions → Delete).

## Zurück auf den Stand vor dem Update

1. Den Revert gemäss KB „Nutanix: Manueller Snapshot (Recovery Point) vor Updates“ durchführen. Den Recovery Point `BatchPatch_Update_<JJJJMMTT>` wählen und für **alle 3 VMs** zurücksetzen.
2. Die VMs bleiben danach ausgeschaltet. In dieser Reihenfolge einschalten:
   1. HIST-01;
   2. CIM-01;
   3. CIM-02.
3. Der Snapshot wurde **nach** `Stop-PsgProjekt.ps1` erstellt. Im Snapshot ist der Dienst CIMPLICITY also auf *Deaktiviert*, und das Projekt startet nach dem Einschalten **nicht** von selbst.
4. Projekt wieder starten:
   1. Auf CIM-01, danach auf CIM-02 in einer PowerShell als Administrator ausführen: `Set-Service CIMPLICITY -StartupType Automatic; Start-Service CIMPLICITY`. Alternativ `Start-PsgProjekt.ps1` per BatchPatch ausführen.
   2. Danach Sichtkontrollen gemäss Schritt 4.
