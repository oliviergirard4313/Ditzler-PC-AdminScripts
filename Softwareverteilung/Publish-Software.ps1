#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage
<#
.SYNOPSIS
    Laedt einen Software-Installer in den Azure Storage Account der
    Softwareverteilung hoch (ditzlersoftware / Container software).

.DESCRIPTION
    Ablage: software/<Hersteller>/<Produkt>/<Version>/<Dateiname>

    - Eine veroeffentlichte Version wird NIE ueberschrieben. Existiert der
      Blob bereits, bricht das Skript ab (neue Version = neuer Ordner).
    - Anmeldung mit dem eigenen Entra-Konto (Rolle "Storage Blob Data
      Contributor" auf ditzlersoftware), kein Kontoschluessel, kein SAS.
    - Berechnet den SHA256-Hash. Dieser Hash ist die Referenz fuer
      Get-DitzlerSoftware und muss im SuperOps-Skript hinterlegt werden.
      Der Hash wird zusaetzlich als Blob-Metadatum "sha256" gespeichert
      (nur zur Information, NICHT als Vertrauensquelle verwenden).
    - Ergebnis (Pfad, URL, Hash, Groesse) in der Konsole und in
      C:\Temp\GIO-Ausgabe\Publish-Software_<Hersteller>_<Produkt>_<Version>.txt
    - Die vollstaendige URL MIT SAS (Policy "clients-lesen") wird nur in die
      Zwischenablage kopiert - direkt in SuperOps "Installer URL" einfuegen.
      Der SAS landet nie in der Ausgabedatei oder in der Konsole.

    Erlaubte Zeichen in Hersteller/Produkt/Version/Dateiname: A-Z a-z 0-9 . _ -
    (keine Leerzeichen - vermeidet Kodierungsprobleme in URLs und SuperOps).

.PARAMETER Pfad
    Lokaler Pfad zur Installer-Datei.

.PARAMETER Hersteller
    z.B. Nutanix, 7-Zip, Adobe

.PARAMETER Produkt
    z.B. NGT, 7-Zip, AcrobatReader

.PARAMETER Version
    z.B. 4.5.1.8

.EXAMPLE
    .\Publish-Software.ps1 -Pfad D:\Setup\7z2501-x64.msi -Hersteller 7-Zip -Produkt 7-Zip -Version 25.01

.NOTES
    Autor   : GIO / Claude
    Version : 1.1
    Datum   : 26.11.2026
    Laeuft auf SV-OS-DEV-01 (Az-Module installiert), PowerShell 7.

    Aenderungen:
      1.0  26.11.2026  Erste Version
      1.1  26.11.2026  URL mit SAS in die Zwischenablage (SAS wird aus der
                       Stored Access Policy erzeugt, braucht Leserecht auf
                       die Kontoschluessel, z.B. Owner); Anzeige-Bug
                       "$basisUrl?" behoben
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Pfad,
    [Parameter(Mandatory)] [string] $Hersteller,
    [Parameter(Mandatory)] [string] $Produkt,
    [Parameter(Mandatory)] [string] $Version,
    [string] $StorageAccount = 'ditzlersoftware',
    [string] $Container      = 'software',
    [string] $ResourceGroup  = 'rg-softwareverteilung',
    [string] $SasPolicy      = 'clients-lesen',
    [string] $Tenant        = 'ditzler.onmicrosoft.com',
    [string] $SubscriptionId = '6503f610-26e8-4dc3-aa08-71ae788d8e09',
    [string] $AusgabeOrdner  = 'C:\Temp\GIO-Ausgabe'
)

$ErrorActionPreference = 'Stop'

# --- 1. Eingaben pruefen -------------------------------------------------
$datei = Get-Item -LiteralPath $Pfad -ErrorAction SilentlyContinue
if (-not $datei -or $datei.PSIsContainer) {
    throw "Datei nicht gefunden: $Pfad"
}

$erlaubt = '^[A-Za-z0-9._-]+$'
foreach ($teil in @(
        @{ Name = 'Hersteller'; Wert = $Hersteller },
        @{ Name = 'Produkt';    Wert = $Produkt },
        @{ Name = 'Version';    Wert = $Version },
        @{ Name = 'Dateiname';  Wert = $datei.Name })) {
    if ($teil.Wert -notmatch $erlaubt -or $teil.Wert -match '^\.+$') {
        throw "$($teil.Name) '$($teil.Wert)' enthaelt unerlaubte Zeichen (erlaubt: A-Z a-z 0-9 . _ -). Datei ggf. vorher umbenennen."
    }
}

