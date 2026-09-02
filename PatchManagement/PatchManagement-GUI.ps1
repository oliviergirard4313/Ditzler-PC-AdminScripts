#Requires -Version 5.1
<#
.SYNOPSIS
    Kleine GUI, die die beiden Schritte des manuellen Patch-Ablaufs fuer die
    4 manuellen Gruppen zusammenfasst (siehe SuperOps-Patch-Mechanik.md
    §6c): Serverliste live aus SuperOps abrufen
    (Get-AssetsByPatchCategory.ps1, intern per psexec -s auf SYSTEM
    erhoben) und danach Invoke-ManualPatchRun.ps1 fuer die ausgewaehlten
    Server starten.

.DESCRIPTION
    Unter dem normalen Admin-Konto starten (NICHT unter SYSTEM/psexec) -
    das ist der Kontext, den Invoke-ManualPatchRun.ps1 fuer WinRM zu den
    Zielservern braucht (Kerberos-Double-Hop bricht unter SYSTEM). Nur der
    interne Aufruf von Get-AssetsByPatchCategory.ps1 (Button "Server
    aktualisieren") wird gezielt per psexec -s auf SYSTEM angehoben
    (fuer credentials.xml/SuperOps-API), voellig getrennt vom restlichen
    Ablauf - dasselbe Muster wie die beiden separaten Skripte, nur in einem
    Fenster zusammengefasst.

    WICHTIG - "Als Administrator ausfuehren": psexec -s braucht selbst
    fuer eine rein lokale Erhoehung auf SYSTEM einen bereits erhoehten
    (High-Integrity-Token) aufrufenden Prozess, um den Dienst PSEXESVC
    installieren zu koennen - ohne das schlaegt der Button "Server
    aktualisieren" fehl oder loest mitten im Klick eine eigene UAC-Eingabe
    aus. Der WinRM-Teil (Start/Ueberwachung) braucht dagegen KEINE
    Erhoehung, nur den richtigen Domaenenbenutzer. Diese GUI prueft beim
    Start, ob sie erhoeht laeuft, und deaktiviert "Server aktualisieren"
    (mit Hinweis) falls nicht - der Rest (manuelle Serverliste, Start)
    bleibt trotzdem nutzbar.

    Von Claude Code nicht vollstaendig end-to-end testbar: psexec -s
    schlaegt in dessen eigener Sandbox-Umgebung mit "Couldn't install
    PSEXESVC service: The handle is invalid" fehl (bekannte Einschraenkung,
    siehe Ditzler-Memory). Vor dem ersten produktiven Einsatz bitte den
    Button "Server aktualisieren" einmal selbst pruefen. Falls psexec dort
    nicht mitspielt: alternativ Get-AssetsByPatchCategory.ps1 manuell per
    psexec -s ausfuehren und das Ergebnis ins Feld "Manuell" einfuegen -
    dieser Weg braucht kein psexec innerhalb der GUI.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'

$RepoDir            = "C:\Admin\Ditzler\PatchManagement"
$HelperScript       = Join-Path $RepoDir "Get-AssetsByPatchCategory.ps1"
$OrchestratorScript = Join-Path $RepoDir "Invoke-ManualPatchRun.ps1"

# psexec -s braucht selbst fuer eine lokale Erhoehung auf SYSTEM einen
# bereits erhoehten aufrufenden Prozess (installiert sonst seinen Dienst
# PSEXESVC nicht) - ohne "Als Administrator ausfuehren" wuerde der Button
# "Server aktualisieren" fehlschlagen oder eine eigene UAC-Eingabe mitten
# im Klick ausloesen. Der WinRM-Teil (Start/-Ueberwachung) braucht das
# nicht - deshalb hier nur den betroffenen Button sperren, nicht das
# ganze Fenster.
$IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$PsExecCandidates = @(
    "C:\ProgramData\chocolatey\bin\PsExec.exe",
    "C:\Tools\PsExec.exe"
)
$PsExecPath = $PsExecCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $PsExecPath) {
    $Cmd = Get-Command psexec.exe -ErrorAction SilentlyContinue
    if ($Cmd) { $PsExecPath = $Cmd.Source }
}

$KnownCategories = @(
    'SV_SW-Std_Manual-Update-Group-1',
    'SV_SW-Std_Manual-Update-Group-2',
    'SV_SW-Std_Manual-Update-Group-3',
    'SV_SW-Std_Manual-Update-Group-4'
)

# ---------------------------------------------------------
# Fenster + Steuerelemente
# ---------------------------------------------------------

$Form = New-Object System.Windows.Forms.Form
$Form.Text = "Ditzler - Manueller Patch-Lauf"
$Form.ClientSize = New-Object System.Drawing.Size(760, 730)
$Form.StartPosition = 'CenterScreen'
$Form.FormBorderStyle = 'FixedDialog'
$Form.MaximizeBox = $false

