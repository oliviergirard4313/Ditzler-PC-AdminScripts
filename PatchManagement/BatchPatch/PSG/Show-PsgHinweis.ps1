#Requires -Version 5.1
<#
.SYNOPSIS
    PSG-Patch: Hinweisfenster fuer die manuellen Schritte auf SV-OS-WSUS-01
    (BatchPatch-Sitzung svc_batchpatch).

.DESCRIPTION
    Wird von BatchPatch als "Local command" pro Zeile aufgerufen. Die 3 Zeilen
    laufen parallel, es erscheint trotzdem nur EIN Fenster (Mutex +
    Statusdateien in -StatusOrdner\<JJJJMMTT>).

    -Phase Start  (vor dem kalten Snapshot, Lauf A):
        Fenster Ja/Nein "Wartungsmodus aktiviert? CIP_MASTER gestoppt?".
        Ja   -> ExitCode 0 (alle 3 Zeilen laufen weiter)
        Nein -> ExitCode 1 (alle 3 Zeilen brechen ab, KEIN Snapshot)
        Nach einem "Ja" wird am selben Tag nicht erneut gefragt
        (Wiederholung einer einzelnen Zeile).

    -Phase Ende   (am Ende von Lauf A bzw. Lauf B):
        Merkt sich pro Server "A fertig" bzw. "B fertig" (B = A war schon
        fertig). Sobald alle 3 Server die Phase beendet haben, erscheint EIN
        Hinweis (Lauf B starten bzw. Sichtkontrollen + Wartungsmodus beenden).
        Immer ExitCode 0 (Hinweis, kein Abbruch).

    Voraussetzung: RDP-Sitzung svc_batchpatch auf SV-OS-WSUS-01 offen,
    sonst ist das Fenster unsichtbar und die Queue wartet.

    Aufruf (BatchPatch, Local command):
        Start: cmd /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Service\BatchPatch\Scripts\PSG\Show-PsgHinweis.ps1 -Phase Start -Computer $computer && pwsh.exe ... Invoke-NutanixColdSnapshot.ps1 ...
        Ende : powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Service\BatchPatch\Scripts\PSG\Show-PsgHinweis.ps1 -Phase Ende -Computer $computer

.NOTES
    Autor   : Olivier
    Version : 1.0
    Datum   : 25.11.2026

    Exitcodes:
      0 = weiter
      1 = Abbruch durch den Administrator (Phase Start) oder unerwarteter Fehler
#>
param(
    [Parameter(Mandatory)][ValidateSet('Start', 'Ende')][string]$Phase,
    [Parameter(Mandatory)][string]$Computer,
    [string[]]$Server = @('SV-PSG-CIM-01', 'SV-PSG-CIM-02', 'SV-PSG-HIST-01'),
    [string]$StatusOrdner = 'C:\Service\BatchPatch\PSG\Status'
)

$ErrorActionPreference = 'Stop'
$Kurz    = ($Computer -split '\.')[0].ToUpper()
$Ordner  = Join-Path $StatusOrdner (Get-Date -Format 'yyyyMMdd')
$Beginn  = Get-Date
New-Item -ItemType Directory -Force -Path $Ordner | Out-Null
$LogFile = Join-Path $Ordner 'Hinweise.log'
function Write-Log { param([string]$Msg) Add-Content -Path $LogFile -Value ("[{0:HH:mm:ss}] [{1}] [{2}] {3}" -f (Get-Date), $Phase, $Kurz, $Msg) -Encoding UTF8 }

Add-Type -AssemblyName System.Windows.Forms
function Show-Fenster {
    param([string]$Text, [string]$Titel, [System.Windows.Forms.MessageBoxButtons]$Knoepfe, [System.Windows.Forms.MessageBoxIcon]$Symbol)
    # unsichtbares TopMost-Fenster als Besitzer -> Meldung erscheint im Vordergrund
    $f = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false; WindowState = 'Minimized' }
    $f.Show(); $f.Hide()
    try { return [System.Windows.Forms.MessageBox]::Show($f, $Text, $Titel, $Knoepfe, $Symbol) } finally { $f.Dispose() }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\Ditzler-PSG-Hinweis')
