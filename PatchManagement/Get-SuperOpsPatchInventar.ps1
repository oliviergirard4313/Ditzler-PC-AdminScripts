#Requires -Version 5.1
<#
.SYNOPSIS
    Listet alle Assets aus SuperOps (IT-Edition) inkl. Patch-Kategorie.

.DESCRIPTION
    Nutzt die IT-Edition-API (https://euapi.superops.ai/it, nicht MSP).
    Zugangsdaten (ApiKey, CustomerSubDomain) werden ueber die bestehende
    Ditzler-Powershell-Lib aus credentials.xml geladen (Devolutions Hub
    als Quelle der Wahrheit) - kein eigener Auth-Code hier.

    Das Custom Field "Categorie_SW-Patch" liegt technisch im JSON-Feld
    "customFields" unter dem Schluessel "udf17radio" (empirisch bestaetigt
    05.08.2026 anhand echter Asset-Daten, z.B. SV-OS-BAK-03 =
    "SV_SW-Std_Auto-Update-1").

.PARAMETER OutputCsv
    Pfad fuer CSV-Export. Standard: .\SuperOps_PatchInventar_<Datum>.csv

.PARAMETER NurServer
    Wenn gesetzt: nur Assets mit platformFamily "Server" (schliesst
    Domaincontroller/Standalone-Workstations aus).

.EXAMPLE
    .\Get-SuperOpsPatchInventar.ps1 -NurServer
#>

param(
    [string]$OutputCsv = ".\SuperOps_PatchInventar_$(Get-Date -Format 'yyyyMMdd_HHmm').csv",
    [switch]$NurServer
)

try { Clear-Host } catch { }
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LibPath = "C:\ProgramData\Superops\Scripts\Ditzler-Powershell-Lib.psm1"

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $Farbe = switch ($Level) {
        'OK'   { 'Green'  }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red'    }
        default { 'White' }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Msg" -ForegroundColor $Farbe
}

Write-Host '=== SuperOps Patch-Inventar (IT-Edition) ===' -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $LibPath)) {
    Write-Log "Bibliothek nicht gefunden: $LibPath" -Level 'ERR'
    exit 1
}

Import-Module $LibPath -Force
$AllCreds = Get-Credentials "credentials.xml"
Initialize-SuperOpsCreds -AllCreds $AllCreds

# ---------------------------------------------------------
# Alle Assets laden (paginiert, je 100)
# ---------------------------------------------------------

$Query = @'
query getAssetList($input: ListInfoInput!) {
  getAssetList(input: $input) {
    assets {
      assetId
      name
      hostName
      platform
      platformFamily
      status
      patchStatus
      lastCommunicatedTime
      customFields
    }
    listInfo {
      totalCount
      page
      pageSize
    }
  }
}
'@

$Alle     = New-Object 'System.Collections.Generic.List[object]'
$Seite    = 1
$ProSeite = 100

do {
    $Vars = @{ input = @{ page = $Seite; pageSize = $ProSeite } }
    $Antwort = Invoke-SuperOpsGraphQL -Query $Query -Variables $Vars

    if ($Antwort.PSObject.Properties['errors'] -and $Antwort.errors) {
        $Fehler = ($Antwort.errors | ForEach-Object { $_.message }) -join '; '
        Write-Log "GraphQL-Fehler: $Fehler" -Level 'ERR'
        exit 1
    }

    $Assets = @($Antwort.data.getAssetList.assets)
    $Total  = $Antwort.data.getAssetList.listInfo.totalCount

    foreach ($Asset in $Assets) {
        $Alle.Add($Asset)
    }

    Write-Log "Seite $Seite geladen: $($Alle.Count) / $Total Assets"
    $Seite++

} while ($Assets.Count -gt 0 -and $Alle.Count -lt $Total)

Write-Log "$($Alle.Count) Assets total geladen." -Level 'OK'

# ---------------------------------------------------------
# Ausgabe-Objekte bauen
# ---------------------------------------------------------

$Ergebnis = New-Object 'System.Collections.Generic.List[PSCustomObject]'

foreach ($Asset in $Alle) {

    $PatchKategorie = ''
    if ($Asset.customFields -and $Asset.customFields.udf17radio) {
        $PatchKategorie = $Asset.customFields.udf17radio
    }

    $LetzterKontakt = ''
    if (-not [string]::IsNullOrEmpty($Asset.lastCommunicatedTime)) {
        try {
            $LetzterKontakt = [datetime]::Parse($Asset.lastCommunicatedTime).ToString('yyyy-MM-dd HH:mm')
        } catch {
            $LetzterKontakt = $Asset.lastCommunicatedTime
        }
    }

    $Ergebnis.Add([PSCustomObject]@{
        AssetId           = $Asset.assetId
        Name              = $Asset.name
        HostName          = $Asset.hostName
        Platform          = $Asset.platform
        PlatformFamily    = $Asset.platformFamily
        Status            = $Asset.status
        PatchStatus       = $Asset.patchStatus
        LastCommunicated  = $LetzterKontakt
        Categorie_SWPatch = $PatchKategorie
    })
}

if ($NurServer) {
    $Ergebnis = $Ergebnis | Where-Object { $_.PlatformFamily -eq 'Server' }
    Write-Log "Nach Server-Filter: $($Ergebnis.Count) Assets."
}

# ---------------------------------------------------------
# Konsolenausgabe
# ---------------------------------------------------------

Write-Host ''
Write-Host '=== Assets nach Patch-Kategorie ===' -ForegroundColor Cyan
$Ergebnis | Sort-Object Categorie_SWPatch, Name |
    Format-Table Name, PlatformFamily, Status, PatchStatus, Categorie_SWPatch -AutoSize

Write-Host ''
Write-Host '=== Verteilung Categorie_SW-Patch ===' -ForegroundColor Cyan
$Ergebnis | Group-Object Categorie_SWPatch | Sort-Object Count -Descending | ForEach-Object {
    $Label = if ([string]::IsNullOrEmpty($_.Name)) { '(keine Zuweisung)' } else { $_.Name }
    Write-Host "  $($Label.PadRight(30)) $($_.Count)"
}

# ---------------------------------------------------------
# CSV-Export
# ---------------------------------------------------------

$Ergebnis | Export-Csv -Path $OutputCsv -Delimiter ';' -Encoding UTF8 -NoTypeInformation
Write-Log "CSV gespeichert: $OutputCsv" -Level 'OK'