$LblCategory = New-Object System.Windows.Forms.Label
$LblCategory.Text = "Kategorie:"
$LblCategory.Location = New-Object System.Drawing.Point(10, 15)
$LblCategory.Size = New-Object System.Drawing.Size(80, 20)
$Form.Controls.Add($LblCategory)

$CmbCategory = New-Object System.Windows.Forms.ComboBox
$CmbCategory.Location = New-Object System.Drawing.Point(95, 12)
$CmbCategory.Size = New-Object System.Drawing.Size(300, 20)
$CmbCategory.DropDownStyle = 'DropDownList'
$KnownCategories | ForEach-Object { [void]$CmbCategory.Items.Add($_) }
$CmbCategory.SelectedIndex = 0
$Form.Controls.Add($CmbCategory)

$BtnRefresh = New-Object System.Windows.Forms.Button
$BtnRefresh.Text = "Server aktualisieren"
$BtnRefresh.Location = New-Object System.Drawing.Point(405, 10)
$BtnRefresh.Size = New-Object System.Drawing.Size(150, 25)
if (-not $IsElevated) {
    $BtnRefresh.Enabled = $false
    $BtnRefresh.Text = "Server aktualisieren (Admin noetig)"
    $Tooltip = New-Object System.Windows.Forms.ToolTip
    $Tooltip.SetToolTip($BtnRefresh, "Dieses Fenster wurde nicht 'Als Administrator ausfuehren' gestartet - psexec -s kann sonst SYSTEM nicht erreichen. Neu starten mit Rechtsklick > 'Als Administrator ausfuehren', oder das Feld 'Manuell' unten benutzen.")
}
$Form.Controls.Add($BtnRefresh)

$LblServers = New-Object System.Windows.Forms.Label
$LblServers.Text = "Gefundene Server (abwaehlen = ausschliessen):"
$LblServers.Location = New-Object System.Drawing.Point(10, 45)
$LblServers.Size = New-Object System.Drawing.Size(340, 20)
$Form.Controls.Add($LblServers)

# ListView statt CheckedListBox: braucht eine zweite, vom Servernamen
# getrennte Spalte fuer angemeldete Benutzer (siehe Set-LoggedOnUsers unten)
# - bei einem echten Reboot wird der Prozess ohne Rueckfrage per
# "shutdown /f" beendet (siehe Install-ManualPatches-Local.ps1), nicht
# gespeicherte Arbeit (z.B. offenes Notepad) ginge sonst kommentarlos
# verloren. Diese Spalte macht das VOR dem Start sichtbar, ersetzt aber
# keine harte technische Absicherung im Skript selbst (offener Punkt,
# siehe SuperOps-Patch-Mechanik.md §7).
$ChkListServers = New-Object System.Windows.Forms.ListView
$ChkListServers.Location = New-Object System.Drawing.Point(10, 68)
$ChkListServers.Size = New-Object System.Drawing.Size(340, 150)
$ChkListServers.View = 'Details'
$ChkListServers.CheckBoxes = $true
$ChkListServers.FullRowSelect = $true
$ChkListServers.GridLines = $true
[void]$ChkListServers.Columns.Add('Server', 150)
[void]$ChkListServers.Columns.Add('Angemeldete Benutzer', 175)
$Form.Controls.Add($ChkListServers)

# Server -> ob/welche Benutzer angemeldet sind, per WinRM abgefragt (quser) -
# braucht KEIN psexec/SYSTEM, normale WinRM-Rechte genuegen.
function Get-LoggedOnUsersText {
    param([string]$Server)
    try {
        $Raw = Invoke-Command -ComputerName $Server -ErrorAction Stop -ScriptBlock {
            & quser.exe 2>$null
        }
        if (-not $Raw) { return 'keine' }
        $Users = @($Raw | Select-Object -Skip 1 | ForEach-Object { ($_.Trim() -split '\s+')[0] } | Where-Object { $_ })
        if ($Users.Count -eq 0) { return 'keine' }
        return ($Users -join ', ')
    }
    catch {
        return 'unbekannt (WinRM-Fehler)'
    }
}

$LblManual = New-Object System.Windows.Forms.Label
$LblManual.Text = "Manuell (kommagetrennt, ueberschreibt Auswahl links):"
$LblManual.Location = New-Object System.Drawing.Point(360, 45)
$LblManual.Size = New-Object System.Drawing.Size(380, 20)
$Form.Controls.Add($LblManual)

$TxtManual = New-Object System.Windows.Forms.TextBox
$TxtManual.Location = New-Object System.Drawing.Point(360, 68)
$TxtManual.Size = New-Object System.Drawing.Size(380, 150)
$TxtManual.Multiline = $true
$TxtManual.ScrollBars = 'Vertical'
$Form.Controls.Add($TxtManual)

