#!/bin/bash
# ==========================================================
# setup-kiosk.sh
# Einmalig auf dem Raspberry Pi ausfuehren (als Benutzer "pi" bzw. dem
# Benutzer, der bei Systemstart automatisch angemeldet wird - siehe
# raspi-config, System Options -> Boot / Auto Login -> Desktop Autologin).
# ==========================================================
# Autor    : GIO / Claude
# Version  : 2.0
# Datum    : 2026-08-12
#
# Zweck:
#   Richtet den TV-Dashboard-Kiosk ein (grosser Bildschirm im Buero):
#   ZWEI Chromium-Fenster werden automatisch gestartet und nebeneinander
#   gekachelt (je eines pro Haelfte des Bildschirms), ohne Adressleiste/
#   Raender:
#     - links : SuperOps-Alerts (von SV-OS-PRB-01 generierte Seite,
#               siehe Generate SuperOps Alert Dashboard.ps1)
#     - rechts: PRTG-Map (native PRTG-Ansicht, eigene URL von GIO)
#   Kein zusammengesetztes HTML mehr auf Skriptseite noetig - jede
#   Quelle bleibt in ihrem eigenen Fenster/eigener Session.
#
#   Architekturentscheidung 12.08.2026: SuperOps' eigener Report-Editor
#   kennt kein Widget mit rohem Alert-Text (nur Tabellen/Zaehler), daher
#   bleibt fuer SuperOps eine eigene generierte Seite noetig. PRTG hat
#   dagegen eine native Map-Ansicht, die GIO direkt bereitstellt - PRTG
#   wird hier NICHT gescraped (PRTG soll mittelfristig sowieso abgeloest
#   werden, siehe CLAUDE.md).
#
#   Fensterkachelung per --window-position/--window-size ist unter X11
#   zuverlaessig, unter Wayland/labwc (Standard auf Raspberry Pi OS
#   Bookworm) dagegen NICHT garantiert. Dieses Skript versucht deshalb,
#   den Pi per raspi-config auf X11 umzustellen (Advanced Options ->
#   Wayland -> X11). Falls das fehlschlaegt oder nicht gewuenscht ist,
#   muss die Fensterkachelung unter Wayland/labwc manuell geprueft
#   werden (z.B. ueber eine labwc-Layout-Regel statt CLI-Flags).
#
#   Alte, nicht mehr funktionierende Kiosk-Konfiguration wird NICHT
#   geloescht, sondern nach ~/kiosk-backup-<Datum>/ verschoben.
#
# Verwendung:
#   0. ZUERST import-root-ca.sh ausfuehren (die IIS-Site auf SV-OS-PRB-01
#      nutzt ein Zertifikat aus der internen Ditzler-CA - ohne dieses
#      Root-Zertifikat auf dem Pi zeigt das linke Kiosk-Fenster nur eine
#      Zertifikatswarnung statt des Dashboards, siehe import-root-ca.sh)
#   1. SUPEROPS_URL und PRTG_URL unten anpassen
#   2. ./setup-kiosk.sh
#   3. sudo reboot
#
# Aenderungsverlauf:
#   1.0 (2026-08-12): Erste Version, ein Kiosk-Fenster mit kombinierter
#                      Seite (SuperOps+PRTG server-seitig zusammengebaut)
#   2.0 (2026-08-12): Umgestellt auf zwei gekachelte Fenster - PRTG wird
#                      nicht mehr gescraped, sondern nativ als eigene
#                      Map-URL angezeigt (siehe CLAUDE.md)
# ==========================================================

set -e

SUPEROPS_URL="https://sv-os-prb-01.ditzlernet.local/dashboard/"
PRTG_URL="__PRTG_MAP_URL_HIER_EINTRAGEN__"

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

echo "=== 3. Wrapper-Skript fuer 2 gekachelte Kiosk-Fenster einrichten ==="
mkdir -p "$BIN_DIR"

