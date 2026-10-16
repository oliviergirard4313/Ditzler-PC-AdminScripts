<#
.SYNOPSIS
    AD-Verwaltung – Benutzer anlegen/kopieren, Entra-Sync, M365-Lizenz und Diagnose (WPF-GUI).

.DESCRIPTION
    Ersetzt Copy-ADUser.ps1 und Repair-ADUser.ps1.

    Registerkarte "Benutzer anlegen / kopieren":
      - Namensvorschlag nach Ditzler-Konvention: SAM = vorname.nachname (+1..n falls belegt),
        UPN = Mail = SAM@ditzler.ch, Anzeigename = "Nachname Vorname"
      - Optionale Vorlage wie "Kopieren" in ADUC: gleiche OU, alle Gruppen, Organisations- und
        Adressattribute (ohne Titel, ohne extensionAttribute*, ohne msExch*-Altlasten)
      - Danach: AD-Replikation des Objekts, Delta-Sync auf dem Entra-Connect-Server,
        Warten auf das Entra-Objekt, UsageLocation setzen, Lizenz zuweisen
      - Zugangsblatt drucken (Benutzer, Mail, Initialpasswort, Regeln der effektiven FGPP)

    Registerkarte "Diagnose":
      - Prüft einen einzelnen Benutzer in AD und Entra ID; jede behebbare Abweichung hat
        einen Button "Korrigieren" mit Vorschau vorher/nachher

    Geschützte Konten (adm_*, srv_*, src_*, semservice, somservice) werden nie verändert.
    Alle Aktionen werden in C:\Service\AD-Verwaltung\logs protokolliert (ohne Passwörter).

.NOTES
    Ausführung : SV-OS-MGT-11, als Domain-Admin
    Ablage     : C:\Service\AD-Verwaltung\AD-Verwaltung.ps1
    Benötigt   : RSAT ActiveDirectory, Modul Microsoft.Graph.Authentication,
                 WinRM-Zugriff auf den Entra-Connect-Server
    M365-Konto : braucht mindestens die Rollen "User Administrator" + "License Administrator"
#>

#Requires -Version 5.1
#Requires -Modules ActiveDirectory

[CmdletBinding()]
param()

# WPF braucht einen STA-Thread – sonst neu starten
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    return
}

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, ReachFramework, System.Printing
Import-Module ActiveDirectory

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------
$Config = [ordered]@{
    Firmenname           = 'Louis Ditzler AG'
    MailDomain           = 'ditzler.ch'
    # Hier werden die Ziel-OUs für neue Benutzer gesucht (nur OUs namens SyncOuName)
    BenutzerOuBasis      = 'OU=01_Normal-Users,OU=01_Users_W11,DC=ditzlernet,DC=local'
    SyncOuName           = 'Sync-O365'
    EntraConnectServer   = 'SV-OS-ADC-11'
    UsageLocation        = 'CH'
    # FGPP für normale Benutzer (Prüfung + Korrektur in der Diagnose)
    BenutzerFgpp         = 'Prod-Users-FGPP'
    GeschuetzteKonten    = @('adm_*', 'srv_*', 'src_*', 'semservice', 'somservice')
    LogVerzeichnis       = 'C:\Service\AD-Verwaltung\logs'
    SyncTimeoutMinuten   = 15
    EntraWarteMinuten    = 5
    InitialPasswortTage  = 7
    GraphScopes          = @('User.ReadWrite.All', 'Organization.Read.All')
    # Wie "Kopieren" in ADUC, ohne title, extensionAttribute*, msExch*, RADIUS/NPS, BitLocker/TPM
    KopierAttribute      = @(
        'company', 'department', 'division', 'manager',
        'streetAddress', 'postOfficeBox', 'l', 'st', 'postalCode', 'c', 'co', 'countryCode',
        'scriptPath', 'profilePath', 'homeDirectory', 'homeDrive',
        'logonHours', 'userWorkstations', 'accountExpires'
    )
    # In diesen Attributen wird der SAM der Vorlage durch den neuen SAM ersetzt (%username%)
    SamErsetzenIn        = @('scriptPath', 'profilePath', 'homeDirectory')
}

# Gratis-/Viral-SKUs, die nicht zur Auswahl stehen sollen
$KostenloseSkus = @(
    'FLOW_FREE', 'POWER_BI_STANDARD', 'TEAMS_EXPLORATORY', 'WINDOWS_STORE', 'STREAM', 'POWERAPPS_VIRAL',
    'POWERAPPS_DEV', 'CCIBOTS_PRIVPREV_VIRAL', 'RIGHTSMANAGEMENT_ADHOC', 'MICROSOFT_BUSINESS_CENTER',
    'Power_Pages_vTrial_for_Makers', 'DEVELOPERPACK_E5', 'MCOPSTNC'
)

$SkuNamen = @{
    'SPB'                      = 'Microsoft 365 Business Premium'
    'O365_BUSINESS_PREMIUM'    = 'Microsoft 365 Business Standard'
    'O365_BUSINESS_ESSENTIALS' = 'Microsoft 365 Business Basic'
    'O365_BUSINESS'            = 'Microsoft 365 Apps for Business'
    'OFFICESUBSCRIPTION'       = 'Microsoft 365 Apps for Enterprise'
    'SPE_E3'                   = 'Microsoft 365 E3'
    'SPE_E5'                   = 'Microsoft 365 E5'
    'SPE_F1'                   = 'Microsoft 365 F3'
    'M365_F1'                  = 'Microsoft 365 F1'
    'ENTERPRISEPACK'           = 'Office 365 E3'
    'STANDARDPACK'             = 'Office 365 E1'
    'DESKLESSPACK'             = 'Office 365 F3'
    'EXCHANGESTANDARD'         = 'Exchange Online (Plan 1)'
    'EXCHANGEENTERPRISE'       = 'Exchange Online (Plan 2)'
    'EXCHANGEDESKLESS'         = 'Exchange Online Kiosk'
    'POWER_BI_PRO'             = 'Power BI Pro'
    'PBI_PREMIUM_PER_USER'     = 'Power BI Premium per User'
    'VISIOCLIENT'              = 'Visio Plan 2'
    'PROJECTPROFESSIONAL'      = 'Project Plan 3'
    'MCOEV'                    = 'Teams Phone Standard'
    'Microsoft_Teams_Premium'  = 'Teams Premium'
    'AAD_PREMIUM'              = 'Entra ID P1'
    'AAD_PREMIUM_P2'           = 'Entra ID P2'
    'EMS'                      = 'Enterprise Mobility + Security E3'
    'Microsoft_365_Copilot'    = 'Microsoft 365 Copilot'
}

# ---------------------------------------------------------------------------
# Zustand
# ---------------------------------------------------------------------------
$script:DC                = (Get-ADDomain).PDCEmulator
$script:Window            = $null
$script:Ui                = @{}
$script:Beschaeftigt      = $false
$script:GraphVerbunden    = $false
$script:GraphKonto        = ''
$script:AlleSkus          = @()
$script:Vorlage           = $null
$script:LetzterBenutzer   = $null
$script:DiagnoseDn        = $null

# ---------------------------------------------------------------------------
# Protokoll und UI-Hilfen
# ---------------------------------------------------------------------------
function Update-Ui {
    if ($script:Window) {
        $script:Window.Dispatcher.Invoke([Action] {}, [System.Windows.Threading.DispatcherPriority]::Background)
    }
}

# Wartet, ohne die Oberfläche einzufrieren
function Wait-Ui {
    param([int]$Sekunden)
    $ende = (Get-Date).AddSeconds($Sekunden)
    while ((Get-Date) -lt $ende) {
        Start-Sleep -Milliseconds 200
        Update-Ui
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Nachricht,
        [ValidateSet('INFO', 'OK', 'WARNUNG', 'FEHLER', 'SIM')][string]$Stufe = 'INFO'
    )
    $zeile = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Stufe, $Nachricht
    try {
        if (-not (Test-Path -LiteralPath $Config.LogVerzeichnis)) {
            New-Item -ItemType Directory -Path $Config.LogVerzeichnis -Force | Out-Null
        }
        $datei = Join-Path $Config.LogVerzeichnis ('AD-Verwaltung_{0:yyyy-MM}.log' -f (Get-Date))
        Add-Content -LiteralPath $datei -Value "$zeile [$env:USERDOMAIN\$env:USERNAME@$env:COMPUTERNAME]" -Encoding UTF8
    }
    catch {
        # Protokolldatei nicht schreibbar – Anzeige in der GUI reicht dann
    }
    if ($script:Ui.ContainsKey('txtLog')) {
        $script:Ui.txtLog.AppendText("$zeile`r`n")
        $script:Ui.txtLog.ScrollToEnd()
        Update-Ui
    }
}

function Show-Meldung {
    param([string]$Text, [string]$Titel = 'AD-Verwaltung', [string]$Symbol = 'Information')
    [void][System.Windows.MessageBox]::Show($script:Window, $Text, $Titel, 'OK', $Symbol)
}

function Confirm-Aktion {
    param([string]$Text, [string]$Titel = 'Bestätigung', [string]$Symbol = 'Question')
    return ([System.Windows.MessageBox]::Show($script:Window, $Text, $Titel, 'YesNo', $Symbol) -eq 'Yes')
}

function Test-Simulation {
    return ($script:Ui.chkSimulation.IsChecked -eq $true)
}

# Führt eine GUI-Aktion aus: Sanduhr, Fehleranzeige, Schutz gegen Doppelklick
function Invoke-UiAktion {
    param([Parameter(Mandatory)][scriptblock]$Aktion)
    if ($script:Beschaeftigt) { return }
    $script:Beschaeftigt = $true
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        & $Aktion
    }
    catch {
        Write-Log "Fehler: $($_.Exception.Message)" 'FEHLER'
        Show-Meldung -Text $_.Exception.Message -Titel 'Fehler' -Symbol 'Error'
    }
    finally {
        $script:Beschaeftigt = $false
        $script:Window.Cursor = $null
    }
}