# Optionen (Standardwerte identisch zu Invoke-ManualPatchRun.ps1)

$LblMaxRounds = New-Object System.Windows.Forms.Label
$LblMaxRounds.Text = "MaxRounds:"
$LblMaxRounds.Location = New-Object System.Drawing.Point(10, 230)
$LblMaxRounds.Size = New-Object System.Drawing.Size(80, 20)
$Form.Controls.Add($LblMaxRounds)

$NumMaxRounds = New-Object System.Windows.Forms.NumericUpDown
$NumMaxRounds.Location = New-Object System.Drawing.Point(95, 228)
$NumMaxRounds.Size = New-Object System.Drawing.Size(50, 20)
$NumMaxRounds.Minimum = 1
$NumMaxRounds.Maximum = 5
$NumMaxRounds.Value = 2
$Form.Controls.Add($NumMaxRounds)

$LblMaxReboots = New-Object System.Windows.Forms.Label
$LblMaxReboots.Text = "MaxReboots:"
$LblMaxReboots.Location = New-Object System.Drawing.Point(160, 230)
$LblMaxReboots.Size = New-Object System.Drawing.Size(80, 20)
$Form.Controls.Add($LblMaxReboots)

$NumMaxReboots = New-Object System.Windows.Forms.NumericUpDown
$NumMaxReboots.Location = New-Object System.Drawing.Point(245, 228)
$NumMaxReboots.Size = New-Object System.Drawing.Size(50, 20)
$NumMaxReboots.Minimum = 0
$NumMaxReboots.Maximum = 5
$NumMaxReboots.Value = 2
$Form.Controls.Add($NumMaxReboots)

$LblPollSec = New-Object System.Windows.Forms.Label
$LblPollSec.Text = "InstallPollSeconds:"
$LblPollSec.Location = New-Object System.Drawing.Point(310, 230)
$LblPollSec.Size = New-Object System.Drawing.Size(115, 20)
$Form.Controls.Add($LblPollSec)

$NumPollSec = New-Object System.Windows.Forms.NumericUpDown
$NumPollSec.Location = New-Object System.Drawing.Point(425, 228)
$NumPollSec.Size = New-Object System.Drawing.Size(60, 20)
$NumPollSec.Minimum = 5
$NumPollSec.Maximum = 300
$NumPollSec.Value = 30
$Form.Controls.Add($NumPollSec)

$LblMaxWait = New-Object System.Windows.Forms.Label
$LblMaxWait.Text = "InstallMaxWaitMinutes:"
$LblMaxWait.Location = New-Object System.Drawing.Point(500, 230)
$LblMaxWait.Size = New-Object System.Drawing.Size(140, 20)
$Form.Controls.Add($LblMaxWait)

$NumMaxWait = New-Object System.Windows.Forms.NumericUpDown
$NumMaxWait.Location = New-Object System.Drawing.Point(640, 228)
$NumMaxWait.Size = New-Object System.Drawing.Size(60, 20)
$NumMaxWait.Minimum = 1
$NumMaxWait.Maximum = 180
$NumMaxWait.Value = 45
$Form.Controls.Add($NumMaxWait)

$ChkWhatIf = New-Object System.Windows.Forms.CheckBox
$ChkWhatIf.Text = "-WhatIf (nur simulieren, nichts installieren/rebooten)"
$ChkWhatIf.Location = New-Object System.Drawing.Point(10, 260)
$ChkWhatIf.Size = New-Object System.Drawing.Size(400, 20)
$Form.Controls.Add($ChkWhatIf)

$BtnStart = New-Object System.Windows.Forms.Button
$BtnStart.Text = "Start"
$BtnStart.Location = New-Object System.Drawing.Point(10, 290)
$BtnStart.Size = New-Object System.Drawing.Size(150, 30)
$BtnStart.BackColor = [System.Drawing.Color]::LightGreen
$Form.Controls.Add($BtnStart)

$BtnCancel = New-Object System.Windows.Forms.Button
$BtnCancel.Text = "Abbrechen"
$BtnCancel.Location = New-Object System.Drawing.Point(170, 290)
$BtnCancel.Size = New-Object System.Drawing.Size(150, 30)
$BtnCancel.Enabled = $false
$Form.Controls.Add($BtnCancel)

$LblStatus = New-Object System.Windows.Forms.Label
$LblStatus.Text = "Bereit."
$LblStatus.Location = New-Object System.Drawing.Point(340, 296)
$LblStatus.Size = New-Object System.Drawing.Size(400, 20)
$Form.Controls.Add($LblStatus)