try {
    # verlassener Mutex (anderer Prozess per exit beendet) gilt als erhalten
    try { [void]$mutex.WaitOne() } catch [System.Threading.AbandonedMutexException] { }
    if ($Phase -eq 'Start') {
        $ok  = Join-Path $Ordner 'Start.ok'
        $nein = Join-Path $Ordner 'Start.abbruch'
        if (Test-Path $ok) { Write-Log 'Bereits bestaetigt -> weiter.'; exit 0 }
        if ((Test-Path $nein) -and (Get-Item $nein).LastWriteTime -gt $Beginn.AddSeconds(-1)) {
            Write-Log 'Abbruch durch den Administrator (anderes Fenster) -> Abbruch.'; exit 1
        }
        $antwort = Show-Fenster -Titel 'PSG-Patch: vor dem Start bestaetigen' -Knoepfe YesNo -Symbol Question -Text @"
Vor dem Herunterfahren der PSG-Server bestaetigen:

1. Wartungsmodus in SuperOps aktiviert fuer
   SV-PSG-CIM-01, SV-PSG-CIM-02, SV-PSG-HIST-01?

2. CIP_MASTER im Workbench auf CIM-01 gestoppt
   (Stop Redundant Project -> Primary & Secondary)?

Ja   = weiter (Snapshot + Updates auf allen 3 Servern)
Nein = Abbruch auf allen 3 Servern, nichts wird heruntergefahren
"@
        if ($antwort -eq 'Yes') {
            Set-Content -Path $ok -Value (Get-Date -Format s); Remove-Item $nein -ErrorAction SilentlyContinue
            Write-Log 'Bestaetigt (Ja) -> weiter.'; exit 0
        }
        Set-Content -Path $nein -Value (Get-Date -Format s)
        Write-Log 'Nein -> Abbruch.'; exit 1
    }

    # Phase Ende: A oder B?
    $lauf = if (Test-Path (Join-Path $Ordner "A_$Kurz")) { 'B' } else { 'A' }
    Set-Content -Path (Join-Path $Ordner "${lauf}_$Kurz") -Value (Get-Date -Format s)
    Write-Log "Lauf $lauf fertig."
    $fertig = @($Server | Where-Object { Test-Path (Join-Path $Ordner "${lauf}_$_") })
    $gezeigt = Join-Path $Ordner "Hinweis_$lauf"
    if ($fertig.Count -eq $Server.Count -and -not (Test-Path $gezeigt)) {
        Set-Content -Path $gezeigt -Value (Get-Date -Format s)
        if ($lauf -eq 'A') {
            $text = @"
Lauf A ist auf allen 3 Servern fertig (Snapshot + Updates).

Jetzt Lauf B starten:
1. Die 3 Server-Zeilen markieren
2. Actions -> Job queue -> Create/modify job queue
3. Saved Queues: PSG-Nachher doppelklicken
4. Apply queue to row(s) without executing -> Close
5. NUR die Zeile PSG-Nachher-Start markieren
6. Actions -> Job queue -> Execute advanced multi-row queue sequence
"@
        } else {
            $text = @"
Lauf B ist fertig: CIP_MASTER laeuft wieder, automatische Tests OK.

Jetzt manuell:
1. Workbench CIM-01: Statusleiste "Run SV-PSG-CIM-01 SV-PSG-CIM-02"
2. HIST-01, Historian Administrator -> Collectors:
   beide Running, einer Active / einer Standby
3. CIM-02: GefRedundancy -> MASTER und SLAVE Online
4. CIM-01 + CIM-02: KEPServerEX License Utility -> Siemens Suite = Good
5. Wartungsmodus in SuperOps beenden (3 Server)
6. Produktion informieren
"@
        }
        Write-Log "Hinweis Lauf $lauf angezeigt."
        [void](Show-Fenster -Titel "PSG-Patch: Lauf $lauf fertig" -Knoepfe OK -Symbol Information -Text $text)
    }
    exit 0
}
catch {
    Write-Log ("Fehler: {0}" -f $_.Exception.Message)
    exit 1
}
finally {
    try { $mutex.ReleaseMutex() } catch { }
    $mutex.Dispose()
}
