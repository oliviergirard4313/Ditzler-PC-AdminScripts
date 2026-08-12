#!/bin/bash
# ==========================================================
# setup-kiosk.sh
# Einmalig auf dem Raspberry Pi ausfuehren (als Benutzer "dashboard" bzw.
# dem Benutzer, der bei Systemstart automatisch angemeldet wird - siehe
# raspi-config, System Options -> Boot / Auto Login -> Desktop Autologin).
# ==========================================================
# Autor    : GIO / Claude
# Version  : 3.0
# Datum    : 2026-08-12
#
# Zweck:
#   Richtet den TV-Dashboard-Kiosk ein (grosser Bildschirm im Buero): EIN
#   Chromium-Fenster wird automatisch im Vollbild gestartet, ohne
#   Adressleiste/Raender. Die Seite selbst (siehe Generate SuperOps Alert
#   Dashboard.ps1 auf SV-OS-PRB-01) ist zweispaltig aufgebaut - PRTG-Map
#   als <iframe> links, SuperOps-Alerts/Ticket-Statistiken rechts - beides
#   in EINER Seite, EINEM Fenster.
#
# Architekturverlauf (siehe CLAUDE.md fuer die volle Geschichte):
#   - v1.0: eine Seite, serverseitig aus SuperOps- UND PRTG-Daten
#     zusammengebaut (PRTG wurde damals noch gescraped).
#   - v2.0: PRTG wird NICHT mehr gescraped (native Map-Ansicht von GIO
#     bereitgestellt) - dafuer ZWEI gekachelte Chromium-Fenster, eines pro
#     Quelle, weil eine serverseitig zusammengebaute Seite mit der reinen
#     Alert-Textquelle (SuperOps) allein nicht mehr ausreichte.
#   - v3.0 (diese Version): zurueck zu EINEM Fenster - PRTGs mapshow.htm
#     ist von Paessler explizit fuers Einbetten gedacht (kein X-Frame-
#     Options-Problem zu erwarten), daher jetzt als <iframe> direkt in der
#     von SV-OS-PRB-01 generierten Seite statt eines zweiten Fensters.
#     Erspart das fehleranfaellige X11-Fenstertuiling (--window-position/
#     --window-size funktioniert unter Wayland/labwc nicht zuverlaessig) -
#     mit nur einem Fenster ist X11 vs. Wayland fuer die Darstellung
#     irrelevant, --kiosk uebernimmt das Vollbild in beiden Faellen.
#
#   Alte, nicht mehr funktionierende Kiosk-Konfiguration wird NICHT
#   geloescht, sondern nach ~/kiosk-backup-<Datum>/ verschoben.
#
# Verwendung:
#   0. import-root-ca.sh ausfuehren (importiert das interne Ditzler-Root-
#      Zertifikat - noetig, damit Chromium der IIS-Site auf SV-OS-PRB-01
#      vertraut).
#   1. DASHBOARD_URL unten anpassen, falls sich die IIS-Adresse aendert
#      (Standard passt bereits: die Seite enthaelt PRTG+SuperOps zusammen,
#      die PRTG-Map-URL wird NICHT hier, sondern per -PrtgMapUrl Parameter
#      in Generate SuperOps Alert Dashboard.ps1 auf SV-OS-PRB-01 gesetzt).
#   2. ./setup-kiosk.sh
#   3. sudo reboot
#
# Aenderungsverlauf:
#   1.0 (2026-08-12): Erste Version, ein Kiosk-Fenster mit kombinierter
#                      Seite (SuperOps+PRTG server-seitig zusammengebaut)
#   2.0 (2026-08-12): Umgestellt auf zwei gekachelte Fenster - PRTG wird
#                      nicht mehr gescraped, sondern nativ als eigene
#                      Map-URL angezeigt (siehe CLAUDE.md)
#   2.1 (2026-08-12): Live-Test auf sv-os-HAL9000 (echter Pi-Hostname):
#                      (1) chromium-browser-Binary existiert auf neueren
#                      Raspberry Pi OS Versionen nicht mehr (nur noch das
#                      leere Uebergangspaket) - Binaryname wird jetzt per
#                      "command -v" ermittelt statt hartkodiert.
#                      (2) "Unlock Keyring"-Dialog blockierte den Start
#                      trotz --password-store=basic (das wirkt nur auf
#                      Chromiums Passwortmanager, nicht auf den generellen
#                      gnome-keyring-Autostart) - per XDG-Autostart-Override
#                      (Hidden=true) unterdrueckt.
#                      (3) NET::ERR_CERT_COMMON_NAME_INVALID (fehlendes SAN
#                      im IIS-Zertifikat, kein Root-CA-Vertrauensproblem) -
#                      --ignore-certificate-errors als Uebergangsloesung,
#                      bis das Zertifikat mit korrektem SAN neu ausgestellt
#                      wird (separate PKI-Aufgabe).
#   2.2 (2026-08-12): PKI-Aufgabe aus v2.1 erledigt - neues Zertifikat mit
#                      korrektem SAN (sv-os-prb-01.ditzlernet.local +
#                      sv-os-prb-01) ueber ditzler-CA (Template "WebServer")
#                      ausgestellt und in IIS gebunden. Live auf dem Pi
#                      bestaetigt: keine Zertifikatswarnung mehr.
#                      --ignore-certificate-errors dadurch nicht mehr noetig,
#                      wieder entfernt (Zertifikatspruefung laeuft normal).
#   3.0 (2026-08-12): Architekturwechsel auf Wunsch von GIO: PRTG-Map als
#                      <iframe> in dieselbe SuperOps-Seite eingebettet
#                      (siehe Generate SuperOps Alert Dashboard.ps1 v6.0),
#                      statt eines zweiten separaten Kiosk-Fensters. Dieses
#                      Skript dadurch stark vereinfacht: nur noch EIN
#                      Chromium-Aufruf, keine Aufloesungsermittlung/
#                      Fensterpositionierung mehr, X11-vs-Wayland-Frage
#                      damit hinfaellig.
# ==========================================================