$blobName = "$Hersteller/$Produkt/$Version/$($datei.Name)"
$basisUrl = "https://$StorageAccount.blob.core.windows.net/$Container/$blobName"

# --- 2. Anmeldung --------------------------------------------------------
$ctx = Get-AzContext
if (-not $ctx -or $ctx.Subscription.Id -ne $SubscriptionId) {
    Write-Host 'Anmeldung an Azure ...' -ForegroundColor Yellow
    Connect-AzAccount -Tenant $Tenant -Subscription $SubscriptionId | Out-Null
}
$storageCtx = New-AzStorageContext -StorageAccountName $StorageAccount -UseConnectedAccount

# --- 3. Nicht ueberschreiben --------------------------------------------
$vorhanden = Get-AzStorageBlob -Container $Container -Blob $blobName -Context $storageCtx -ErrorAction SilentlyContinue
if ($vorhanden) {
    throw "Blob existiert bereits: $blobName - eine veroeffentlichte Version wird nie ueberschrieben. Neue Version = neuer Versionsordner."
}

# --- 4. Hash -------------------------------------------------------------
Write-Host "SHA256 berechnen: $($datei.Name) ($([math]::Round($datei.Length / 1MB, 1)) MB) ..." -ForegroundColor Yellow
$sha256 = (Get-FileHash -LiteralPath $datei.FullName -Algorithm SHA256).Hash.ToUpperInvariant()

# --- 5. Upload -----------------------------------------------------------
Write-Host "Upload nach $Container/$blobName ..." -ForegroundColor Yellow
$param = @{
    File       = $datei.FullName
    Container  = $Container
    Blob       = $blobName
    Context    = $storageCtx
    Properties = @{ ContentType = 'application/octet-stream' }
    Metadata   = @{
        sha256        = $sha256
        hochgeladenVon = $env:USERNAME
        hochgeladenAm  = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    }
}
Set-AzStorageBlobContent @param | Out-Null

# --- 6. Kontrolle --------------------------------------------------------
$blob = Get-AzStorageBlob -Container $Container -Blob $blobName -Context $storageCtx
if ($blob.Length -ne $datei.Length) {
    throw "Groesse stimmt nicht: lokal $($datei.Length) Bytes, Azure $($blob.Length) Bytes."
}

# --- 7. Ergebnis ---------------------------------------------------------
$zeilen = @(
    "Datum        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    "Rechner      : $env:COMPUTERNAME"
    "Datei        : $($datei.FullName)"
    "Groesse      : $($datei.Length) Bytes"
    ''
    "Blob-Pfad    : $blobName"
    "SHA256       : $sha256"
    ''
    'Get-DitzlerSoftware (SuperOps-Skript):'
    "  Get-DitzlerSoftware -Pfad '$blobName' -Sha256 '$sha256' -Sas `$Sas"
    ''
    'SuperOps Custom Software (Methode URL) - URL ohne SAS:'
    "  $basisUrl"
)

# --- 8. URL mit SAS in die Zwischenablage -------------------------------
# Upload ist bereits erfolgreich - ein Fehler hier bricht nicht ab.
$zwischenablage = $false
try {
    $key    = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroup -Name $StorageAccount)[0].Value
    $keyCtx = New-AzStorageContext -StorageAccountName $StorageAccount -StorageAccountKey $key
    $sas    = (New-AzStorageContainerSASToken -Name $Container -Policy $SasPolicy -Protocol HttpsOnly -Context $keyCtx).TrimStart('?')
    # ${} noetig: '?' ist in PowerShell ein gueltiges Zeichen im Variablennamen
    Set-Clipboard -Value "${basisUrl}?$sas"
    $zwischenablage = $true
}
catch {
    Write-Warning "URL mit SAS konnte nicht erzeugt werden: $($_.Exception.Message)"
}

if (-not (Test-Path $AusgabeOrdner)) { New-Item -ItemType Directory -Path $AusgabeOrdner | Out-Null }
$ausgabeDatei = Join-Path $AusgabeOrdner "Publish-Software_$($Hersteller)_$($Produkt)_$($Version).txt"
$zeilen | Out-File -FilePath $ausgabeDatei -Encoding UTF8

Write-Host ''
$zeilen | ForEach-Object { Write-Host $_ }
Write-Host ''
if ($zwischenablage) {
    Write-Host 'URL MIT SAS ist in der Zwischenablage -> in SuperOps "Installer URL" einfuegen.' -ForegroundColor Green
}
Write-Host "Ausgabe: $ausgabeDatei" -ForegroundColor Green