# Auswahl-Dialog (Lizenz, FGPP-Gruppe ...); gibt das gewählte Element oder $null zurück
function Show-AuswahlDialog {
    param([string]$Titel, [string]$Text, [object[]]$Eintraege)
    $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="560" Height="380" WindowStartupLocation="CenterOwner" ResizeMode="NoResize"
        FontFamily="Segoe UI" FontSize="13">
  <DockPanel Margin="12">
    <TextBlock x:Name="lblText" DockPanel.Dock="Top" TextWrapping="Wrap" Margin="0,0,0,8"/>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Button x:Name="btnOk" Content="OK" Width="100" Margin="4" IsDefault="True"/>
      <Button Content="Abbrechen" Width="100" Margin="4" IsCancel="True"/>
    </StackPanel>
    <ListBox x:Name="lstAuswahl" DisplayMemberPath="Anzeige"/>
  </DockPanel>
</Window>
'@
    $dlg = [System.Windows.Markup.XamlReader]::Parse($xaml)
    $dlg.Owner = $script:Window
    $dlg.Title = $Titel
    $dlg.FindName('lblText').Text = $Text
    $lst = $dlg.FindName('lstAuswahl')
    $lst.ItemsSource = @($Eintraege)
    $lst.SelectedIndex = 0
    $dlg.FindName('btnOk').Add_Click({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
    $lst.Add_MouseDoubleClick({ [System.Windows.Window]::GetWindow($this).DialogResult = $true })
    if ($dlg.ShowDialog() -eq $true) { return $lst.SelectedItem }
    return $null
}

# ---------------------------------------------------------------------------
# AD-Hilfsfunktionen
# ---------------------------------------------------------------------------
function ConvertTo-LdapWert {
    param([string]$Wert)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Wert.ToCharArray()) {
        switch ($ch) {
            '\'     { [void]$sb.Append('\5c') }
            '*'     { [void]$sb.Append('\2a') }
            '('     { [void]$sb.Append('\28') }
            ')'     { [void]$sb.Append('\29') }
            "`0"    { [void]$sb.Append('\00') }
            default { [void]$sb.Append($ch) }
        }
    }
    return $sb.ToString()
}

function Test-Geschuetzt {
    param([string]$Sam)
    foreach ($muster in $Config.GeschuetzteKonten) {
        if ($Sam -like $muster) { return $true }
    }
    return $false
}

function Test-InSyncOu {
    param([string]$Dn)
    return ($Dn -like "*,OU=$($Config.SyncOuName),*")
}

# "OU=Sync-O365,OU=02_Betrieb,OU=01_Normal-Users,..." -> "01_Normal-Users \ 02_Betrieb \ Sync-O365"
function Get-OuAnzeige {
    param([string]$Dn)
    [string[]]$teile = @([regex]::Split($Dn, '(?<!\\),') | Where-Object { $_ -like 'OU=*' } | ForEach-Object { $_.Substring(3) })
    [array]::Reverse($teile)
    return ($teile -join ' \ ')
}

function Get-Eltern {
    param([string]$Dn)
    return ([regex]::Split($Dn, '(?<!\\),', 2)[1])
}

# Umlaute umschreiben, Akzente entfernen, nur a-z 0-9 und Bindestrich behalten
function ConvertTo-NamensTeil {
    param([string]$Text)
    $t = $Text.Trim().ToLowerInvariant()
    foreach ($paar in @(@('ä', 'ae'), @('ö', 'oe'), @('ü', 'ue'), @('ß', 'ss'), @('æ', 'ae'), @('ø', 'oe'))) {
        $t = $t.Replace($paar[0], $paar[1])
    }
    $formD = $t.Normalize([System.Text.NormalizationForm]::FormD)
    $t = -join ($formD.ToCharArray() | Where-Object {
            [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark
        })
    $t = $t -replace '[^a-z0-9-]', ''
    $t = $t -replace '-{2,}', '-' -replace '^-|-$', ''
    return $t
}

function Test-SamFrei {
    param([string]$Sam)
    $treffer = Get-ADObject -LDAPFilter "(sAMAccountName=$(ConvertTo-LdapWert $Sam))" -Server $script:DC
    return (-not $treffer)
}

# Alle AD-Objekte (Benutzer, Kontakte, Gruppen ...), die die Adresse als UPN, mail oder proxyAddress nutzen
function Get-AdressKonflikte {
    param([string]$Adresse, [string]$AusserDn = '')
    $w = ConvertTo-LdapWert $Adresse
    $filter = "(|(userPrincipalName=$w)(mail=$w)(proxyAddresses=smtp:$w))"
    return @(Get-ADObject -LDAPFilter $filter -Server $script:DC | Where-Object { $_.DistinguishedName -ne $AusserDn })
}

function Get-BenutzernamenVorschlag {
    param([string]$Vorname, [string]$Nachname)
    $v = ConvertTo-NamensTeil $Vorname
    $n = ConvertTo-NamensTeil $Nachname
    if (-not $v -or -not $n) { return $null }
    $basis = "$v.$n"
    for ($i = 0; $i -lt 100; $i++) {
        $suffix = if ($i -eq 0) { '' } else { "$i" }
        $lokal = "$basis$suffix"
        $sam = $lokal
        $hinweise = @()
        if ($sam.Length -gt 20) {
            # sAMAccountName ist auf 20 Zeichen begrenzt; UPN/Mail behalten den vollen Namen
            $sam = $basis.Substring(0, 20 - $suffix.Length).TrimEnd('.', '-') + $suffix
            $hinweise += "SAM auf 20 Zeichen gekürzt ($sam) – UPN/Mail bleiben $lokal@$($Config.MailDomain)."
        }
        $upn = "$lokal@$($Config.MailDomain)"
        if ((Test-SamFrei $sam) -and (Get-AdressKonflikte $upn).Count -eq 0) {
            if ($i -gt 0) { $hinweise += "$basis ist bereits vergeben – Nummer $i angehängt." }
            return [pscustomobject]@{ Sam = $sam; Upn = $upn; Hinweis = ($hinweise -join ' ') }
        }
    }
    throw "Kein freier Benutzername für $basis gefunden."
}

function Find-AdBenutzer {
    param([string]$Suchtext)
    $w = ConvertTo-LdapWert $Suchtext.Trim()
    if (-not $w) { return @() }
    $filter = "(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=*$w*)(displayName=*$w*)(userPrincipalName=*$w*)(mail=*$w*)))"
    return @(Get-ADUser -LDAPFilter $filter -Server $script:DC -Properties DisplayName, Enabled -ResultSetSize 50 |
            Sort-Object DisplayName |
            ForEach-Object {
                $zusatz = @()
                if (-not $_.Enabled) { $zusatz += 'deaktiviert' }
                if (Test-Geschuetzt $_.SamAccountName) { $zusatz += 'geschützt' }
                $z = if ($zusatz) { ' [' + ($zusatz -join ', ') + ']' } else { '' }
                [pscustomobject]@{
                    Anzeige           = '{0}  ({1})  –  {2}{3}' -f $_.DisplayName, $_.SamAccountName, (Get-OuAnzeige $_.DistinguishedName), $z
                    SamAccountName    = $_.SamAccountName
                    DistinguishedName = $_.DistinguishedName
                }
            })
}

function Get-SyncOus {
    return @(Get-ADOrganizationalUnit -LDAPFilter "(ou=$($Config.SyncOuName))" -SearchBase $Config.BenutzerOuBasis -Server $script:DC |
            Sort-Object DistinguishedName |
            ForEach-Object { [pscustomobject]@{ Anzeige = (Get-OuAnzeige $_.DistinguishedName); DistinguishedName = $_.DistinguishedName } })
}

# Zu kopierende Attributwerte der Vorlage (leere Werte und "läuft nie ab" werden ausgelassen)
function Get-VorlagenAttribute {
    param([Parameter(Mandatory)]$Vorlage, [string]$NeuerSam)
    $ergebnis = [ordered]@{}
    foreach ($attr in $Config.KopierAttribute) {
        if (-not ($Vorlage.PSObject.Properties.Name -contains $attr)) { continue }
        $wert = $Vorlage.$attr
        if ($null -eq $wert) { continue }
        if ($wert -is [Microsoft.ActiveDirectory.Management.ADPropertyValueCollection]) {
            if ($wert.Count -eq 0) { continue }
            $wert = [string[]]@($wert)
        }
        if ($wert -is [string] -and [string]::IsNullOrWhiteSpace($wert)) { continue }
        if ($attr -eq 'countryCode' -and [int]$wert -eq 0) { continue }
        if ($attr -eq 'accountExpires') {
            $v = [int64]$wert
            if ($v -le 0 -or $v -eq [int64]::MaxValue) { continue }
        }
        if ($NeuerSam -and $Config.SamErsetzenIn -contains $attr) {
            $wert = [regex]::Replace([string]$wert, [regex]::Escape($Vorlage.SamAccountName), $NeuerSam, 'IgnoreCase')
        }
        $ergebnis[$attr] = $wert
    }
    return $ergebnis
}

function Format-AttributWert {
    param([string]$Name, $Wert)
    switch ($Name) {
        'logonHours'     { return '(Anmeldezeiten eingeschränkt)' }
        'accountExpires' { return ([DateTime]::FromFileTime([int64]$Wert)).ToString('dd.MM.yyyy') }
        'manager'        { return ([regex]::Match([string]$Wert, '^CN=(.+?)(?<!\\),').Groups[1].Value -replace '\\', '') }
        default          { return (@($Wert) -join '; ') }
    }
}

function Test-ErlaubteMailDomain {
    param([string]$Adresse)
    $domain = ($Adresse -split '@')[-1]
    return ($domain -eq $Config.MailDomain -or $domain -like '*.onmicrosoft.com')
}

# Soll-Liste der proxyAddresses: SMTP:<Primär>, übrige smtp-Aliase der erlaubten Domains als
# sekundär, alle anderen Typen (x500, X400, sip ...) unverändert, keine Duplikate
function Get-SollProxyAdressen {
    param([string[]]$Aktuell, [string]$Primaer)
    $liste = New-Object System.Collections.Generic.List[string]
    $gesehen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $liste.Add("SMTP:$Primaer")
    [void]$gesehen.Add("smtp:$Primaer")
    foreach ($p in @($Aktuell)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($p -match '^smtp:(.+)$') {
            $adresse = $Matches[1]
            if (-not (Test-ErlaubteMailDomain $adresse)) { continue }
            if ($gesehen.Add("smtp:$adresse")) { $liste.Add("smtp:$adresse") }
        }
        elseif ($gesehen.Add($p)) {
            $liste.Add($p)
        }
    }
    return , $liste.ToArray()
}

# Vergleichsschlüssel: Präfix SMTP/smtp case-sensitiv, Adresse case-insensitiv
function Get-ProxySchluessel {
    param([string[]]$Liste)
    $schluessel = @($Liste | Where-Object { $_ } | ForEach-Object {
            if ($_ -match '^smtp:') { $_.Substring(0, 5) + $_.Substring(5).ToLowerInvariant() } else { $_.ToLowerInvariant() }
        } | Sort-Object -CaseSensitive)
    return ($schluessel -join '|')
}

function Get-PasswortRichtlinie {
    param([string]$Identitaet)
    $p = $null
    if ($Identitaet) {
        try { $p = Get-ADUserResultantPasswordPolicy -Identity $Identitaet -Server $script:DC -ErrorAction Stop } catch { $p = $null }
    }
    $istFgpp = $true
    if (-not $p) {
        $p = Get-ADDefaultDomainPasswordPolicy -Server $script:DC
        $istFgpp = $false
    }
    return [pscustomobject]@{
        Name          = if ($istFgpp) { $p.Name } else { 'Default Domain Policy' }
        IstFgpp       = $istFgpp
        MinLaenge     = [int]$p.MinPasswordLength
        Komplex       = [bool]$p.ComplexityEnabled
        Historie      = [int]$p.PasswordHistoryCount
        MaxAlterTage  = [int]$p.MaxPasswordAge.TotalDays
        MinAlterTage  = [int]$p.MinPasswordAge.TotalDays
        Sperrschwelle = [int]$p.LockoutThreshold
    }
}

# Repliziert Objekte sofort vom Arbeits-DC auf alle anderen beschreibbaren DCs,
# damit der Entra-Connect-Server sie unabhängig von seinem bevorzugten DC sieht
function Sync-AdReplikation {
    param([string[]]$Objekte)
    $ziele = @(Get-ADDomainController -Filter * | Where-Object { -not $_.IsReadOnly -and $_.HostName -ne $script:DC })
    foreach ($dc in $ziele) {
        foreach ($o in $Objekte) {
            try {
                Sync-ADObject -Object $o -Source $script:DC -Destination $dc.HostName -ErrorAction Stop
            }
            catch {
                Write-Log "Replikation von '$o' nach $($dc.HostName) fehlgeschlagen: $($_.Exception.Message)" 'WARNUNG'
            }
        }
    }
    Write-Log "AD-Replikation auf $($ziele.Count) weitere(n) DC(s) angestoßen."
}

# ---------------------------------------------------------------------------
# Microsoft Graph
# ---------------------------------------------------------------------------
$EntraFelder = 'id,displayName,userPrincipalName,accountEnabled,usageLocation,assignedLicenses,licenseAssignmentStates,' +
'onPremisesSyncEnabled,onPremisesImmutableId,onPremisesLastSyncDateTime,onPremisesProvisioningErrors,onPremisesSamAccountName,mail'

function Invoke-Graph {
    param([string]$Methode = 'GET', [Parameter(Mandatory)][string]$Uri, $Body)
    $p = @{ Method = $Methode; Uri = $Uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $p.Body = ConvertTo-Json -InputObject $Body -Depth 10
        $p.ContentType = 'application/json'
    }
    return (Invoke-MgGraphRequest @p)
}

function Connect-M365 {
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        throw "Modul Microsoft.Graph.Authentication fehlt. Installation: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    # Anmeldung im Browser statt über WAM
    try { Set-MgGraphOption -DisableLoginByWAM $true -ErrorAction Stop } catch { }
    Write-Log 'Anmeldung an Microsoft 365 – bitte im Browser anmelden ...'
    Connect-MgGraph -Scopes $Config.GraphScopes -ContextScope Process -NoWelcome -ErrorAction Stop
    $ctx = Get-MgContext
    if (-not $ctx) { throw 'Anmeldung an Microsoft 365 fehlgeschlagen.' }
    $fehlend = @($Config.GraphScopes | Where-Object { $ctx.Scopes -notcontains $_ })
    if ($fehlend) { Write-Log "Fehlende Berechtigungen: $($fehlend -join ', ')" 'WARNUNG' }
    $script:GraphVerbunden = $true
    $script:GraphKonto = $ctx.Account
    Write-Log "Mit Microsoft 365 verbunden als $($ctx.Account)." 'OK'
    Update-Lizenzen
    Update-Statuszeile
}

# Fragt bei Bedarf nach und verbindet; $true wenn verbunden
function Confirm-M365Verbindung {
    if ($script:GraphVerbunden) { return $true }
    if (-not (Confirm-Aktion 'Für diesen Schritt ist eine Microsoft-365-Anmeldung nötig. Jetzt anmelden?' 'Microsoft 365')) { return $false }
    Connect-M365
    return $script:GraphVerbunden
}

function Get-ImmutableIdKandidaten {
    param([Parameter(Mandatory)]$AdBenutzer)
    $ids = @([Convert]::ToBase64String($AdBenutzer.ObjectGUID.ToByteArray()))
    $cg = $AdBenutzer.'mS-DS-ConsistencyGuid'
    if ($cg) { $ids += [Convert]::ToBase64String([byte[]]$cg) }
    return @($ids | Select-Object -Unique)
}

# Sucht das Entra-Objekt zuerst über die ImmutableId (Hard-Match), dann über die UPN
function Find-EntraBenutzer {
    param([string[]]$ImmutableIds, [string]$Upn)
    foreach ($id in @($ImmutableIds)) {
        if (-not $id) { continue }
        try {
            $filter = [uri]::EscapeDataString("onPremisesImmutableId eq '$id'")
            $r = Invoke-Graph -Uri "/v1.0/users?`$filter=$filter&`$select=$EntraFelder"
            if (@($r.value).Count -gt 0) { return [pscustomobject]@{ Benutzer = @($r.value)[0]; Treffer = 'ImmutableId' } }
        }
        catch {
            Write-Log "Suche über ImmutableId fehlgeschlagen: $($_.Exception.Message)" 'WARNUNG'
        }
    }
    if ($Upn) {
        $filter = [uri]::EscapeDataString("userPrincipalName eq '$($Upn.Replace("'", "''"))'")
        $r = Invoke-Graph -Uri "/v1.0/users?`$filter=$filter&`$select=$EntraFelder"
        if (@($r.value).Count -gt 0) { return [pscustomobject]@{ Benutzer = @($r.value)[0]; Treffer = 'UPN' } }
    }
    return $null
}

function Get-SkuAnzeigename {
    param([string]$Teilenummer)
    if ($SkuNamen.ContainsKey($Teilenummer)) { return $SkuNamen[$Teilenummer] }
    return $Teilenummer
}

function Get-SkuNameNachId {
    param([string]$SkuId)
    $sku = $script:AlleSkus | Where-Object SkuId -eq $SkuId | Select-Object -First 1
    if ($sku) { return $sku.Name }
    return $SkuId
}

function Update-Lizenzen {
    $r = Invoke-Graph -Uri '/v1.0/subscribedSkus'
    $script:AlleSkus = @(@($r.value) | ForEach-Object {
            $gesamt = [int]$_.prepaidUnits.enabled
            $belegt = [int]$_.consumedUnits
            $name = Get-SkuAnzeigename $_.skuPartNumber
            [pscustomobject]@{
                SkuId       = [string]$_.skuId
                Teilenummer = [string]$_.skuPartNumber
                Name        = $name
                Gesamt      = $gesamt
                Belegt      = $belegt
                Frei        = $gesamt - $belegt
                Waehlbar    = ($_.appliesTo -eq 'User' -and $_.capabilityStatus -eq 'Enabled' -and
                               $KostenloseSkus -notcontains $_.skuPartNumber -and $gesamt -lt 10000)
                Anzeige     = '{0}  –  {1} frei ({2}/{3} belegt)' -f $name, ($gesamt - $belegt), $belegt, $gesamt
            }
        } | Sort-Object Name)
    Write-Log ("{0} Lizenztypen geladen, davon {1} mit freien Lizenzen." -f @($script:AlleSkus | Where-Object Waehlbar).Count, @($script:AlleSkus | Where-Object { $_.Waehlbar -and $_.Frei -gt 0 }).Count)

    $auswahl = @([pscustomobject]@{ SkuId = $null; Name = ''; Frei = 0; Anzeige = '(keine Lizenz zuweisen)' })
    $auswahl += @($script:AlleSkus | Where-Object { $_.Waehlbar -and $_.Frei -gt 0 })
    $script:Ui.cmbLizenz.ItemsSource = $auswahl
    $script:Ui.cmbLizenz.SelectedIndex = 0
    $script:Ui.cmbLizenz.IsEnabled = $true
    Set-LizenzAusVorlage
}

function Set-UsageLocation {
    param([Parameter(Mandatory)][string]$EntraId)
    Invoke-Graph -Methode PATCH -Uri "/v1.0/users/$EntraId" -Body @{ usageLocation = $Config.UsageLocation } | Out-Null
    Write-Log "UsageLocation = $($Config.UsageLocation) gesetzt." 'OK'
}

function Add-EntraLizenz {
    param([Parameter(Mandatory)][string]$EntraId, [Parameter(Mandatory)]$Sku)
    # Frische Zahlen holen, bevor zugewiesen wird
    Update-Lizenzen
    $aktuell = $script:AlleSkus | Where-Object SkuId -eq $Sku.SkuId
    if (-not $aktuell -or $aktuell.Frei -le 0) { throw "Keine freie Lizenz '$($Sku.Name)' mehr verfügbar." }
    $body = @{ addLicenses = @(@{ skuId = $Sku.SkuId; disabledPlans = @() }); removeLicenses = @() }
    Invoke-Graph -Methode POST -Uri "/v1.0/users/$EntraId/assignLicense" -Body $body | Out-Null
    Write-Log "Lizenz '$($Sku.Name)' zugewiesen." 'OK'
    Update-Lizenzen
}

# ---------------------------------------------------------------------------
# Entra Connect
# ---------------------------------------------------------------------------
function Get-SyncStatus {
    return Invoke-Command -ComputerName $Config.EntraConnectServer -ErrorAction Stop -ScriptBlock {
        Import-Module ADSync -ErrorAction Stop
        $s = Get-ADSyncScheduler
        [pscustomobject]@{ Staging = [bool]$s.StagingModeEnabled; Laeuft = [bool]$s.SyncCycleInProgress }
    }
}

function Start-EntraSync {
    $server = $Config.EntraConnectServer
    if (Test-Simulation) {
        Write-Log "[Simulation] Delta-Sync auf $server würde gestartet." 'SIM'
        return
    }
    $ende = (Get-Date).AddMinutes($Config.SyncTimeoutMinuten)
    $status = Get-SyncStatus
    if ($status.Staging) { throw "$server ist im Staging-Modus – dort wird nicht exportiert. Sync abgebrochen." }
    while ($status.Laeuft) {
        if ((Get-Date) -gt $ende) { throw "Zeitüberschreitung: auf $server läuft seit langem ein Sync-Zyklus." }
        Write-Log "Auf $server läuft bereits ein Sync-Zyklus – warte ..."
        Wait-Ui 15
        $status = Get-SyncStatus
    }
    $ergebnis = Invoke-Command -ComputerName $server -ErrorAction Stop -ScriptBlock {
        Import-Module ADSync -ErrorAction Stop
        [string](Start-ADSyncSyncCycle -PolicyType Delta).Result
    }
    Write-Log "Delta-Sync auf $server gestartet ($ergebnis)."
    Wait-Ui 5
    do {
        if ((Get-Date) -gt $ende) { throw "Zeitüberschreitung beim Warten auf den Sync-Zyklus auf $server." }
        $status = Get-SyncStatus
        if ($status.Laeuft) { Wait-Ui 10 }
    } while ($status.Laeuft)
    Write-Log 'Delta-Sync abgeschlossen.' 'OK'
}

# ---------------------------------------------------------------------------
# Benutzer anlegen / kopieren
# ---------------------------------------------------------------------------
function Update-NamensVorschlag {
    $ui = $script:Ui
    $vorname = $ui.txtVorname.Text.Trim()
    $nachname = $ui.txtNachname.Text.Trim()
    if (-not $vorname -or -not $nachname) {
        $ui.lblHinweis.Text = ''
        return
    }
    $ui.txtAnzeigename.Text = "$nachname $vorname"
    $vorschlag = Get-BenutzernamenVorschlag -Vorname $vorname -Nachname $nachname
    if ($vorschlag) {
        $ui.txtSam.Text = $vorschlag.Sam
        $ui.txtUpn.Text = $vorschlag.Upn
        $ui.lblHinweis.Text = $vorschlag.Hinweis
    }
}

function Set-Vorlage {
    param($Eintrag)
    $ui = $script:Ui
    $ui.lstGruppen.ItemsSource = $null
    $ui.lstAttribute.ItemsSource = $null
    $script:Vorlage = $null
    if (-not $Eintrag) { return }
    if (Test-Geschuetzt $Eintrag.SamAccountName) {
        $ui.cmbVorlage.SelectedIndex = -1
        throw "'$($Eintrag.SamAccountName)' ist ein geschütztes Konto und kann nicht als Vorlage dienen."
    }
    $props = @($Config.KopierAttribute) + @('memberOf', 'primaryGroupID', 'DisplayName', 'UserPrincipalName', 'mS-DS-ConsistencyGuid')
    $v = Get-ADUser -Identity $Eintrag.DistinguishedName -Properties $props -Server $script:DC
    $script:Vorlage = $v

    $ui.lstGruppen.ItemsSource = @($v.memberOf | ForEach-Object { [regex]::Match($_, '^CN=(.+?)(?<!\\),').Groups[1].Value -replace '\\', '' } | Sort-Object)
    $attr = Get-VorlagenAttribute -Vorlage $v -NeuerSam '<neu>'
    $ui.lstAttribute.ItemsSource = @($attr.Keys | ForEach-Object { '{0} = {1}' -f $_, (Format-AttributWert $_ $attr[$_]) })
    if ($v.primaryGroupID -ne 513) {
        Write-Log "Vorlage hat eine abweichende primäre Gruppe (RID $($v.primaryGroupID)) – wird nicht übernommen." 'WARNUNG'
    }

    # OU der Vorlage auswählen (bei Bedarf in die Liste aufnehmen)
    $ou = Get-Eltern $v.DistinguishedName
    $items = @($ui.cmbOU.ItemsSource)
    $treffer = $items | Where-Object { $_.DistinguishedName -eq $ou } | Select-Object -First 1
    if (-not $treffer) {
        $anzeige = Get-OuAnzeige $ou
        if (-not (Test-InSyncOu "CN=x,$ou")) { $anzeige += '   (KEINE Sync-OU!)' }
        $treffer = [pscustomobject]@{ Anzeige = $anzeige; DistinguishedName = $ou }
        $ui.cmbOU.ItemsSource = @($items) + $treffer
    }
    $ui.cmbOU.SelectedItem = $treffer
    Write-Log "Vorlage: $($v.DisplayName) ($($v.SamAccountName)) – $(@($v.memberOf).Count) Gruppen, OU $(Get-OuAnzeige $ou)"
    Set-LizenzAusVorlage
}

# Lizenz der Vorlage vorauswählen, falls verbunden und frei
function Set-LizenzAusVorlage {
    if (-not $script:GraphVerbunden -or -not $script:Vorlage) { return }
    try {
        $treffer = Find-EntraBenutzer -ImmutableIds (Get-ImmutableIdKandidaten $script:Vorlage) -Upn $script:Vorlage.UserPrincipalName
        if (-not $treffer) { return }
        $skuIds = @($treffer.Benutzer.assignedLicenses | ForEach-Object { [string]$_.skuId })
        $wahl = @($script:Ui.cmbLizenz.ItemsSource) | Where-Object { $_.SkuId -and $skuIds -contains $_.SkuId } | Select-Object -First 1
        if ($wahl) {
            $script:Ui.cmbLizenz.SelectedItem = $wahl
            Write-Log "Lizenz der Vorlage vorausgewählt: $($wahl.Name)"
        }
    }
    catch {
        Write-Log "Lizenz der Vorlage nicht lesbar: $($_.Exception.Message)" 'WARNUNG'
    }
}

function Invoke-BenutzerAnlage {
    $ui = $script:Ui
    $vorname = $ui.txtVorname.Text.Trim()
    $nachname = $ui.txtNachname.Text.Trim()
    $sam = $ui.txtSam.Text.Trim()
    $upn = $ui.txtUpn.Text.Trim()
    $anzeige = $ui.txtAnzeigename.Text.Trim()
    $ou = $ui.cmbOU.SelectedItem
    $passwort = $ui.txtPasswort.Text
    $sku = $ui.cmbLizenz.SelectedItem
    $sim = Test-Simulation

    # --- Prüfungen
    $fehler = @()
    if (-not $vorname -or -not $nachname) { $fehler += 'Vorname und Nachname sind Pflicht.' }
    if (-not $anzeige) { $fehler += 'Anzeigename fehlt.' }
    if ($sam -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$') { $fehler += "Benutzername '$sam' ist ungültig (max. 20 Zeichen, nur a-z, 0-9, . _ -)." }
    if ($upn -notmatch "^[A-Za-z0-9._-]+@$([regex]::Escape($Config.MailDomain))$") { $fehler += "E-Mail/UPN muss auf @$($Config.MailDomain) enden und darf nur a-z, 0-9, . _ - enthalten." }
    if (Test-Geschuetzt $sam) { $fehler += "'$sam' entspricht einem geschützten Kontomuster." }
    if (-not $ou) { $fehler += 'Keine OU gewählt.' }
    if (-not $passwort) { $fehler += 'Initialpasswort fehlt.' }
    if (-not $fehler) {
        if (-not (Test-SamFrei $sam)) { $fehler += "Benutzername '$sam' ist bereits vergeben." }
        $konflikte = Get-AdressKonflikte $upn
        if ($konflikte) { $fehler += "Adresse $upn wird bereits verwendet von: $($konflikte.DistinguishedName -join '; ')" }
        if ($script:GraphVerbunden) {
            $cloud = Find-EntraBenutzer -Upn $upn
            if ($cloud) { $fehler += "In Entra ID existiert bereits ein Objekt mit UPN $upn (Sync aktiv: $($cloud.Benutzer.onPremisesSyncEnabled)). Ein Soft-Match würde es übernehmen – bitte zuerst klären." }
        }
    }
    if ($fehler) {
        Show-Meldung -Text ($fehler -join "`n`n") -Titel 'Benutzer kann nicht angelegt werden' -Symbol 'Warning'
        return
    }
    if (-not (Test-InSyncOu "CN=x,$($ou.DistinguishedName)")) {
        if (-not (Confirm-Aktion "Die gewählte OU ist keine $($Config.SyncOuName)-OU – der Benutzer wird NICHT mit Microsoft 365 synchronisiert.`n`nTrotzdem fortfahren?" 'Keine Sync-OU' 'Warning')) { return }
    }

    $vorlage = $script:Vorlage
    $kopie = if ($vorlage) { Get-VorlagenAttribute -Vorlage $vorlage -NeuerSam $sam } else { [ordered]@{} }
    $gruppen = if ($vorlage) { @($vorlage.memberOf) } else { @() }
    $syncAktiv = ($ui.chkSync.IsChecked -eq $true)

    $zusammenfassung = @(
        "Anzeigename : $anzeige"
        "Benutzername: $sam"
        "E-Mail/UPN  : $upn"
        "OU          : $($ou.Anzeige)"
        "Vorlage     : $(if ($vorlage) { "$($vorlage.DisplayName) ($($gruppen.Count) Gruppen, $($kopie.Count) Attribute)" } else { '(keine)' })"
        "Entra-Sync  : $(if ($syncAktiv) { 'ja' } else { 'nein' })"
        "Lizenz      : $(if ($syncAktiv -and $sku -and $sku.SkuId) { $sku.Name } else { '(keine)' })"
    ) -join "`n"
    $titel = if ($sim) { 'Benutzer anlegen – SIMULATION' } else { 'Benutzer anlegen' }
    if (-not (Confirm-Aktion "$zusammenfassung`n`nJetzt anlegen?" $titel)) { return }

    # --- CN muss in der OU eindeutig sein
    $cn = $anzeige
    if (Get-ADObject -LDAPFilter "(cn=$(ConvertTo-LdapWert $cn))" -SearchBase $ou.DistinguishedName -SearchScope OneLevel -Server $script:DC) {
        $cn = "$anzeige ($sam)"
    }

    $lokal = $upn.Split('@')[0]
    $weitere = @{
        mailNickname   = $lokal
        proxyAddresses = [string[]]@("SMTP:$upn")
    }
    $parameter = @{
        Name                  = $cn
        GivenName             = $vorname
        Surname               = $nachname
        DisplayName           = $anzeige
        SamAccountName        = $sam
        UserPrincipalName     = $upn
        EmailAddress          = $upn
        Path                  = $ou.DistinguishedName
        AccountPassword       = (ConvertTo-SecureString -String $passwort -AsPlainText -Force)
        Enabled               = $true
        ChangePasswordAtLogon = $true
        Server                = $script:DC
        PassThru              = $true
        ErrorAction           = 'Stop'
    }
    foreach ($k in $kopie.Keys) {
        if ($k -eq 'accountExpires') { $parameter.AccountExpirationDate = [DateTime]::FromFileTime([int64]$kopie[$k]) }
        else { $weitere[$k] = $kopie[$k] }
    }
    $parameter.OtherAttributes = $weitere

    Write-Log "Lege Benutzer $sam ($anzeige) an in $($ou.DistinguishedName)$(if ($vorlage) { " – Vorlage $($vorlage.SamAccountName)" })"
    if ($sim) {
        Write-Log "[Simulation] New-ADUser $sam; Attribute: $((@($weitere.Keys) | Sort-Object) -join ', ')" 'SIM'
        $dn = "CN=$cn,$($ou.DistinguishedName)"
    }
    else {
        $neu = New-ADUser @parameter
        $dn = $neu.DistinguishedName
        Write-Log "Benutzer angelegt: $dn" 'OK'
    }

    # --- Gruppen der Vorlage
    $gruppenFehler = 0
    foreach ($g in $gruppen) {
        if ($sim) { Write-Log "[Simulation] Gruppe: $g" 'SIM'; continue }
        try {
            Add-ADGroupMember -Identity $g -Members $dn -Server $script:DC -ErrorAction Stop
            Write-Log "Gruppe hinzugefügt: $g"
        }
        catch {
            $gruppenFehler++
            Write-Log "Gruppe '$g' fehlgeschlagen: $($_.Exception.Message)" 'FEHLER'
        }
    }
    if (-not $sim) { Sync-AdReplikation (@($dn) + $gruppen) }

    $script:LetzterBenutzer = [pscustomobject]@{ Name = $anzeige; Sam = $sam; Upn = $upn; Passwort = $passwort; Dn = $dn }
    $ui.btnDrucken.IsEnabled = $true

    # --- Entra ID
    $entraText = ''
    if ($syncAktiv) {
        $entraText = Invoke-EntraNachbearbeitung -Upn $upn -Sku $sku
    }

    $meldung = "Benutzer $sam wurde $(if ($sim) { 'SIMULIERT' } else { 'angelegt' }).`n"
    if ($gruppenFehler) { $meldung += "`n$gruppenFehler Gruppe(n) konnten nicht zugewiesen werden – siehe Protokoll.`n" }
    if ($entraText) { $meldung += "`n$entraText`n" }
    $meldung += "`nJetzt kann das Zugangsblatt gedruckt werden."
    Show-Meldung -Text $meldung -Titel 'Fertig'
}

# Sync, auf Entra-Objekt warten, UsageLocation, Lizenz; gibt eine Zusammenfassung zurück
function Invoke-EntraNachbearbeitung {
    param([string]$Upn, $Sku)
    if (-not (Confirm-M365Verbindung)) {
        Write-Log 'Keine Microsoft-365-Verbindung – Entra-Schritte übersprungen.' 'WARNUNG'
        return 'Entra-Schritte übersprungen (keine M365-Verbindung).'
    }
    Start-EntraSync
    if (Test-Simulation) {
        if ($Sku -and $Sku.SkuId) { Write-Log "[Simulation] UsageLocation $($Config.UsageLocation) + Lizenz '$($Sku.Name)' würden gesetzt." 'SIM' }
        return 'Entra-Schritte simuliert.'
    }

    $ende = (Get-Date).AddMinutes($Config.EntraWarteMinuten)
    $treffer = $null
    while (-not $treffer) {
        $treffer = Find-EntraBenutzer -Upn $Upn
        if ($treffer) { break }
        if ((Get-Date) -gt $ende) {
            Write-Log "$Upn ist nach $($Config.EntraWarteMinuten) Minuten nicht in Entra ID erschienen." 'FEHLER'
            return "ACHTUNG: $Upn ist noch nicht in Entra ID sichtbar. Bitte später im Diagnose-Tab prüfen."
        }
        Write-Log 'Noch nicht in Entra ID sichtbar – neuer Versuch in 20 s ...'
        Wait-Ui 20
    }
    $e = $treffer.Benutzer
    Write-Log "In Entra ID gefunden: $($e.userPrincipalName) (Id $($e.id))" 'OK'
    $text = @("Entra ID: Objekt synchronisiert.")

    foreach ($pf in @($e.onPremisesProvisioningErrors)) {
        if (-not $pf) { continue }
        Write-Log "Provisioning-Fehler: $($pf.category) / $($pf.propertyCausingError) = $($pf.value)" 'FEHLER'
        $text += "Provisioning-Fehler: $($pf.propertyCausingError) = $($pf.value)"
    }

    try {
        Set-UsageLocation -EntraId $e.id
        $text += "UsageLocation: $($Config.UsageLocation)"
    }
    catch {
        Write-Log "UsageLocation setzen fehlgeschlagen: $($_.Exception.Message)" 'FEHLER'
        $text += 'UsageLocation: FEHLER (siehe Protokoll)'
    }

    if ($Sku -and $Sku.SkuId) {
        try {
            Add-EntraLizenz -EntraId $e.id -Sku $Sku
            $text += "Lizenz: $($Sku.Name)"
        }
        catch {
            Write-Log "Lizenzzuweisung fehlgeschlagen: $($_.Exception.Message)" 'FEHLER'
            $text += "Lizenz: FEHLER – $($_.Exception.Message)"
        }
    }
    return ($text -join "`n")
}

# ---------------------------------------------------------------------------
# Zugangsblatt
# ---------------------------------------------------------------------------
function New-Absatz {
    param([string]$Text, [double]$Groesse = 13, [switch]$Fett, [double]$Abstand = 6)
    $p = New-Object System.Windows.Documents.Paragraph
    $run = New-Object System.Windows.Documents.Run($Text)
    if ($Fett) { $run.FontWeight = [System.Windows.FontWeights]::SemiBold }
    $p.Inlines.Add($run)
    $p.FontSize = $Groesse
    $p.Margin = New-Object System.Windows.Thickness(0, 0, 0, $Abstand)
    return $p
}

function Invoke-ZugangsblattDruck {
    $b = $script:LetzterBenutzer
    if (-not $b) { return }
    $richtlinie = Get-PasswortRichtlinie -Identitaet $(if (Test-Simulation) { $null } else { $b.Dn })
    if (-not $richtlinie.IstFgpp) {
        Write-Log "$($b.Sam) hat keine FGPP ($($Config.BenutzerFgpp)) – es gilt nur die Default Domain Policy." 'WARNUNG'
    }

    $dlg = New-Object System.Windows.Controls.PrintDialog
    if ($dlg.ShowDialog() -ne $true) { return }

    $doc = New-Object System.Windows.Documents.FlowDocument
    $doc.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $doc.FontSize = 13
    $doc.PageWidth = $dlg.PrintableAreaWidth
    $doc.PageHeight = $dlg.PrintableAreaHeight
    $doc.ColumnWidth = $dlg.PrintableAreaWidth
    $doc.PagePadding = New-Object System.Windows.Thickness(70, 60, 70, 60)

    $doc.Blocks.Add((New-Absatz -Text $Config.Firmenname -Groesse 12 -Abstand 2))
    $doc.Blocks.Add((New-Absatz -Text 'Ihr persönliches Benutzerkonto' -Groesse 22 -Fett -Abstand 20))

    # Zugangsdaten als Tabelle
    $tabelle = New-Object System.Windows.Documents.Table
    $tabelle.CellSpacing = 0
    $tabelle.Columns.Add((New-Object System.Windows.Documents.TableColumn -Property @{ Width = New-Object System.Windows.GridLength(230) }))
    $tabelle.Columns.Add((New-Object System.Windows.Documents.TableColumn))
    $gruppe = New-Object System.Windows.Documents.TableRowGroup
    $zeilen = @(
        @('Name', $b.Name),
        @('Benutzername (Windows)', $b.Sam),
        @('E-Mail / Microsoft 365', $b.Upn),
        @('Initialpasswort', $b.Passwort)
    )
    foreach ($z in $zeilen) {
        $zeile = New-Object System.Windows.Documents.TableRow
        $links = New-Object System.Windows.Documents.TableCell((New-Absatz -Text $z[0] -Abstand 0))
        $rechts = New-Object System.Windows.Documents.TableCell((New-Absatz -Text $z[1] -Groesse 15 -Fett -Abstand 0))
        foreach ($zelle in @($links, $rechts)) {
            $zelle.Padding = New-Object System.Windows.Thickness(6, 8, 6, 8)
            $zelle.BorderBrush = [System.Windows.Media.Brushes]::LightGray
            $zelle.BorderThickness = New-Object System.Windows.Thickness(0, 0, 0, 1)
        }
        if ($z[0] -eq 'Initialpasswort') { $rechts.Blocks.FirstBlock.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas') }
        $zeile.Cells.Add($links)
        $zeile.Cells.Add($rechts)
        $gruppe.Rows.Add($zeile)
    }
    $tabelle.RowGroups.Add($gruppe)
    $doc.Blocks.Add($tabelle)

    $doc.Blocks.Add((New-Absatz -Text 'Erste Anmeldung' -Groesse 16 -Fett -Abstand 6))
    $schritte = New-Object System.Windows.Documents.List
    $schritte.MarkerStyle = [System.Windows.TextMarkerStyle]::Decimal
    foreach ($t in @(
            'Melden Sie sich an einem Firmen-PC mit Ihrem Benutzernamen und dem Initialpasswort an.',
            'Sie werden sofort aufgefordert, ein eigenes, neues Passwort zu wählen.',
            'Das neue Passwort gilt danach auch für E-Mail (Outlook), Teams und Microsoft 365 (nach einigen Minuten).'
        )) {
        $schritte.ListItems.Add((New-Object System.Windows.Documents.ListItem((New-Absatz -Text $t -Abstand 3))))
    }
    $doc.Blocks.Add($schritte)

    $doc.Blocks.Add((New-Absatz -Text 'Regeln für Ihr neues Passwort' -Groesse 16 -Fett -Abstand 6))
    $regeln = New-Object System.Windows.Documents.List
    $regeln.MarkerStyle = [System.Windows.TextMarkerStyle]::Disc
    $texte = @("Mindestens $($richtlinie.MinLaenge) Zeichen lang.")
    if ($richtlinie.Komplex) {
        $texte += 'Enthält Zeichen aus mindestens 3 der 4 Gruppen: Grossbuchstaben (A–Z), Kleinbuchstaben (a–z), Ziffern (0–9), Sonderzeichen (z. B. ! $ # % & ?).'
        $texte += 'Darf weder Ihren Benutzernamen noch Teile Ihres Namens enthalten.'
    }
    if ($richtlinie.Historie -gt 0) { $texte += "Darf keinem Ihrer letzten $($richtlinie.Historie) Passwörter entsprechen." }
    if ($richtlinie.MinAlterTage -gt 0) { $texte += "Kann frühestens nach $($richtlinie.MinAlterTage) Tag(en) erneut geändert werden." }
    if ($richtlinie.MaxAlterTage -gt 0) { $texte += "Muss spätestens alle $($richtlinie.MaxAlterTage) Tage geändert werden – Windows erinnert Sie rechtzeitig." }
    if ($richtlinie.Sperrschwelle -gt 0) { $texte += "Nach $($richtlinie.Sperrschwelle) Fehlversuchen wird das Konto vorübergehend gesperrt." }
    $texte += 'Tipp: Ein Satz aus mehreren Wörtern (z. B. "Mein Velo ist 12 Jahre alt!") ist sicher und gut zu merken.'
    foreach ($t in $texte) {
        $regeln.ListItems.Add((New-Object System.Windows.Documents.ListItem((New-Absatz -Text $t -Abstand 3))))
    }
    $doc.Blocks.Add($regeln)

    $doc.Blocks.Add((New-Absatz -Text 'Geben Sie Ihr Passwort niemals weiter – auch nicht an die IT. Die IT wird Sie nie nach Ihrem Passwort fragen.' -Fett -Abstand 20))
    $doc.Blocks.Add((New-Absatz -Text ("Erstellt am {0:dd.MM.yyyy} durch die Informatik. Bitte dieses Blatt nach der ersten Anmeldung vernichten." -f (Get-Date)) -Groesse 10))

    $dlg.PrintDocument(([System.Windows.Documents.IDocumentPaginatorSource]$doc).DocumentPaginator, "Zugangsdaten $($b.Sam)")
    Write-Log "Zugangsblatt für $($b.Sam) gedruckt (Richtlinie: $($richtlinie.Name))." 'OK'
}

# ---------------------------------------------------------------------------
# Diagnose
# ---------------------------------------------------------------------------
function New-Pruefung {
    param(
        [string]$Bereich, [string]$Pruefung,
        [ValidateSet('OK', 'WARNUNG', 'FEHLER', 'INFO')][string]$Status,
        [string]$Detail, [string]$FixTyp = '', $FixDaten = $null, [string]$Vorschau = ''
    )
    $symbole = @{ OK = [string][char]0x2714; WARNUNG = [string][char]0x26A0; FEHLER = [string][char]0x2716; INFO = [string][char]0x2139 }
    return [pscustomobject]@{
        Symbol   = $symbole[$Status]
        Bereich  = $Bereich
        Pruefung = $Pruefung
        Status   = $Status
        Detail   = $Detail
        FixTyp   = $FixTyp
        FixDaten = $FixDaten
        Vorschau = $Vorschau
        FixLabel = if ($FixTyp) { 'Korrigieren' } else { '' }
    }
}

function Get-DiagnoseErgebnisse {
    param([Parameter(Mandatory)][string]$Dn)
    $props = @('GivenName', 'Surname', 'DisplayName', 'UserPrincipalName', 'mail', 'mailNickname', 'proxyAddresses', 'Enabled',
        'LockedOut', 'PasswordNeverExpires', 'PasswordExpired', 'pwdLastSet', 'whenCreated', 'mS-DS-ConsistencyGuid')
    $u = Get-ADUser -Identity $Dn -Properties $props -Server $script:DC
    $liste = New-Object System.Collections.Generic.List[object]
    $geschuetzt = Test-Geschuetzt $u.SamAccountName
    $upn = [string]$u.UserPrincipalName
    $lokal = if ($upn -match '^(.+)@') { $Matches[1] } else { '' }
    $inSync = Test-InSyncOu $u.DistinguishedName

    if ($geschuetzt) {
        $liste.Add((New-Pruefung 'AD' 'Geschütztes Konto' 'INFO' 'Konto entspricht einem geschützten Muster – nur Anzeige, Korrekturen gesperrt.'))
    }

    # --- Konto
    if ($inSync) { $liste.Add((New-Pruefung 'AD' 'Sync-OU' 'OK' (Get-OuAnzeige $u.DistinguishedName))) }
    else { $liste.Add((New-Pruefung 'AD' 'Sync-OU' 'FEHLER' "Liegt nicht in einer $($Config.SyncOuName)-OU – wird nicht mit Entra ID synchronisiert: $(Get-OuAnzeige $u.DistinguishedName)")) }

    if ($u.Enabled) { $liste.Add((New-Pruefung 'AD' 'Konto aktiviert' 'OK' 'Aktiviert')) }
    else { $liste.Add((New-Pruefung 'AD' 'Konto aktiviert' 'WARNUNG' 'Konto ist deaktiviert.' 'Aktivieren' $null 'Konto aktivieren (Enable-ADAccount)')) }

    if ($u.LockedOut) { $liste.Add((New-Pruefung 'AD' 'Kontosperre' 'WARNUNG' 'Konto ist gesperrt (zu viele Fehlversuche).' 'Entsperren' $null 'Konto entsperren (Unlock-ADAccount)')) }

    # --- Namen
    if (-not $u.GivenName -or -not $u.Surname) {
        $liste.Add((New-Pruefung 'AD' 'Vor-/Nachname' 'FEHLER' "Vorname '$($u.GivenName)' / Nachname '$($u.Surname)' unvollständig – bitte in ADUC ergänzen."))
    }
    else {
        $sollAnzeige = "$($u.Surname) $($u.GivenName)"
        if ($u.DisplayName -eq $sollAnzeige) { $liste.Add((New-Pruefung 'AD' 'Anzeigename' 'OK' $u.DisplayName)) }
        else {
            $liste.Add((New-Pruefung 'AD' 'Anzeigename' 'WARNUNG' "'$($u.DisplayName)' entspricht nicht der Konvention 'Nachname Vorname'." `
                        'Attribut' @{ displayName = $sollAnzeige } "displayName:`n  vorher: $($u.DisplayName)`n  nachher: $sollAnzeige"))
        }
    }

    # --- UPN
    if ($upn -like "*@$($Config.MailDomain)") {
        if ($lokal -match '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$' -and $lokal -notmatch '\.\.') {
            $liste.Add((New-Pruefung 'AD' 'UPN' 'OK' $upn))
        }
        else {
            $liste.Add((New-Pruefung 'AD' 'UPN' 'FEHLER' "UPN '$upn' enthält ungültige Zeichen (erlaubt: a-z, 0-9, . _ -). Umbenennung manuell planen."))
        }
    }
    else {
        $basis = if ($lokal) { $lokal } else { $u.SamAccountName.ToLowerInvariant() }
        $sollUpn = "$basis@$($Config.MailDomain)"
        $liste.Add((New-Pruefung 'AD' 'UPN' 'FEHLER' "UPN '$upn' endet nicht auf @$($Config.MailDomain) – Anmeldung an Microsoft 365 nicht möglich." `
                    'Upn' $sollUpn "userPrincipalName:`n  vorher: $upn`n  nachher: $sollUpn`n`nACHTUNG: ändert den Anmeldenamen des Benutzers in Microsoft 365."))
    }
    if ($lokal -and $u.SamAccountName -ne $lokal) {
        $liste.Add((New-Pruefung 'AD' 'Konvention SAM = Mail' 'INFO' "Benutzername '$($u.SamAccountName)' weicht vom Mail-Namen '$lokal' ab (nur Hinweis)."))
    }

    # --- Mail-Attribute
    $upnIstMailfaehig = ($upn -like "*@$($Config.MailDomain)")
    if (-not $u.mail) {
        $liste.Add((New-Pruefung 'AD' 'mail' 'FEHLER' 'Attribut mail ist leer.' $(if ($upnIstMailfaehig) { 'Attribut' } else { '' }) @{ mail = $upn } "mail:`n  vorher: (leer)`n  nachher: $upn"))
    }
    elseif ($u.mail -ne $upn) {
        $liste.Add((New-Pruefung 'AD' 'mail' 'WARNUNG' "mail '$($u.mail)' ≠ UPN '$upn'." $(if ($upnIstMailfaehig) { 'Attribut' } else { '' }) @{ mail = $upn } "mail:`n  vorher: $($u.mail)`n  nachher: $upn"))
    }
    else { $liste.Add((New-Pruefung 'AD' 'mail' 'OK' $u.mail)) }

    if ($lokal) {
        if ($u.mailNickname -eq $lokal) { $liste.Add((New-Pruefung 'AD' 'mailNickname' 'OK' $u.mailNickname)) }
        else {
            $vorher = if ($u.mailNickname) { $u.mailNickname } else { '(leer)' }
            $liste.Add((New-Pruefung 'AD' 'mailNickname' 'WARNUNG' "mailNickname '$vorher' ≠ '$lokal'." 'Attribut' @{ mailNickname = $lokal } "mailNickname:`n  vorher: $vorher`n  nachher: $lokal"))
        }
    }

    # --- proxyAddresses
    $ist = @($u.proxyAddresses | ForEach-Object { [string]$_ })
    if ($upnIstMailfaehig) {
        $soll = Get-SollProxyAdressen -Aktuell $ist -Primaer $upn
        $primaere = @($ist | Where-Object { $_ -cmatch '^SMTP:' })
        $probleme = @()
        if ($primaere.Count -eq 0) { $probleme += 'keine primäre SMTP-Adresse' }
        elseif ($primaere.Count -gt 1) { $probleme += "$($primaere.Count) primäre SMTP-Adressen" }
        elseif ($primaere[0].Substring(5) -ne $upn) { $probleme += "primäre Adresse $($primaere[0].Substring(5)) ≠ UPN" }
        $fremd = @($ist | Where-Object { $_ -match '^smtp:(.+)$' -and -not (Test-ErlaubteMailDomain $Matches[1]) })
        if ($fremd) { $probleme += "fremde Domains: $(($fremd | ForEach-Object { $_.Substring(5) }) -join ', ')" }
        if ((Get-ProxySchluessel $ist) -ne (Get-ProxySchluessel $soll)) {
            if (-not $probleme) { $probleme += 'Duplikate bzw. nicht normalisiert' }
            $status = if ($primaere.Count -ne 1) { 'FEHLER' } else { 'WARNUNG' }
            $vorschau = "proxyAddresses vorher:`n  " + ($(if ($ist) { $ist -join "`n  " } else { '(leer)' })) +
            "`n`nproxyAddresses nachher:`n  " + ($soll -join "`n  ") + "`n`n(x500/X400/sip und Aliase auf @$($Config.MailDomain) bleiben erhalten.)"
            $liste.Add((New-Pruefung 'AD' 'proxyAddresses' $status ($probleme -join '; ') 'Proxy' $soll $vorschau))
        }
        else {
            $aliase = @($ist | Where-Object { $_ -cmatch '^smtp:' }).Count
            $liste.Add((New-Pruefung 'AD' 'proxyAddresses' 'OK' "Primär $upn, $aliase Alias(e), $(@($ist).Count) Einträge gesamt"))
        }
    }

    # --- Adresskonflikte im ganzen AD
    $adressen = @($upn, [string]$u.mail) + @($ist | Where-Object { $_ -match '^smtp:' } | ForEach-Object { $_.Substring(5) })
    $konflikte = @()
    foreach ($a in @($adressen | Where-Object { $_ } | Select-Object -Unique)) {
        foreach ($k in (Get-AdressKonflikte -Adresse $a -AusserDn $u.DistinguishedName)) { $konflikte += "$a → $($k.DistinguishedName)" }
    }
    if ($konflikte) { $liste.Add((New-Pruefung 'AD' 'Adress-Duplikate' 'FEHLER' ("Adresse auch bei anderem Objekt vorhanden (Sync-Fehler!): " + ($konflikte -join '; ')))) }
    else { $liste.Add((New-Pruefung 'AD' 'Adress-Duplikate' 'OK' 'Keine Duplikate im AD')) }

    # --- Passwort
    if ($u.PasswordNeverExpires) {
        $liste.Add((New-Pruefung 'AD' 'Passwort läuft nie ab' 'WARNUNG' 'PasswordNeverExpires ist gesetzt.' 'PwdNeverExpires' $null 'PasswordNeverExpires entfernen'))
    }
    if ($u.pwdLastSet -eq 0) {
        $alter = [int]((Get-Date) - $u.whenCreated).TotalDays
        if ($alter -gt $Config.InitialPasswortTage) {
            $liste.Add((New-Pruefung 'AD' 'Initialpasswort' 'WARNUNG' "Seit $alter Tagen nicht geändert – das Initialpasswort gilt weiterhin auch in Microsoft 365."))
        }
        else { $liste.Add((New-Pruefung 'AD' 'Initialpasswort' 'INFO' 'Muss bei der nächsten Anmeldung geändert werden.')) }
    }
    elseif ($u.PasswordExpired) {
        $liste.Add((New-Pruefung 'AD' 'Passwort abgelaufen' 'WARNUNG' 'Das Passwort ist abgelaufen.'))
    }

    $richtlinie = Get-PasswortRichtlinie -Identitaet $u.DistinguishedName
    if ($richtlinie.Name -eq $Config.BenutzerFgpp) {
        $liste.Add((New-Pruefung 'AD' 'Passwortrichtlinie' 'OK' "$($richtlinie.Name) (min. $($richtlinie.MinLaenge) Zeichen)"))
    }
    elseif ($richtlinie.IstFgpp) {
        $liste.Add((New-Pruefung 'AD' 'Passwortrichtlinie' 'INFO' "$($richtlinie.Name) (min. $($richtlinie.MinLaenge) Zeichen)"))
    }
    else {
        $liste.Add((New-Pruefung 'AD' 'Passwortrichtlinie' 'WARNUNG' "Keine FGPP – nur Default Domain Policy (min. $($richtlinie.MinLaenge) Zeichen, Komplexität: $($richtlinie.Komplex))." `
                    'Fgpp' $null "Benutzer in eine Gruppe aufnehmen, für die '$($Config.BenutzerFgpp)' gilt."))
    }

    # --- Entra ID
    if (-not $script:GraphVerbunden) {
        $liste.Add((New-Pruefung 'Entra' 'Entra-Prüfungen' 'INFO' 'Nicht mit Microsoft 365 verbunden – oben rechts "Mit Microsoft 365 verbinden".'))
        return $liste
    }
    $treffer = Find-EntraBenutzer -ImmutableIds (Get-ImmutableIdKandidaten $u) -Upn $upn
    if (-not $treffer) {
        if ($inSync) {
            $liste.Add((New-Pruefung 'Entra' 'Objekt in Entra ID' 'FEHLER' 'Kein Entra-Objekt gefunden (weder ImmutableId noch UPN). Neu angelegt oder verschoben? Dann Sync auslösen.' 'EntraSync' $null "AD-Replikation + Delta-Sync auf $($Config.EntraConnectServer) starten"))
        }
        else { $liste.Add((New-Pruefung 'Entra' 'Objekt in Entra ID' 'INFO' 'Kein Entra-Objekt – erwartet, da keine Sync-OU.')) }
        return $liste
    }
    $e = $treffer.Benutzer
    if (-not $e.onPremisesSyncEnabled) {
        $liste.Add((New-Pruefung 'Entra' 'Objekt in Entra ID' 'FEHLER' "Cloud-Objekt $($e.userPrincipalName) mit gleicher UPN ist NICHT synchronisiert – Konflikt manuell lösen (Hard-Match oder Cloud-Objekt entfernen)."))
        return $liste
    }
    if ($treffer.Treffer -eq 'UPN') {
        $liste.Add((New-Pruefung 'Entra' 'Objekt in Entra ID' 'FEHLER' "Entra-Objekt mit gleicher UPN gehört zu einem anderen AD-Objekt (ImmutableId $($e.onPremisesImmutableId) ≠ $((Get-ImmutableIdKandidaten $u) -join ' / '))."))
        return $liste
    }
    $letzterSync = if ($e.onPremisesLastSyncDateTime) { ([DateTime]$e.onPremisesLastSyncDateTime).ToLocalTime().ToString('dd.MM.yyyy HH:mm') } else { '-' }
    $liste.Add((New-Pruefung 'Entra' 'Objekt in Entra ID' 'OK' "Synchronisiert (Hard-Match), zuletzt geändert per Sync: $letzterSync"))

    $pfListe = @($e.onPremisesProvisioningErrors | Where-Object { $_ })
    if ($pfListe) {
        $liste.Add((New-Pruefung 'Entra' 'Provisioning-Fehler' 'FEHLER' (($pfListe | ForEach-Object { "$($_.category): $($_.propertyCausingError) = $($_.value)" }) -join '; ')))
    }
    else { $liste.Add((New-Pruefung 'Entra' 'Provisioning-Fehler' 'OK' 'Keine')) }

    $abweichungen = @()
    if ($e.userPrincipalName -ne $upn) { $abweichungen += "UPN Entra '$($e.userPrincipalName)'" }
    if ($e.displayName -ne $u.DisplayName) { $abweichungen += "Anzeigename Entra '$($e.displayName)'" }
    if ([bool]$e.accountEnabled -ne [bool]$u.Enabled) { $abweichungen += "Aktiviert Entra = $($e.accountEnabled)" }
    if ($abweichungen) {
        $liste.Add((New-Pruefung 'Entra' 'Abgleich AD ↔ Entra' 'WARNUNG' ("Noch nicht synchronisiert: " + ($abweichungen -join '; ')) 'EntraSync' $null "AD-Replikation + Delta-Sync auf $($Config.EntraConnectServer) starten"))
    }
    else { $liste.Add((New-Pruefung 'Entra' 'Abgleich AD ↔ Entra' 'OK' 'UPN, Anzeigename und Status identisch')) }

    if ($e.usageLocation -eq $Config.UsageLocation) { $liste.Add((New-Pruefung 'Entra' 'UsageLocation' 'OK' $e.usageLocation)) }
    else {
        $vorher = if ($e.usageLocation) { $e.usageLocation } else { '(leer)' }
        $liste.Add((New-Pruefung 'Entra' 'UsageLocation' 'WARNUNG' "UsageLocation '$vorher' – für Lizenzen muss sie gesetzt sein." 'UsageLocation' $e.id "usageLocation:`n  vorher: $vorher`n  nachher: $($Config.UsageLocation)"))
    }

    $lizenzen = @($e.assignedLicenses | ForEach-Object { Get-SkuNameNachId ([string]$_.skuId) })
    if ($lizenzen) { $liste.Add((New-Pruefung 'Entra' 'Lizenz' 'OK' ($lizenzen -join ', '))) }
    else { $liste.Add((New-Pruefung 'Entra' 'Lizenz' 'WARNUNG' 'Keine Lizenz zugewiesen.' 'Lizenz' $e.id 'Eine freie Lizenz auswählen und zuweisen')) }

    $lizFehler = @($e.licenseAssignmentStates | Where-Object { $_.state -eq 'Error' })
    if ($lizFehler) {
        $liste.Add((New-Pruefung 'Entra' 'Lizenzstatus' 'FEHLER' (($lizFehler | ForEach-Object { "$(Get-SkuNameNachId ([string]$_.skuId)): $($_.error)" }) -join '; ')))
    }
    return $liste
}

function Invoke-Diagnose {
    if (-not $script:DiagnoseDn) { return }
    $ui = $script:Ui
    Write-Log "Diagnose: $script:DiagnoseDn"
    $ergebnisse = @(Get-DiagnoseErgebnisse -Dn $script:DiagnoseDn)
    # Geschützte Konten: nur anzeigen, keine Korrektur-Buttons
    if (Test-Geschuetzt (Get-ADUser -Identity $script:DiagnoseDn -Server $script:DC).SamAccountName) {
        foreach ($r in $ergebnisse) { $r.FixTyp = ''; $r.FixLabel = '' }
    }
    $ui.dgDiagnose.ItemsSource = $ergebnisse
    $f = @($ergebnisse | Where-Object Status -eq 'FEHLER').Count
    $w = @($ergebnisse | Where-Object Status -eq 'WARNUNG').Count
    $o = @($ergebnisse | Where-Object Status -eq 'OK').Count
    $ui.lblDiagZusammenfassung.Text = "$f Fehler · $w Warnung(en) · $o in Ordnung"
    Write-Log "Diagnose-Ergebnis: $f Fehler, $w Warnungen, $o OK" $(if ($f) { 'FEHLER' } elseif ($w) { 'WARNUNG' } else { 'OK' })
}

function Invoke-DiagnoseKorrektur {
    param([Parameter(Mandatory)]$Eintrag)
    $dn = $script:DiagnoseDn
    $u = Get-ADUser -Identity $dn -Server $script:DC
    if (Test-Geschuetzt $u.SamAccountName) {
        Show-Meldung -Text "'$($u.SamAccountName)' ist ein geschütztes Konto – keine Änderungen." -Titel 'Geschützt' -Symbol 'Stop'
        return
    }

    $vorschau = $Eintrag.Vorschau
    $auswahl = $null
    switch ($Eintrag.FixTyp) {
        'Fgpp' {
            $fgpp = Get-ADFineGrainedPasswordPolicy -Identity $Config.BenutzerFgpp -Server $script:DC
            $gruppen = @()
            foreach ($ziel in $fgpp.AppliesTo) {
                $mitglieder = @(Get-ADGroupMember -Identity $ziel -Server $script:DC | Where-Object objectClass -eq 'group')
                if ($mitglieder) { $gruppen += $mitglieder } else { $gruppen += Get-ADGroup -Identity $ziel -Server $script:DC }
            }
            $items = @($gruppen | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Anzeige = $_.Name; DistinguishedName = $_.DistinguishedName } })
            $auswahl = Show-AuswahlDialog -Titel 'Passwortrichtlinie' -Text "In welche Gruppe soll $($u.SamAccountName) aufgenommen werden? (alle erhalten '$($Config.BenutzerFgpp)')" -Eintraege $items
            if (-not $auswahl) { return }
            $vorschau = "Gruppe hinzufügen: $($auswahl.Anzeige)"
        }
        'Lizenz' {
            if (-not $script:AlleSkus) { Update-Lizenzen }
            $items = @($script:AlleSkus | Where-Object { $_.Waehlbar -and $_.Frei -gt 0 })
            if (-not $items) { Show-Meldung -Text 'Keine freien Lizenzen verfügbar.' -Symbol 'Warning'; return }
            $auswahl = Show-AuswahlDialog -Titel 'Lizenz zuweisen' -Text "Welche Lizenz soll $($u.SamAccountName) erhalten?" -Eintraege $items
            if (-not $auswahl) { return }
            $vorschau = "Lizenz zuweisen: $($auswahl.Name)`nFalls nötig wird zuerst UsageLocation = $($Config.UsageLocation) gesetzt."
        }
    }

    $titel = if (Test-Simulation) { "Korrektur – SIMULATION" } else { 'Korrektur bestätigen' }
    if (-not (Confirm-Aktion "$($Eintrag.Pruefung) – $($u.SamAccountName)`n`n$vorschau`n`nJetzt ausführen?" $titel)) { return }

    $protokoll = ($vorschau -replace "`r?`n\s*", ' | ')
    if (Test-Simulation) {
        Write-Log "[Simulation] Korrektur '$($Eintrag.Pruefung)' für $($u.SamAccountName): $protokoll" 'SIM'
        return
    }
    Write-Log "Korrektur '$($Eintrag.Pruefung)' für $($u.SamAccountName): $protokoll"

    switch ($Eintrag.FixTyp) {
        'Aktivieren'      { Enable-ADAccount -Identity $dn -Server $script:DC }
        'Entsperren'      { Unlock-ADAccount -Identity $dn -Server $script:DC }
        'Attribut'        { Set-ADUser -Identity $dn -Replace $Eintrag.FixDaten -Server $script:DC }
        'Upn'             { Set-ADUser -Identity $dn -UserPrincipalName $Eintrag.FixDaten -Server $script:DC }
        'Proxy'           { Set-ADUser -Identity $dn -Replace @{ proxyAddresses = [string[]]$Eintrag.FixDaten } -Server $script:DC }
        'PwdNeverExpires' { Set-ADUser -Identity $dn -PasswordNeverExpires $false -Server $script:DC }
        'Fgpp'            {
            Add-ADGroupMember -Identity $auswahl.DistinguishedName -Members $dn -Server $script:DC
            Sync-AdReplikation @($auswahl.DistinguishedName)
        }
        'EntraSync'       {
            Sync-AdReplikation @($dn)
            Start-EntraSync
        }
        'UsageLocation'   { Set-UsageLocation -EntraId $Eintrag.FixDaten }
        'Lizenz'          {
            $e = (Invoke-Graph -Uri "/v1.0/users/$($Eintrag.FixDaten)?`$select=id,usageLocation")
            if ($e.usageLocation -ne $Config.UsageLocation) { Set-UsageLocation -EntraId $Eintrag.FixDaten }
            Add-EntraLizenz -EntraId $Eintrag.FixDaten -Sku $auswahl
        }
        default           { throw "Unbekannter Korrekturtyp '$($Eintrag.FixTyp)'." }
    }
    Write-Log "Korrektur '$($Eintrag.Pruefung)' ausgeführt." 'OK'
    if ($Eintrag.Bereich -eq 'AD' -and $Eintrag.FixTyp -ne 'Fgpp') {
        Write-Log 'Hinweis: AD-Änderungen erscheinen in Entra ID erst nach dem nächsten Sync ("Sync auslösen").'
    }
    Invoke-Diagnose
}

function Update-Statuszeile {
    $m365 = if ($script:GraphVerbunden) { "M365: $script:GraphKonto" } else { 'M365: nicht verbunden' }
    $script:Ui.lblStatus.Text = "Domäne $((Get-ADDomain -Server $script:DC).DNSRoot)  ·  DC $script:DC  ·  Entra Connect $($Config.EntraConnectServer)  ·  $m365  ·  Angemeldet: $env:USERDOMAIN\$env:USERNAME"
    if ($script:GraphVerbunden) { $script:Ui.btnM365.Content = 'Lizenzen aktualisieren' }
}

# ---------------------------------------------------------------------------
# Oberfläche
# ---------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="AD-Verwaltung – Benutzer, Entra-Sync, Lizenzen, Diagnose"
        Width="1180" Height="880" MinWidth="900" MinHeight="650"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Padding" Value="12,4"/>
      <Setter Property="Margin" Value="4"/>
      <Setter Property="MinWidth" Value="90"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Padding" Value="3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Padding" Value="4,3"/>
    </Style>
    <Style TargetType="TextBlock" x:Key="Feld">
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="4,0,8,0"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Padding" Value="6"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Top" Background="#1F3A5F" Padding="14,8">
      <DockPanel>
        <Button x:Name="btnM365" DockPanel.Dock="Right" Content="Mit Microsoft 365 verbinden" VerticalAlignment="Center"/>
        <CheckBox x:Name="chkSimulation" DockPanel.Dock="Right" Content="Nur simulieren (keine Änderungen)"
                  Foreground="White" VerticalAlignment="Center" Margin="12,0"/>
        <StackPanel>
          <TextBlock Text="AD-Verwaltung" Foreground="White" FontSize="18" FontWeight="SemiBold"/>
          <TextBlock x:Name="lblStatus" Foreground="#CFE0F5" FontSize="12" TextTrimming="CharacterEllipsis"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <GroupBox DockPanel.Dock="Bottom" Header="Protokoll" Margin="10,0,10,10" Height="170">
      <TextBox x:Name="txtLog" IsReadOnly="True" FontFamily="Consolas" FontSize="12" Margin="0"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
    </GroupBox>

    <TabControl Margin="10,10,10,8">
      <TabItem Header="  Benutzer anlegen / kopieren  ">
        <Grid Margin="10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="3*"/>
            <ColumnDefinition Width="16"/>
            <ColumnDefinition Width="2*"/>
          </Grid.ColumnDefinitions>
          <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
            <StackPanel>
              <GroupBox Header="1. Vorlage (optional – wie „Kopieren“ in ADUC)">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBox x:Name="txtVorlageSuche" Grid.Column="0" ToolTip="Name, Benutzername oder E-Mail der Vorlage"/>
                  <Button x:Name="btnVorlageSuchen" Grid.Column="1" Content="Suchen" IsDefault="False"/>
                  <Button x:Name="btnVorlageLeeren" Grid.Column="2" Content="Ohne Vorlage"/>
                  <ComboBox x:Name="cmbVorlage" Grid.Row="1" Grid.ColumnSpan="3" DisplayMemberPath="Anzeige"/>
                </Grid>
              </GroupBox>
              <GroupBox Header="2. Neuer Benutzer">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <TextBlock Grid.Row="0" Style="{StaticResource Feld}" Text="Vorname"/>
                  <TextBox x:Name="txtVorname" Grid.Row="0" Grid.Column="1"/>
                  <TextBlock Grid.Row="1" Style="{StaticResource Feld}" Text="Nachname"/>
                  <TextBox x:Name="txtNachname" Grid.Row="1" Grid.Column="1"/>
                  <TextBlock Grid.Row="2" Style="{StaticResource Feld}" Text="Benutzername (SAM)"/>
                  <TextBox x:Name="txtSam" Grid.Row="2" Grid.Column="1"/>
                  <TextBlock Grid.Row="3" Style="{StaticResource Feld}" Text="E-Mail / UPN"/>
                  <TextBox x:Name="txtUpn" Grid.Row="3" Grid.Column="1"/>
                  <TextBlock Grid.Row="4" Style="{StaticResource Feld}" Text="Anzeigename"/>
                  <TextBox x:Name="txtAnzeigename" Grid.Row="4" Grid.Column="1"/>
                  <TextBlock Grid.Row="5" Style="{StaticResource Feld}" Text="OU"/>
                  <ComboBox x:Name="cmbOU" Grid.Row="5" Grid.Column="1" DisplayMemberPath="Anzeige"/>
                  <TextBlock Grid.Row="6" Style="{StaticResource Feld}" Text="Initialpasswort"/>
                  <TextBox x:Name="txtPasswort" Grid.Row="6" Grid.Column="1" FontFamily="Consolas"/>
                  <TextBlock x:Name="lblHinweis" Grid.Row="7" Grid.Column="1" Foreground="#9A6700" TextWrapping="Wrap" Margin="4,2"/>
                </Grid>
              </GroupBox>
              <GroupBox Header="3. Microsoft 365">
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="150"/>
                    <ColumnDefinition Width="*"/>
                  </Grid.ColumnDefinitions>
                  <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/><RowDefinition Height="Auto"/>
                  </Grid.RowDefinitions>
                  <CheckBox x:Name="chkSync" Grid.ColumnSpan="2" IsChecked="True" Margin="4,6"
                            Content="Nach dem Anlegen Entra-Sync starten, UsageLocation CH setzen und Lizenz zuweisen"/>
                  <TextBlock Grid.Row="1" Style="{StaticResource Feld}" Text="Lizenz"/>
                  <ComboBox x:Name="cmbLizenz" Grid.Row="1" Grid.Column="1" DisplayMemberPath="Anzeige" IsEnabled="False"
                            ToolTip="Erst nach der Anmeldung an Microsoft 365 verfügbar"/>
                </Grid>
              </GroupBox>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="btnAnlegen" Content="Benutzer anlegen" FontWeight="SemiBold" Padding="18,6"/>
                <Button x:Name="btnDrucken" Content="Zugangsblatt drucken" IsEnabled="False" Padding="18,6"/>
              </StackPanel>
            </StackPanel>
          </ScrollViewer>
          <GroupBox Grid.Column="2" Header="Aus der Vorlage übernommen">
            <Grid>
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <TextBlock Text="Gruppen" FontWeight="SemiBold" Margin="2,0,0,4"/>
              <ListBox x:Name="lstGruppen" Grid.Row="1"/>
              <TextBlock Grid.Row="2" Text="Attribute" FontWeight="SemiBold" Margin="2,10,0,4"/>
              <ListBox x:Name="lstAttribute" Grid.Row="3"/>
            </Grid>
          </GroupBox>
        </Grid>
      </TabItem>

      <TabItem Header="  Diagnose  ">
        <DockPanel Margin="10">
          <Grid DockPanel.Dock="Top">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="260"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBox x:Name="txtDiagSuche" Grid.Column="0" ToolTip="Name, Benutzername oder E-Mail"/>
            <Button x:Name="btnDiagSuchen" Grid.Column="1" Content="Suchen"/>
            <ComboBox x:Name="cmbDiagBenutzer" Grid.Column="2" DisplayMemberPath="Anzeige"/>
            <Button x:Name="btnDiagStart" Grid.Column="3" Content="Prüfen" FontWeight="SemiBold"/>
            <Button x:Name="btnDiagSync" Grid.Column="4" Content="Sync auslösen"/>
          </Grid>
          <TextBlock x:Name="lblDiagZusammenfassung" DockPanel.Dock="Top" Margin="4,10,4,6" FontWeight="SemiBold"/>
          <DataGrid x:Name="dgDiagnose" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"
                    HeadersVisibility="Column" GridLinesVisibility="Horizontal" SelectionMode="Single"
                    HorizontalGridLinesBrush="#DDDDDD" RowHeaderWidth="0">
            <DataGrid.RowStyle>
              <Style TargetType="DataGridRow">
                <Style.Triggers>
                  <DataTrigger Binding="{Binding Status}" Value="FEHLER"><Setter Property="Background" Value="#FDE2E1"/></DataTrigger>
                  <DataTrigger Binding="{Binding Status}" Value="WARNUNG"><Setter Property="Background" Value="#FFF4CE"/></DataTrigger>
                  <DataTrigger Binding="{Binding Status}" Value="OK"><Setter Property="Background" Value="#EAF6EC"/></DataTrigger>
                </Style.Triggers>
              </Style>
            </DataGrid.RowStyle>
            <DataGrid.Columns>
              <DataGridTextColumn Header="" Binding="{Binding Symbol}" Width="28"/>
              <DataGridTextColumn Header="Bereich" Binding="{Binding Bereich}" Width="60"/>
              <DataGridTextColumn Header="Prüfung" Binding="{Binding Pruefung}" Width="170"/>
              <DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="*">
                <DataGridTextColumn.ElementStyle>
                  <Style TargetType="TextBlock">
                    <Setter Property="TextWrapping" Value="Wrap"/>
                    <Setter Property="Margin" Value="2,3"/>
                  </Style>
                </DataGridTextColumn.ElementStyle>
              </DataGridTextColumn>
              <DataGridTemplateColumn Header="Aktion" Width="120">
                <DataGridTemplateColumn.CellTemplate>
                  <DataTemplate>
                    <Button Content="{Binding FixLabel}" Tag="{Binding}" Margin="2" Padding="8,2">
                      <Button.Style>
                        <Style TargetType="Button">
                          <Style.Triggers>
                            <DataTrigger Binding="{Binding FixLabel}" Value="">
                              <Setter Property="Visibility" Value="Collapsed"/>
                            </DataTrigger>
                          </Style.Triggers>
                        </Style>
                      </Button.Style>
                    </Button>
                  </DataTemplate>
                </DataGridTemplateColumn.CellTemplate>
              </DataGridTemplateColumn>
            </DataGrid.Columns>
          </DataGrid>
        </DockPanel>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@

$script:Window = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($knoten in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $name = $knoten.Attributes | Where-Object LocalName -eq 'Name' | Select-Object -ExpandProperty Value
    $script:Ui[$name] = $script:Window.FindName($name)
}
$ui = $script:Ui

# --- Startwerte
# Initialpasswort bewusst leer: wird bei jeder Anlage eingegeben (kein Passwort im Skript/Git)
$ui.cmbOU.ItemsSource = @(Get-SyncOus)
Update-Statuszeile

# --- Namensvorschlag mit kurzer Verzögerung beim Tippen
$script:NamensTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:NamensTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:NamensTimer.Add_Tick({
        $script:NamensTimer.Stop()
        Invoke-UiAktion { Update-NamensVorschlag }
    })
$namensHandler = { $script:NamensTimer.Stop(); $script:NamensTimer.Start() }
$ui.txtVorname.Add_TextChanged($namensHandler)
$ui.txtNachname.Add_TextChanged($namensHandler)

# --- Kopfzeile
$ui.btnM365.Add_Click({
        Invoke-UiAktion {
            if ($script:GraphVerbunden) { Update-Lizenzen } else { Connect-M365 }
        }
    })
$ui.chkSimulation.Add_Click({
        $zustand = if (Test-Simulation) { 'EIN' } else { 'AUS' }
        Write-Log "Simulationsmodus $zustand."
    })

# --- Anlegen
$vorlageSuchen = {
    Invoke-UiAktion {
        $treffer = @(Find-AdBenutzer $script:Ui.txtVorlageSuche.Text)
        $script:Ui.cmbVorlage.ItemsSource = $treffer
        if ($treffer.Count -eq 0) { Write-Log "Keine Vorlage gefunden für '$($script:Ui.txtVorlageSuche.Text)'." 'WARNUNG' }
        else { $script:Ui.cmbVorlage.IsDropDownOpen = $true }
    }
}
$ui.btnVorlageSuchen.Add_Click($vorlageSuchen)
$ui.txtVorlageSuche.Add_KeyDown({ if ($_.Key -eq 'Return') { & $vorlageSuchen } })
$ui.cmbVorlage.Add_SelectionChanged({
        $eintrag = $script:Ui.cmbVorlage.SelectedItem
        if ($eintrag) { Invoke-UiAktion { Set-Vorlage $eintrag } }
    })
$ui.btnVorlageLeeren.Add_Click({
        $script:Ui.cmbVorlage.SelectedIndex = -1
        $script:Ui.cmbVorlage.ItemsSource = $null
        $script:Ui.txtVorlageSuche.Text = ''
        Set-Vorlage $null
        Write-Log 'Ohne Vorlage – neuer, leerer Benutzer.'
    })
$ui.btnAnlegen.Add_Click({ Invoke-UiAktion { Invoke-BenutzerAnlage } })
$ui.btnDrucken.Add_Click({ Invoke-UiAktion { Invoke-ZugangsblattDruck } })

# --- Diagnose
$diagSuchen = {
    Invoke-UiAktion {
        $treffer = @(Find-AdBenutzer $script:Ui.txtDiagSuche.Text)
        $script:Ui.cmbDiagBenutzer.ItemsSource = $treffer
        if ($treffer.Count -eq 1) { $script:Ui.cmbDiagBenutzer.SelectedIndex = 0 }
        elseif ($treffer.Count -gt 1) { $script:Ui.cmbDiagBenutzer.IsDropDownOpen = $true }
        else { Write-Log "Kein Benutzer gefunden für '$($script:Ui.txtDiagSuche.Text)'." 'WARNUNG' }
    }
}
$ui.btnDiagSuchen.Add_Click($diagSuchen)
$ui.txtDiagSuche.Add_KeyDown({ if ($_.Key -eq 'Return') { & $diagSuchen } })
$ui.cmbDiagBenutzer.Add_SelectionChanged({
        $eintrag = $script:Ui.cmbDiagBenutzer.SelectedItem
        if ($eintrag) {
            $script:DiagnoseDn = $eintrag.DistinguishedName
            Invoke-UiAktion { Invoke-Diagnose }
        }
    })
$ui.btnDiagStart.Add_Click({ Invoke-UiAktion { Invoke-Diagnose } })
$ui.btnDiagSync.Add_Click({
        Invoke-UiAktion {
            if ($script:DiagnoseDn -and -not (Test-Simulation)) { Sync-AdReplikation @($script:DiagnoseDn) }
            Start-EntraSync
            Invoke-Diagnose
        }
    })
$ui.dgDiagnose.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
        param($absender, $e)
        $eintrag = $e.OriginalSource.Tag
        if ($eintrag -and $eintrag.FixTyp) { Invoke-UiAktion { Invoke-DiagnoseKorrektur -Eintrag $eintrag } }
    })

Write-Log "AD-Verwaltung gestartet (DC $script:DC, $(@($ui.cmbOU.ItemsSource).Count) Sync-OUs)."
[void]$script:Window.ShowDialog()
if ($script:GraphVerbunden) { try { Disconnect-MgGraph | Out-Null } catch { } }