$LblGrid = New-Object System.Windows.Forms.Label
$LblGrid.Text = "Status pro Server (direkt von den Zielservern gelesen, unabhaengig vom Log unten):"
$LblGrid.Location = New-Object System.Drawing.Point(10, 326)
$LblGrid.Size = New-Object System.Drawing.Size(600, 20)
$Form.Controls.Add($LblGrid)

$GridStatus = New-Object System.Windows.Forms.DataGridView
$GridStatus.Location = New-Object System.Drawing.Point(10, 348)
$GridStatus.Size = New-Object System.Drawing.Size(730, 170)
$GridStatus.ReadOnly = $true
$GridStatus.AllowUserToAddRows = $false
$GridStatus.AllowUserToDeleteRows = $false
$GridStatus.AllowUserToResizeRows = $false
$GridStatus.RowHeadersVisible = $false
$GridStatus.SelectionMode = 'FullRowSelect'
$GridStatus.AutoSizeColumnsMode = 'Fill'
[void]$GridStatus.Columns.Add('Server', 'Server')
[void]$GridStatus.Columns.Add('Status', 'Status')
[void]$GridStatus.Columns.Add('Runde', 'Runde')
[void]$GridStatus.Columns.Add('Reboots', 'Reboots')
[void]$GridStatus.Columns.Add('LetzterSchritt', 'Letzter Schritt')
[void]$GridStatus.Columns.Add('Aktualisiert', 'Aktualisiert')
$GridStatus.Columns['Server'].FillWeight = 18
$GridStatus.Columns['Status'].FillWeight = 14
$GridStatus.Columns['Runde'].FillWeight = 8
$GridStatus.Columns['Reboots'].FillWeight = 8
$GridStatus.Columns['LetzterSchritt'].FillWeight = 40
$GridStatus.Columns['Aktualisiert'].FillWeight = 12
$Form.Controls.Add($GridStatus)

# Server -> Zeilenindex, damit Status-Updates die richtige Zeile treffen
# statt bei jedem Poll die ganze Tabelle neu aufzubauen (haette den
# Bildschirm bei jedem Tick "aufblitzen" lassen und die Auswahl/Sortierung
# des Benutzers zerstoert).
$script:GridRowByServer = @{}

function Set-ServerStatus {
    param($Server, $Status, $Runde, $Reboots, $LetzterSchritt)
    if (-not $script:GridRowByServer.ContainsKey($Server)) {
        $Idx = $GridStatus.Rows.Add()
        $script:GridRowByServer[$Server] = $Idx
        $GridStatus.Rows[$Idx].Cells['Server'].Value = $Server
    }
    $Row = $GridStatus.Rows[$script:GridRowByServer[$Server]]
    $Row.Cells['Status'].Value = $Status
    if ($null -ne $Runde) { $Row.Cells['Runde'].Value = $Runde }
    if ($null -ne $Reboots) { $Row.Cells['Reboots'].Value = $Reboots }
    if ($LetzterSchritt) { $Row.Cells['LetzterSchritt'].Value = $LetzterSchritt }
    $Row.Cells['Aktualisiert'].Value = (Get-Date -Format 'HH:mm:ss')

    $Farbe = switch -Wildcard ($Status) {
        'Installiert*'  { [System.Drawing.Color]::LightGreen }
        'Fehler*'       { [System.Drawing.Color]::LightCoral }
        'Nicht*'        { [System.Drawing.Color]::LightSalmon }
        'Neustart*'     { [System.Drawing.Color]::LightSkyBlue }
        'Installation*' { [System.Drawing.Color]::LightYellow }
        'Scan*'         { [System.Drawing.Color]::LightYellow }
        default         { [System.Drawing.Color]::White }
    }
    $Row.DefaultCellStyle.BackColor = $Farbe
}

$TxtLog = New-Object System.Windows.Forms.TextBox
$TxtLog.Location = New-Object System.Drawing.Point(10, 526)
$TxtLog.Size = New-Object System.Drawing.Size(730, 190)
$TxtLog.Multiline = $true
$TxtLog.ScrollBars = 'Vertical'
$TxtLog.ReadOnly = $true
$TxtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$Form.Controls.Add($TxtLog)

function Add-Log {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $TxtLog.AppendText("$Text`r`n")
}

# ---------------------------------------------------------
# "Server aktualisieren" - psexec -s Get-AssetsByPatchCategory.ps1 -Json
# ---------------------------------------------------------