set -e

DASHBOARD_URL="https://sv-os-prb-01.ditzlernet.local/DashboardSuperops/dashboard.html"

AUTOSTART_DIR="$HOME/.config/autostart"
DESKTOP_FILE="$AUTOSTART_DIR/ditzler-dashboard.desktop"
BIN_DIR="$HOME/.local/bin"
WRAPPER_SCRIPT="$BIN_DIR/start-dashboard-kiosk.sh"
BACKUP_DIR="$HOME/kiosk-backup-$(date +%Y%m%d%H%M%S)"

echo "=== 1. Alte Kiosk-Konfiguration sichern ==="
mkdir -p "$BACKUP_DIR"

for OLD_PATH in \
    "$HOME/.config/autostart" \
    "$HOME/.config/lxsession/LXDE-pi/autostart" \
    "$HOME/.config/labwc/autostart" \
    "$HOME/.config/wayfire.ini"
do
    if [ -e "$OLD_PATH" ]; then
        echo "Sichere: $OLD_PATH"
        cp -a "$OLD_PATH" "$BACKUP_DIR/" 2>/dev/null || true
    fi
done

echo "Backup abgelegt unter: $BACKUP_DIR"

echo "=== 2. Alte Chromium-Kiosk-Autostarts entfernen (falls vorhanden) ==="
if [ -d "$AUTOSTART_DIR" ]; then
    grep -l -i "chromium" "$AUTOSTART_DIR"/*.desktop 2>/dev/null | while read -r OLD_ENTRY; do
        echo "Deaktiviere alten Eintrag: $OLD_ENTRY"
        mv "$OLD_ENTRY" "$OLD_ENTRY.disabled"
    done
fi

# --password-store=basic (siehe unten) verhindert nur, dass Chromiums
# Passwortmanager den Systemschluesselbund nutzt - der gnome-keyring-Daemon
# startet trotzdem bei jeder Anmeldung und wird z.B. fuer OSCrypt (Cookie-
# Verschluesselung) angefragt, was auf diesem Kiosk-Konto ohne automatische
# PAM-Entsperrung zum blockierenden "Unlock Keyring"-Dialog fuehrt (live
# beobachtet 12.08.2026 auf sv-os-HAL9000, trotz --password-store=basic).
# Kein Passwort/keine Secrets auf diesem Kiosk noetig - der Daemon wird
# deshalb per Standard-XDG-Override (Hidden=true in ~/.config/autostart/,
# gleicher Dateiname wie die Vorgabe unter /etc/xdg/autostart/) komplett
# unterdrueckt, statt zu versuchen, ihn automatisch zu entsperren.
echo "=== 2b. Autostart des gnome-keyring-Daemons unterdruecken ==="
mkdir -p "$AUTOSTART_DIR"
for KEYRING_ID in gnome-keyring-pkcs11 gnome-keyring-secrets gnome-keyring-ssh; do
    cat > "$AUTOSTART_DIR/${KEYRING_ID}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${KEYRING_ID} (disabled)
Exec=true
Hidden=true
EOF
done
echo "Keyring-Autostart per Override deaktiviert (wirkt nach Neustart)."

echo "=== 3. Wrapper-Skript fuer das Kiosk-Fenster einrichten ==="
mkdir -p "$BIN_DIR"

cat > "$WRAPPER_SCRIPT" <<'WRAPPER_EOF'
#!/bin/bash
# Wird von ditzler-dashboard.desktop automatisch gestartet.

DASHBOARD_URL="__DASHBOARD_URL_PLACEHOLDER__"

# Binaername variiert je nach Raspberry Pi OS Version - "chromium-browser" ist
# auf neueren Systemen (Debian 13/trixie-Basis) nur noch ein leeres
# Uebergangspaket ohne echtes Binary, das echte Binary heisst "chromium"
# (bestaetigt 12.08.2026 auf sv-os-HAL9000: "chromium-browser: command not
# found", "which chromium" -> /usr/bin/chromium). Beide Namen probieren,
# statt einen hart zu kodieren.
if command -v chromium-browser >/dev/null 2>&1; then
    CHROMIUM_BIN="chromium-browser"
elif command -v chromium >/dev/null 2>&1; then
    CHROMIUM_BIN="chromium"
else
    echo "FEHLER: Weder 'chromium-browser' noch 'chromium' gefunden. 'sudo apt install chromium' ausfuehren." >&2
    exit 1
fi

# --password-store=basic: zusaetzlich zur Autostart-Unterdrueckung des
# Keyring-Daemons oben (fuer Chromiums eigenen Passwortmanager). Unproblematisch,
# da --incognito ohnehin nichts dauerhaft speichert.
COMMON_FLAGS="--kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --disable-translate --overscroll-history-navigation=0 --check-for-update-interval=31536000 --incognito --password-store=basic"

"$CHROMIUM_BIN" $COMMON_FLAGS \
    --user-data-dir="$HOME/.config/chromium-kiosk-dashboard" \
    "$DASHBOARD_URL" &
WRAPPER_EOF

# URL in den Wrapper einsetzen (kein sed -i mit Sonderzeichen im Pfad,
# deshalb ueber Platzhalter + einfaches sed ohne Sonderzeichenprobleme)
sed -i "s#__DASHBOARD_URL_PLACEHOLDER__#${DASHBOARD_URL}#g" "$WRAPPER_SCRIPT"

chmod +x "$WRAPPER_SCRIPT"
echo "Wrapper-Skript geschrieben: $WRAPPER_SCRIPT"

echo "=== 4. Autostart-Eintrag einrichten ==="
mkdir -p "$AUTOSTART_DIR"

cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Ditzler Dashboard Kiosk
Exec=${WRAPPER_SCRIPT}
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF

echo "Autostart-Eintrag geschrieben: $DESKTOP_FILE"

echo "=== 5. Bildschirmschoner / Standby deaktivieren ==="
if command -v raspi-config >/dev/null 2>&1; then
    sudo raspi-config nonint do_blanking 1 || true
    echo "Bildschirm-Blanking ueber raspi-config deaktiviert."
else
    echo "raspi-config nicht gefunden - Blanking manuell pruefen (xset s off -dpms unter X11)."
fi

echo ""
echo "Fertig. Dashboard-URL: $DASHBOARD_URL"
echo "(enthaelt PRTG-Map + SuperOps-Alerts in einer Seite - PRTG-URL wird"
echo "per -PrtgMapUrl Parameter in Generate SuperOps Alert Dashboard.ps1"
echo "auf SV-OS-PRB-01 gesetzt, nicht hier auf dem Pi)"
echo "Jetzt neu starten: sudo reboot"