cat > "$WRAPPER_SCRIPT" <<'WRAPPER_EOF'
#!/bin/bash
# Wird von ditzler-dashboard.desktop automatisch gestartet. Ermittelt die
# aktuelle Bildschirmaufloesung und startet 2 Chromium-Kiosk-Fenster nebeneinander,
# je mit eigenem Profil (--user-data-dir), da Chromium bei geteiltem Profil
# einfach einen neuen Tab im bestehenden Fenster oeffnen wuerde statt ein
# zweites Fenster.

SUPEROPS_URL="__SUPEROPS_URL_PLACEHOLDER__"
PRTG_URL="__PRTG_URL_PLACEHOLDER__"

# Aufloesung ermitteln (X11). Fallback auf 1920x1080, falls xrandr fehlschlaegt
# (z.B. unter Wayland/labwc ohne XWayland).
RESOLUTION=$(xrandr 2>/dev/null | grep '\*' | head -n1 | awk '{print $1}')
if [ -z "$RESOLUTION" ]; then
    RESOLUTION="1920x1080"
fi
SCREEN_W=$(echo "$RESOLUTION" | cut -d'x' -f1)
SCREEN_H=$(echo "$RESOLUTION" | cut -d'x' -f2)
HALF_W=$((SCREEN_W / 2))

COMMON_FLAGS="--kiosk --noerrdialogs --disable-infobars --disable-session-crashed-bubble --disable-translate --overscroll-history-navigation=0 --check-for-update-interval=31536000 --incognito"

chromium-browser $COMMON_FLAGS \
    --window-position=0,0 --window-size=${HALF_W},${SCREEN_H} \
    --user-data-dir="$HOME/.config/chromium-kiosk-superops" \
    "$SUPEROPS_URL" &

sleep 3

chromium-browser $COMMON_FLAGS \
    --window-position=${HALF_W},0 --window-size=${HALF_W},${SCREEN_H} \
    --user-data-dir="$HOME/.config/chromium-kiosk-prtg" \
    "$PRTG_URL" &
WRAPPER_EOF

# URLs in den Wrapper einsetzen (kein sed -i mit Sonderzeichen im Pfad,
# deshalb ueber Platzhalter + einfaches sed ohne Sonderzeichenprobleme)
sed -i "s#__SUPEROPS_URL_PLACEHOLDER__#${SUPEROPS_URL}#g" "$WRAPPER_SCRIPT"
sed -i "s#__PRTG_URL_PLACEHOLDER__#${PRTG_URL}#g" "$WRAPPER_SCRIPT"

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

echo "=== 6. Desktop-Umgebung pruefen (X11 empfohlen fuer verlaessliche Fensterkachelung) ==="
if [ "$XDG_SESSION_TYPE" != "x11" ]; then
    echo "ACHTUNG: Aktuelle Sitzung ist '$XDG_SESSION_TYPE', nicht 'x11'."
    echo "Fensterpositionierung (--window-position/--window-size) ist unter"
    echo "Wayland/labwc nicht zuverlaessig garantiert. Empfehlung: ueber"
    echo "'sudo raspi-config' -> Advanced Options -> Wayland -> X11 umstellen,"
    echo "dann neu starten und dieses Skript erneut pruefen (die Fenster nach"
    echo "einem Neustart beobachten - liegen sie nebeneinander, ist alles ok)."
fi

if [ "$PRTG_URL" = "__PRTG_MAP_URL_HIER_EINTRAGEN__" ]; then
    echo ""
    echo "ACHTUNG: PRTG_URL wurde noch nicht gesetzt (Zeile am Skriptanfang) -"
    echo "das rechte Kiosk-Fenster zeigt aktuell eine ungueltige URL."
fi

echo ""
echo "Fertig. SuperOps: $SUPEROPS_URL"
echo "        PRTG    : $PRTG_URL"
echo "Jetzt neu starten: sudo reboot"