$BtnRefresh.Add_Click({
    if (-not $IsElevated) {
        [System.Windows.Forms.MessageBox]::Show(
            "Dieses Fenster laeuft nicht erhoeht - psexec -s kann SYSTEM ohne 'Als Administrator ausfuehren' nicht erreichen. Fenster schliessen und per Rechtsklick > 'Als Administrator ausfuehren' neu starten, oder das Feld 'Manuell' unten benutzen.",
            "Administratorrechte noetig", 'OK', 'Warning')
        return
    }
    if (-not $PsExecPath) {
        [System.Windows.Forms.MessageBox]::Show(
            "PsExec.exe nicht gefunden (Chocolatey-Pfad und PATH geprueft). Liste kann nicht live abgerufen werden - Get-AssetsByPatchCategory.ps1 manuell per psexec -s ausfuehren und das Ergebnis ins Feld 'Manuell' einfuegen.",
            "Fehler", 'OK', 'Error')
        return
    }
    $Category = $CmbCategory.SelectedItem
    $LblStatus.Text = "Frage SuperOps ab..."
    $Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $BtnRefresh.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()

    # WICHTIG: kein "& $PsExecPath ... 2>&1" - PsExec schreibt seine eigenen
    # Statuszeilen ("Connecting to local system...") auf STDERR, und unter
    # Windows PowerShell wird jede per 2>&1 umgeleitete STDERR-Zeile eines
    # nativen Programms als ErrorRecord in die Pipeline gestellt - bei
    # $ErrorActionPreference = 'Stop' (siehe Kopf dieses Skripts) bricht
    # bereits die ERSTE solche Zeile die ganze Zuweisung sofort ab, bevor
    # die eigentliche -Json-Ausgabe je ankommt (beobachtet 27.08.2026 -
    # Fehlermeldung war woertlich "Connecting to local system..."). Deshalb
    # hier STDOUT/STDERR sauber in getrennte Dateien umleiten statt sie in
    # der Pipeline zu mischen.
    $StdOutFile = [System.IO.Path]::GetTempFileName()
    $StdErrFile = [System.IO.Path]::GetTempFileName()
    # Ergebnisdatei bewusst in C:\Windows\Temp: das Hilfsskript laeuft per
    # psexec -s als SYSTEM und muss dort hineinschreiben koennen, waehrend
    # diese GUI (normaler Admin) sie danach lesen muss - auf beides trifft
    # das bei C:\Windows\Temp zu.
    $ResultFile = Join-Path $env:SystemRoot "Temp\PatchMgmtGui_$([Guid]::NewGuid().ToString('N')).json"
    try {
        # Kein "-i": der interaktive Modus haengt den Prozess an die
        # Benutzersitzung/Desktop, wodurch dessen Ausgabe NICHT mehr in die
        # umgeleiteten stdout/stderr-Dateien zurueckkommt - beobachtet
        # 27.08.2026: ExitCode=0, aber ueberhaupt keine Skriptausgabe
        # gefangen (nur PsExecs eigene Statuszeilen). Interaktivitaet wird
        # hier gar nicht gebraucht (kein UI, nur Text zurueck), deshalb nur
        # "-s" fuer die SYSTEM-Erhoehung.
        # Interpreter nicht fest verdrahten: pwsh.exe (PowerShell 7) fehlt
        # auf frisch aufgesetzten/nie gepatchten Servern (es kommt meist
        # erst per Windows Update) - dann muss powershell.exe einspringen,
        # sonst schlaegt der Button auf so einem Rechner fehl. Dasselbe
        # Problem war schon bei Invoke-ManualPatchRun.ps1 aufgetreten
        # (siehe dessen -Interpreter-Parameter).
        $InterpreterPath = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) {
            (Get-Command pwsh.exe).Source
        } else {
            (Get-Command powershell.exe).Source
        }
        # Ergebnis ueber eine Datei holen (-OutFile), nicht ueber STDOUT:
        # Ditzler-Powershell-Lib.psm1 schreibt eigene Log- und Fehlerzeilen
        # nach STDOUT, die sich nicht abschalten lassen und die JSON-Ausgabe
        # zerstoeren wuerden (beobachtet 27.08.2026). STDOUT/STDERR werden
        # weiterhin geloggt, aber nur noch zur Diagnose.
        $ArgList = @('-accepteula', '-nobanner', '-s', $InterpreterPath, '-NoProfile', '-File', "`"$HelperScript`"", '-Category', "`"$Category`"", '-OutFile', "`"$ResultFile`"")
        $Proc = Start-Process -FilePath $PsExecPath -ArgumentList $ArgList -RedirectStandardOutput $StdOutFile -RedirectStandardError $StdErrFile -NoNewWindow -Wait -PassThru
        $StdOut = @(Get-Content -LiteralPath $StdOutFile -ErrorAction SilentlyContinue)
        $StdErr = @(Get-Content -LiteralPath $StdErrFile -ErrorAction SilentlyContinue)

        Add-Log "--- psexec stdout (Server aktualisieren, ExitCode=$($Proc.ExitCode)) ---"
        $StdOut | ForEach-Object { Add-Log "  $_" }
        if ($StdErr) {
            Add-Log "--- psexec stderr ---"
            $StdErr | ForEach-Object { Add-Log "  $_" }
        }

        # Ursache eines Fehlschlags kann in BEIDEN Kanaelen stehen: eigene
        # Fehlermeldungen des Hilfsskripts auf stderr, Meldungen der
        # Ditzler-Powershell-Lib (z.B. "Key not valid for use in specified
        # state" bei fehlgeschlagener DPAPI-Entschluesselung) dagegen auf
        # stdout - beide werden oben ins Log geschrieben.
        if (-not (Test-Path -LiteralPath $ResultFile)) {
            throw "Das Hilfsskript hat keine Ergebnisdatei geschrieben (ExitCode=$($Proc.ExitCode)). Ursache siehe stdout/stderr im Log oben."
        }
        if ($Proc.ExitCode -ne 0) {
            throw "Hilfsskript mit ExitCode=$($Proc.ExitCode) beendet - Ursache siehe stdout/stderr im Log oben."
        }
        $JsonLine = (Get-Content -LiteralPath $ResultFile -Raw).Trim()
        if (-not $JsonLine) {
            throw "Ergebnisdatei ist leer (ExitCode=$($Proc.ExitCode)) - siehe Log oben."
        }
        # [string[]]-Cast statt nur @(...): ConvertFrom-Json gibt unter
        # Windows PowerShell 5.1 ein Array als EIN Objekt weiter (rollt es
        # nicht aus), @() macht daraus also ein 1-elementiges Array, das das
        # eigentliche Array enthaelt - die foreach-Schleife unten haette
        # dann das ganze Array statt einzelner Servernamen bekommen
        # (beobachtet 27.08.2026: "Cannot find an overload for ListViewItem
        # and the argument count: 7" bei 7 Servern in Gruppe 1, weil
        # New-Object ein Array als Argumentliste auffasst und splattet).
        $Servers = @([string[]](ConvertFrom-Json -InputObject $JsonLine))

        $ChkListServers.Items.Clear()
        $LblStatus.Text = "Pruefe angemeldete Benutzer..."
        foreach ($s in $Servers) {
            [System.Windows.Forms.Application]::DoEvents()
            $Angemeldet = Get-LoggedOnUsersText -Server $s
            # ::new([string]...) statt New-Object ...($s): New-Object fasst
            # ein Array in Klammern als Argumentliste auf und splattet es
            # (siehe Kommentar beim $Servers-Cast oben) - der explizite
            # Cast auf [string] macht das strukturell unmoeglich.
            $Item = [System.Windows.Forms.ListViewItem]::new([string]$s)
            [void]$Item.SubItems.Add($Angemeldet)
            $Item.Checked = $true
            if ($Angemeldet -notin @('keine', 'unbekannt (WinRM-Fehler)')) {
                $Item.BackColor = [System.Drawing.Color]::LightSalmon
                Add-Log "WARNUNG: $s hat angemeldete(n) Benutzer: $Angemeldet - beim Reboot wird per 'shutdown /f' erzwungen beendet, nicht gespeicherte Arbeit geht verloren."
            }
            [void]$ChkListServers.Items.Add($Item)
        }

        $LblStatus.Text = "$($Servers.Count) Server gefunden fuer $Category."
        Add-Log "$($Servers.Count) Server gefunden fuer '$Category'."
    }
    catch {
        $LblStatus.Text = "Fehler beim Abrufen der Serverliste."
        Add-Log "FEHLER: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Fehler beim Abrufen der Serverliste", 'OK', 'Error')
    }
    finally {
        Remove-Item -LiteralPath $StdOutFile, $StdErrFile, $ResultFile -Force -ErrorAction SilentlyContinue
        $Form.Cursor = [System.Windows.Forms.Cursors]::Default
        $BtnRefresh.Enabled = $true
    }
})

