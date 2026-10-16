:: ==========================================================
:: _CHECK_.CMD
:: Starter fuer CheckEnrollementPC.ps1 (gleicher Ordner)
:: ==========================================================
:: Autor    : GIO / Claude
:: Version  : 1.1
:: Datum    : unbekannt (vor 16.10.2026)
:: Geaendert: 16.10.2026
::
:: Verwendung:
::   Nach abgeschlossenem Autopilot, angemeldet als Enrollment-Benutzer,
::   per Doppelklick starten - NICHT "Als Administrator ausfuehren"
::   (der PRT wird nur fuer den angemeldeten Benutzer korrekt angezeigt).
::
:: Aenderungsverlauf:
::   1.0 (vor 16.10.2026): Ursprungsversion
::   1.1 (16.10.2026): Kopfzeile, korrekte Startmeldung, pause am Ende
::                     (Fenster schloss sich sonst sofort)
:: ==========================================================
@echo off
echo Pruefung Hybrid Join / Intune Enrollment wird gestartet...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CheckEnrollementPC.ps1"
pause
