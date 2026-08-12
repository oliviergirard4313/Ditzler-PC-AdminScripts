#!/bin/bash
# ==========================================================
# import-root-ca.sh
# Einmalig auf dem Raspberry Pi ausfuehren, VOR dem ersten Start des
# Kiosk-Autostarts (setup-kiosk.sh).
# ==========================================================
# Autor    : GIO / Claude
# Version  : 1.0
# Datum    : 2026-08-12
#
# Zweck:
#   Die IIS-Site auf SV-OS-PRB-01, die die generierte SuperOps-Dashboard-
#   Seite bedient, nutzt ein Zertifikat aus der internen Ditzler-CA (von
#   GIO am 12.08.2026 bestaetigt, siehe CLAUDE.md). Ohne dieses Root-
#   Zertifikat haelt weder das Betriebssystem noch Chromium die https-
#   Verbindung fuer vertrauenswuerdig - das Kiosk-Fenster zeigt dann eine
#   Zertifikatswarnung statt des Dashboards.
#
#   Zwei getrennte Vertrauensspeicher muessen befuellt werden:
#   1. Systemweiter CA-Speicher (fuer curl/wget/allgemeine Tools)
#   2. Der NSS-Zertifikatsspeicher unter ~/.pki/nssdb, den Chromium unter
#      Linux fuer die https-Zertifikatspruefung verwendet - der
#      systemweite Speicher allein reicht fuer Chromium NICHT aus.
#
# Voraussetzung:
#   Das Root-CA-Zertifikat (.crt/.pem, OHNE privaten Schluessel) muss
#   vorher von GIO exportiert und auf den Pi kopiert werden (z.B. per
#   scp oder USB-Stick). Export z.B. ueber die interne Zertifizierungs-
#   stelle oder aus dem Windows-Zertifikatsspeicher von SV-OS-PRB-01
#   (Stammzertifizierungsstellen -> Zertifikat -> Exportieren, OHNE
#   privaten Schluessel, Format Base64/PEM).
#
# Verwendung:
#   ./import-root-ca.sh /pfad/zu/RootCA.crt
# ==========================================================

set -e

CERT_PATH="$1"

if [ -z "$CERT_PATH" ] || [ ! -f "$CERT_PATH" ]; then
    echo "Verwendung: $0 /pfad/zu/RootCA.crt"
    echo "Das Root-Zertifikat muss vorher von GIO exportiert und auf den Pi kopiert werden."
    exit 1
fi

echo "=== 1. Systemweiten CA-Speicher aktualisieren ==="
sudo cp "$CERT_PATH" /usr/local/share/ca-certificates/ditzler-root-ca.crt
sudo update-ca-certificates

echo "=== 2. NSS-Zertifikatsspeicher von Chromium aktualisieren ==="
if ! command -v certutil >/dev/null 2>&1; then
    echo "certutil fehlt - installiere libnss3-tools..."
    sudo apt-get update
    sudo apt-get install -y libnss3-tools
fi

mkdir -p "$HOME/.pki/nssdb"
if [ ! -f "$HOME/.pki/nssdb/cert9.db" ]; then
    certutil -d sql:"$HOME/.pki/nssdb" -N --empty-password
fi

# -t "C,," markiert das Zertifikat als vertrauenswuerdige CA fuer SSL.
# Erneuter Aufruf mit demselben -n Namen aktualisiert einen vorhandenen
# Eintrag, statt einen Duplikat-Fehler zu werfen.
certutil -d sql:"$HOME/.pki/nssdb" -D -n "Ditzler Root CA" 2>/dev/null || true
certutil -d sql:"$HOME/.pki/nssdb" -A -t "C,," -n "Ditzler Root CA" -i "$CERT_PATH"

echo ""
echo "Fertig. Alle Chromium-Kiosk-Fenster (bzw. der Pi) neu starten, damit"
echo "die Aenderung sicher greift."