# ---------------------------------------------------------
# "Start" - Invoke-ManualPatchRun.ps1 im Hintergrund-Job starten + pollen
# ---------------------------------------------------------

$script:Job = $null
$script:StatusJob = $null
$script:RunId = $null

# ---------------------------------------------------------
# Status-Polling-Job - liest state.json/laststep.txt DIREKT auf jedem
# Zielserver per WinRM (unabhaengig vom Log-Job oben), damit die Tabelle
# einen dynamischen Status pro Server anzeigen kann (Scan/Installation/
# Neustart/Installiert/Fehler), statt nur auf den Konsolentext von
# Invoke-ManualPatchRun.ps1 angewiesen zu sein. Erst startbar, sobald die
# RunId bekannt ist (wird von Invoke-ManualPatchRun.ps1 selbst erst zur
# Laufzeit erzeugt, siehe dessen Zeile "RunId fuer diesen Lauf: ...").
function Start-StatusPollingJob {
    param([string[]]$Servers, [string]$RunId)

    Start-Job -ScriptBlock {
        param($Servers, $RunId)
        while ($true) {
            foreach ($Srv in $Servers) {
                $Result = [ordered]@{ Server = $Srv; Status = ''; Runde = $null; Reboots = $null; LetzterSchritt = '' }
                try {
                    $Data = Invoke-Command -ComputerName $Srv -ErrorAction Stop -ScriptBlock {
                        param($RunId)
                        $Dir = "C:\ProgramData\Superops\Scripts\_ManualPatchRun\$RunId"
                        $State = $null
                        $Step = ''
                        $StateFile = Join-Path $Dir 'state.json'
                        $StepFile  = Join-Path $Dir 'laststep.txt'
                        if (Test-Path -LiteralPath $StateFile) {
                            try { $State = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { }
                        }
                        if (Test-Path -LiteralPath $StepFile) {
                            try { $Step = Get-Content -LiteralPath $StepFile -Raw } catch { }
                        }
                        [PSCustomObject]@{ State = $State; Step = $Step }
                    } -ArgumentList $RunId

                    $Result.LetzterSchritt = ($Data.Step -replace '[\r\n]+', ' ').Trim()

                    if ($Data.State) {
                        $Result.Runde   = $Data.State.RoundsDone
                        $Result.Reboots = $Data.State.RebootsDone
                        switch ($Data.State.Status) {
                            'WaitingReboot' { $Result.Status = 'Neustart laeuft' }
                            'Completed'     { $Result.Status = 'Installiert (abgeschlossen)' }
                            'Failed'        { $Result.Status = 'Fehler' }
                            default {
                                if ($Result.LetzterSchritt -match 'StartInstall|Poll nach|aktiv installierend') { $Result.Status = 'Installation laeuft' }
                                elseif ($Result.LetzterSchritt -match 'Search\(\)|Suche nach|Get-PendingUpdates') { $Result.Status = 'Scan laeuft' }
                                else { $Result.Status = 'Laeuft' }
                            }
                        }
                    }
                    else {
                        $Result.Status = 'Wird gestartet...'
                    }
                }
                catch {
                    # Waehrend eines echten Reboots ist das genau erwartet
                    # (WinRM kurzzeitig nicht erreichbar) - kein Fehlerstatus,
                    # sondern ein plausibler Hinweis darauf.
                    $Result.Status = 'Nicht erreichbar (evtl. Neustart)'
                    $Result.LetzterSchritt = $_.Exception.Message
                }
                [PSCustomObject]$Result
            }
            Start-Sleep -Seconds 10
        }
    } -ArgumentList $Servers, $RunId
}

$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = 1000

$Timer.Add_Tick({
    if (-not $script:Job) { return }

    # Alle seit dem letzten Tick angefallenen Objekte auf einmal durch
    # Out-String schicken statt einzeln - sonst zerreisst es die
    # Format-Table-Zusammenfassung von Invoke-ManualPatchRun.ps1 (Header +
    # Zeilen muessen zusammen gerendert werden, sonst geht die Ausrichtung
    # verloren).
    $Neu = Receive-Job -Job $script:Job -ErrorAction SilentlyContinue
    if ($Neu) {
        Add-Log (($Neu | Out-String).TrimEnd())

        if (-not $script:RunId) {
            $Fund = $Neu | Where-Object { $_ -replace '^\[.*\]\s*', '' -match 'RunId fuer diesen Lauf:\s*(\S+)' } | Select-Object -First 1
            if ($Fund -and $Matches[1]) {
                $script:RunId = $Matches[1]
                $script:StatusJob = Start-StatusPollingJob -Servers $script:CurrentTargets -RunId $script:RunId
            }
        }
    }

    if ($script:StatusJob) {
        $StatusUpdates = Receive-Job -Job $script:StatusJob -ErrorAction SilentlyContinue
        foreach ($U in $StatusUpdates) {
            Set-ServerStatus -Server $U.Server -Status $U.Status -Runde $U.Runde -Reboots $U.Reboots -LetzterSchritt $U.LetzterSchritt
        }
    }

    if ($script:Job.State -in @('Completed', 'Failed', 'Stopped')) {
        $Timer.Stop()
        $Rest = Receive-Job -Job $script:Job -ErrorAction SilentlyContinue
        if ($Rest) { Add-Log (($Rest | Out-String).TrimEnd()) }
        Add-Log "--- Lauf beendet: $($script:Job.State) ---"
        $LblStatus.Text = "Beendet: $($script:Job.State)"
        Remove-Job -Job $script:Job -Force -ErrorAction SilentlyContinue
        $script:Job = $null
        if ($script:StatusJob) {
            Stop-Job -Job $script:StatusJob -ErrorAction SilentlyContinue
            Remove-Job -Job $script:StatusJob -Force -ErrorAction SilentlyContinue
            $script:StatusJob = $null
        }
        $BtnStart.Enabled = $true
        $BtnCancel.Enabled = $false
    }
})

$BtnStart.Add_Click({
    $Manual = $TxtManual.Text.Trim()
    $MitAngemeldetenBenutzern = @()
    if ($Manual) {
        $Targets = @($Manual -split '[,;\s]+' | Where-Object { $_ })
    }
    else {
        $Targets = @($ChkListServers.CheckedItems | ForEach-Object { $_.Text })
        $MitAngemeldetenBenutzern = @($ChkListServers.CheckedItems | Where-Object { $_.SubItems[1].Text -notin @('keine', 'unbekannt (WinRM-Fehler)') } | ForEach-Object { "$($_.Text) ($($_.SubItems[1].Text))" })
    }

    if ($Targets.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Keine Server ausgewaehlt (weder Liste links noch Feld 'Manuell').", "Hinweis", 'OK', 'Warning')
        return
    }

    $WarnText = ''
    if ($MitAngemeldetenBenutzern.Count -gt 0 -and -not $ChkWhatIf.Checked) {
        $WarnText = "`r`n`r`nACHTUNG: angemeldete Benutzer auf folgenden Servern - ein Reboot wuerde per 'shutdown /f' erzwungen, nicht gespeicherte Arbeit geht dabei verloren:`r`n$($MitAngemeldetenBenutzern -join "`r`n")"
    }

    $Confirm = [System.Windows.Forms.MessageBox]::Show(
        "Patch-Lauf starten fuer $($Targets.Count) Server:`r`n$($Targets -join ", ")`r`n`r`nWhatIf: $($ChkWhatIf.Checked)$WarnText",
        "Bestaetigen", 'YesNo', $(if ($WarnText) { 'Warning' } else { 'Question' }))
    if ($Confirm -ne 'Yes') { return }

    $Params = @{
        ServerList            = $Targets
        MaxRounds             = [int]$NumMaxRounds.Value
        MaxReboots            = [int]$NumMaxReboots.Value
        InstallPollSeconds    = [int]$NumPollSec.Value
        InstallMaxWaitMinutes = [int]$NumMaxWait.Value
    }
    if ($ChkWhatIf.Checked) { $Params.WhatIf = $true }

    Add-Log "--- Starte Invoke-ManualPatchRun.ps1 fuer: $($Targets -join ', ') ---"

    # Tabelle fuer den neuen Lauf zuruecksetzen und sofort mit den Zielen
    # befuellen (Status "Wird gestartet..."), noch bevor irgendein Poll
    # zurueckkommt - RunId ist erst bekannt, sobald Invoke-ManualPatchRun.ps1
    # sie selbst ausgibt (siehe Timer weiter unten).
    $GridStatus.Rows.Clear()
    $script:GridRowByServer = @{}
    foreach ($t in $Targets) { Set-ServerStatus -Server $t -Status 'Wird gestartet...' -Runde $null -Reboots $null -LetzterSchritt '' }
    $script:CurrentTargets = $Targets
    $script:RunId = $null
    $script:StatusJob = $null

    $script:Job = Start-Job -ScriptBlock {
        param($ScriptPath, $ScriptParams)
        & $ScriptPath @ScriptParams *>&1
    } -ArgumentList $OrchestratorScript, $Params

    $BtnStart.Enabled = $false
    $BtnCancel.Enabled = $true
    $LblStatus.Text = "Laeuft..."
    $Timer.Start()
})

$BtnCancel.Add_Click({
    if ($script:Job) {
        Add-Log "--- Abbruch angefordert - stoppt nur die lokale Ueberwachung hier, bereits auf den Zielservern gestartete Installationen/Reboots laufen unabhaengig weiter ---"
        Stop-Job -Job $script:Job -ErrorAction SilentlyContinue
        $Timer.Stop()
        Remove-Job -Job $script:Job -Force -ErrorAction SilentlyContinue
        $script:Job = $null
        if ($script:StatusJob) {
            Stop-Job -Job $script:StatusJob -ErrorAction SilentlyContinue
            Remove-Job -Job $script:StatusJob -Force -ErrorAction SilentlyContinue
            $script:StatusJob = $null
        }
        $BtnStart.Enabled = $true
        $BtnCancel.Enabled = $false
        $LblStatus.Text = "Abgebrochen (lokal)."
    }
})

$Form.Add_FormClosing({
    if ($script:Job) {
        Stop-Job -Job $script:Job -ErrorAction SilentlyContinue
        Remove-Job -Job $script:Job -Force -ErrorAction SilentlyContinue
    }
    if ($script:StatusJob) {
        Stop-Job -Job $script:StatusJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:StatusJob -Force -ErrorAction SilentlyContinue
    }
})

[void]$Form.ShowDialog()
