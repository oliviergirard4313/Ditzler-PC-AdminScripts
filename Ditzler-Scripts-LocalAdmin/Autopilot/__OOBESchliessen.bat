:: ==========================================================
:: __OOBESCHLIESSEN.BAT
:: Ueberspringt in der OOBE die Seiten "Lizenzvertrag" und
:: "Produktschluessel" und startet die OOBE-Oberflaeche neu.
:: ==========================================================
:: Autor    : GIO / Claude
:: Version  : 1.1
:: Datum    : unbekannt (vor 16.10.2026)
:: Geaendert: 16.10.2026
::
:: Verwendung:
::   OOBE -> Shift+F10 (SYSTEM, bereits erhoeht) -> __OOBESchliessen.bat
::   - beendet CloudExperienceHostBroker.exe (OOBE-Oberflaeche)
::   - setzt SetupDisplayedEula / SetupDisplayedProductKey = 1
::
:: Aenderungsverlauf:
::   1.0 (vor 16.10.2026): Ursprungsversion (powershell Start-Process -Verb RunAs)
::   1.1 (16.10.2026): Kopfzeile; direkte Befehle statt verschachteltem
::                     RunAs-Aufruf (Shift+F10 ist bereits erhoeht, die
::                     verschachtelten Anfuehrungszeichen waren fehleranfaellig);
::                     Pruefung auf Adminrechte
:: ==========================================================
@echo off
net session >nul 2>&1
if errorlevel 1 (
    echo FEHLER: Adminrechte erforderlich - aus Shift+F10 in der OOBE starten.
    pause
    exit /b 1
)

taskkill /f /im CloudExperienceHostBroker.exe
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\OOBE" /v SetupDisplayedEula /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\OOBE" /v SetupDisplayedProductKey /t REG_DWORD /d 1 /f
