#Requires -Version 5.1
<#
.SYNOPSIS
    Setzt das Custom Field "Categorie_SW-Patch" (customFields.udf17radio)
    fuer einen oder mehrere SuperOps-Assets per API - Schreibzugriff, nicht
    nur Lesezugriff wie Get-SuperOpsPatchInventar.ps1/
    Get-AssetsByPatchCategory.ps1.

.DESCRIPTION
    Automatisiert das Anwenden des Kategorisierungsplans
    (Server-Kategorien-Aenderungen.csv, von Build-ServerPatchCategoryPlan.ps1
    erzeugt) im SuperOps-Portal, statt jeden Server einzeln von Hand im
    Portal umzustellen.

    Nutzt die Mutation "updateAsset" (oeffentliche IT-Edition-API,
    https://developer.superops.com/it) mit
    { assetId: "...", customFields: { udf17radio: "<Kategoriewert>" } } -
    per Web-Recherche 26.08.2026 gefunden, NICHT selbst per Introspection
    gegen die echte API verifiziert (das haette credentials.xml/SYSTEM
    gebraucht, in dieser Session nicht moeglich). Deshalb prueft dieses
    Skript bei jedem Lauf zuerst per Introspection, ob "UpdateAssetInput"
    wirklich ein "assetId"- und ein "customFields"-Feld hat, BEVOR es
    irgendeine echte Mutation abschickt - bricht mit klarer Meldung ab,
    falls das Schema anders aussieht als angenommen.

    WICHTIG - MUSS UNTER SYSTEM LAUFEN: dechiffriert credentials.xml (DPAPI),
    siehe Get-AssetsByPatchCategory.ps1 fuer Details/Grund. Aufruf ueber:
        psexec -i -s pwsh.exe -NoProfile -File Set-AssetPatchCategory.ps1 -WhatIf ...

    SICHERHEIT: [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')] -
    OHNE -WhatIf fragt PowerShell bei JEDEM einzelnen Asset einzeln nach
    Bestaetigung (Standardverhalten bei ConfirmImpact='High'), ausser
    -Confirm:$false wird explizit gesetzt. ERSTER TEST IMMER mit -WhatIf
    und/oder gegen TEST-Update-1/2/3 (Categorie_SW-Patch =
    SV_SW-Std_Manual-Update-TEST), NIE direkt gegen echte Produktivserver.

.PARAMETER AssetId
    Einzelnes Asset per SuperOps AssetId umstellen (siehe Server-Kategorien-*.csv).

.PARAMETER ServerName
    Alternativ zu -AssetId: Servername, wird per API nachgeschlagen (ein
    zusaetzlicher Roundtrip - bei vielen Servern -InputCsv bevorzugen).

.PARAMETER Category
    Neuer Wert fuer Categorie_SW-Patch (mit -AssetId oder -ServerName).

.PARAMETER InputCsv
    Bulk-Modus: CSV mit Spalten Name, AktuelleKategorie, NeueKategorie,
    AssetId (Format von Build-ServerPatchCategoryPlan.ps1's
    Server-Kategorien-Aenderungen.csv). Verarbeitet jede Zeile.

.EXAMPLE
    psexec -i -s pwsh.exe -NoProfile -File .\Set-AssetPatchCategory.ps1 -ServerName TEST-Update-1 -Category "SV_SW-Std_Manual-Update-TEST" -WhatIf

.EXAMPLE
    psexec -i -s pwsh.exe -NoProfile -File .\Set-AssetPatchCategory.ps1 -InputCsv .\Server-Kategorien-Aenderungen.csv -WhatIf
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High', DefaultParameterSetName = 'Single')]
param(
    [Parameter(ParameterSetName = 'Single')]
    [string]$AssetId,
    [Parameter(ParameterSetName = 'Single')]
    [string]$ServerName,
    [Parameter(ParameterSetName = 'Single')]
    [string]$Category,
    [Parameter(ParameterSetName = 'Bulk', Mandatory)]
    [string]$InputCsv
)

try { Clear-Host } catch { }
$ErrorActionPreference = 'Stop'

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

if ($PSCmdlet.ParameterSetName -eq 'Single' -and -not $Category) {
    Write-Log "Ohne -InputCsv braucht es -Category (mit -AssetId oder -ServerName)." -Level 'ERR'
    exit 1
}
if ($PSCmdlet.ParameterSetName -eq 'Single' -and -not $AssetId -and -not $ServerName) {
    Write-Log "Ohne -InputCsv braucht es -AssetId oder -ServerName." -Level 'ERR'
    exit 1
}

$LibPath = "C:\ProgramData\Superops\Scripts\Ditzler-Powershell-Lib.psm1"
if (-not (Test-Path -LiteralPath $LibPath)) {
    Write-Log "Bibliothek nicht gefunden: $LibPath" -Level 'ERR'
    exit 1
}
Import-Module $LibPath -Force
$AllCreds = Get-Credentials "credentials.xml"
Initialize-SuperOpsCreds -AllCreds $AllCreds

# ---------------------------------------------------------
# JSON-Parsing: __type ist ein reservierter Name in JavaScriptSerializer,
# siehe Kommentar in Test-SuperOpsPatchMutations.ps1 fuer Details.
# ---------------------------------------------------------
Add-Type -AssemblyName System.Web.Extensions
$Serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Serializer.MaxJsonLength = [int]::MaxValue
$Serializer.RecursionLimit = 1000

function Invoke-SoGraphQL {
    param([string]$Query, [hashtable]$Variables)
    $BodyObj = @{ query = $Query }
    if ($Variables) { $BodyObj.variables = $Variables }
    $Body = $Serializer.Serialize($BodyObj)
    $Raw = Invoke-WebRequest -Uri $Global:SOApiUrl -Method Post -Headers @{
        'Content-Type'      = 'application/json'
        'Authorization'     = "Bearer $Global:SOApiKey"
        'CustomerSubDomain' = $Global:SOCustomer
    } -Body $Body -TimeoutSec 30 -UseBasicParsing
    $SafeContent = $Raw.Content -replace '"__type"', '"__gqltype"'
    return $Serializer.DeserializeObject($SafeContent)
}

# ---------------------------------------------------------
# Schema-Vorpruefung: existiert UpdateAssetInput wirklich mit den
# erwarteten Feldern? Bricht ab statt eine vermutlich falsche Mutation
# gegen echte Daten abzuschicken.
# ---------------------------------------------------------

Write-Log "Pruefe Schema von UpdateAssetInput vor jeglichem Schreibzugriff..."
$SchemaQuery = @'
query {
  __type(name: "UpdateAssetInput") {
    name
    inputFields { name type { name kind ofType { name kind } } }
  }
}
'@
$SchemaResponse = Invoke-SoGraphQL -Query $SchemaQuery
$InputType = $SchemaResponse['data']['__gqltype']

if (-not $InputType) {
    Write-Log "Typ 'UpdateAssetInput' existiert nicht in diesem Schema - Mutation heisst vermutlich anders oder braucht einen anderen Input-Typnamen. Abbruch." -Level 'ERR'
    exit 1
}
$FieldNames = @($InputType['inputFields'] | ForEach-Object { $_['name'] })
Write-Log "UpdateAssetInput Felder gefunden: $($FieldNames -join ', ')"
if ('assetId' -notin $FieldNames -or 'customFields' -notin $FieldNames) {
    Write-Log "UpdateAssetInput hat nicht die erwarteten Felder 'assetId'/'customFields' - Skript muesste angepasst werden. Abbruch." -Level 'ERR'
    exit 1
}
Write-Log "Schema passt zu den Annahmen dieses Skripts." -Level 'OK'

# ---------------------------------------------------------
# Eigentliche Mutation
# ---------------------------------------------------------

$MutationQuery = @'
mutation updateAsset($input: UpdateAssetInput!) {
  updateAsset(input: $input) {
    assetId
    name
    customFields
  }
}
'@

function Get-AssetIdByName {
    param([string]$Name)
    $Query = @'
query getAssetList($input: ListInfoInput!) {
  getAssetList(input: $input) {
    assets { assetId name }
    listInfo { totalCount page pageSize }
  }
}
'@
    $Page = 1
    do {
        $Resp = Invoke-SoGraphQL -Query $Query -Variables @{ input = @{ page = $Page; pageSize = 100 } }
        $Assets = @($Resp['data']['getAssetList']['assets'])
        $Total = $Resp['data']['getAssetList']['listInfo']['totalCount']
        $Hit = $Assets | Where-Object { $_['name'] -eq $Name } | Select-Object -First 1
        if ($Hit) { return $Hit['assetId'] }
        $Page++
    } while ($Assets.Count -gt 0 -and ($Page - 1) * 100 -lt $Total)
    return $null
}

function Set-OneAssetCategory {
    param([string]$Id, [string]$NameForLog, [string]$NewCategory)

    if (-not $PSCmdlet.ShouldProcess("$NameForLog (AssetId=$Id)", "Categorie_SW-Patch auf '$NewCategory' setzen")) {
        return [PSCustomObject]@{ Name = $NameForLog; AssetId = $Id; NeueKategorie = $NewCategory; Ergebnis = 'Uebersprungen (WhatIf/Nein)' }
    }
    try {
        $Resp = Invoke-SoGraphQL -Query $MutationQuery -Variables @{
            input = @{ assetId = $Id; customFields = @{ udf17radio = $NewCategory } }
        }
        if ($Resp['errors']) {
            $Fehler = ($Resp['errors'] | ForEach-Object { $_['message'] }) -join '; '
            return [PSCustomObject]@{ Name = $NameForLog; AssetId = $Id; NeueKategorie = $NewCategory; Ergebnis = "FEHLER: $Fehler" }
        }
        $Applied = $Resp['data']['updateAsset']['customFields']['udf17radio']
        return [PSCustomObject]@{ Name = $NameForLog; AssetId = $Id; NeueKategorie = $NewCategory; Ergebnis = "OK (bestaetigt: $Applied)" }
    }
    catch {
        return [PSCustomObject]@{ Name = $NameForLog; AssetId = $Id; NeueKategorie = $NewCategory; Ergebnis = "FEHLER: $($_.Exception.Message)" }
    }
}

$Results = [System.Collections.Generic.List[object]]::new()

if ($PSCmdlet.ParameterSetName -eq 'Bulk') {
    if (-not (Test-Path -LiteralPath $InputCsv)) {
        Write-Log "CSV nicht gefunden: $InputCsv" -Level 'ERR'
        exit 1
    }
    $Rows = Import-Csv -LiteralPath $InputCsv
    Write-Log "$($Rows.Count) Zeile(n) aus $InputCsv geladen."
    foreach ($Row in $Rows) {
        $Id = $Row.AssetId
        if (-not $Id) {
            Write-Log "Zeile ohne AssetId uebersprungen: $($Row.Name)" -Level 'WARN'
            continue
        }
        $Results.Add((Set-OneAssetCategory -Id $Id -NameForLog $Row.Name -NewCategory $Row.NeueKategorie))
    }
}
else {
    $Id = $AssetId
    if (-not $Id) {
        Write-Log "Suche AssetId fuer Server '$ServerName'..."
        $Id = Get-AssetIdByName -Name $ServerName
        if (-not $Id) {
            Write-Log "Kein Asset mit Namen '$ServerName' gefunden." -Level 'ERR'
            exit 1
        }
    }
    $LogName = if ($ServerName) { $ServerName } else { $Id }
    $Results.Add((Set-OneAssetCategory -Id $Id -NameForLog $LogName -NewCategory $Category))
}

Write-Host ""
Write-Host "=== Ergebnis ===" -ForegroundColor Cyan
$Results | Format-Table -AutoSize -Wrap

$FehlerCount = @($Results | Where-Object { $_.Ergebnis -like 'FEHLER*' }).Count
if ($FehlerCount -gt 0) {
    Write-Log "$FehlerCount von $($Results.Count) fehlgeschlagen." -Level 'ERR'
    exit 1
}
Write-Log "Fertig." -Level 'OK'
