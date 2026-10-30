:: ==========================================================
:: __LAUNCH_.CMD
:: Starter fuer Autopilot-Vorbereitung.ps1 (gleicher Ordner)
:: ==========================================================
:: Autor    : GIO / Claude
:: Version  : 1.2
:: Datum    : unbekannt (vor 16.10.2026)
:: Geaendert: 30.10.2026
::
:: Verwendung:
::   OOBE -> Shift+F10 -> Laufwerk des USB-Sticks waehlen -> __launch_.cmd
::   (laeuft dort als SYSTEM). Nach einem automatischen Neustart erneut
::   starten: vom USB-Stick oder lokal C:\Service\AutopilotSetup\__launch_.cmd
::
:: Aenderungsverlauf:
::   1.0 (vor 16.10.2026): Ursprungsversion
::   1.1 (16.10.2026): Kopfzeile nach Ditzler-Standard, Kommentar auf Deutsch
::   1.2 (30.10.2026): Umbenannt von _launch_.cmd in __launch_.cmd
:: ==========================================================
@echo off
echo Autopilot-Vorbereitung wird gestartet...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Autopilot-Vorbereitung.ps1"
pause
