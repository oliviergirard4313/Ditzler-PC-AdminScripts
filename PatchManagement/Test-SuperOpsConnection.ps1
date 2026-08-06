#Requires -Version 5.1
<#
.SYNOPSIS
    Minimaler Verbindungstest gegen die SuperOps IT-API (nicht MSP).

.DESCRIPTION
    Testet ausschliesslich die Authentifizierung und den Endpunkt mit einer
    einfachen GraphQL-Abfrage (getDeviceCategories). Kein Asset-Abruf, keine
    Paginierung - nur Verbindung bestaetigen, bevor weiterer Code darauf
    aufbaut.

.PARAMETER ApiToken
    SuperOps API-Token (Format: api-eyJ..., JWT). Standard: Env-Variable
    SUPEROPS_API_KEY.

.PARAMETER ApiEndpoint
    SuperOps IT-Edition Endpunkt (EU). Nicht MSP.

.EXAMPLE
    $env:SUPEROPS_API_KEY = "api-eyJ..."
    .\Test-SuperOpsConnection.ps1
#>

param(
    [string]$ApiToken    = $env:SUPEROPS_API_KEY,
    [string]$ApiEndpoint = 'https://euapi.superops.ai/it'
)

try { Clear-Host } catch { }
Set-StrictMode -Version Latest
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

Write-Host '=== SuperOps IT-API Verbindungstest ===' -ForegroundColor Cyan
Write-Log "Endpunkt: $ApiEndpoint"

if ([string]::IsNullOrEmpty($ApiToken)) {
    Write-Log 'Kein Token gefunden. Parameter -ApiToken oder Env-Variable SUPEROPS_API_KEY setzen.' -Level 'ERR'
    exit 1
}

Write-Log "Token gefunden (Laenge: $($ApiToken.Length) Zeichen)."

$Query = @'
query {
  getDeviceCategories {
    deviceCategoryId
    name
  }
}
'@

$Body = @{ query = $Query } | ConvertTo-Json -Depth 5 -Compress

$Headers = @{
    'Content-Type'  = 'application/json'
    'Authorization' = "Bearer $ApiToken"
}

try {
    Write-Log 'Sende Testabfrage (getDeviceCategories)...'

    $Response = Invoke-RestMethod `
        -Uri     $ApiEndpoint `
        -Method  Post `
        -Headers $Headers `
        -Body    $Body `
        -TimeoutSec 30

    if ($Response.errors) {
        $Fehler = ($Response.errors | ForEach-Object { $_.message }) -join '; '
        Write-Log "GraphQL-Fehler: $Fehler" -Level 'ERR'
        exit 1
    }

    $Kategorien = $Response.data.getDeviceCategories

    if (-not $Kategorien) {
        Write-Log 'Antwort ohne Fehler, aber keine Kategorien erhalten. Rohantwort:' -Level 'WARN'
        $Response | ConvertTo-Json -Depth 10 | Write-Host
        exit 1
    }

    Write-Log "Verbindung erfolgreich. $($Kategorien.Count) DeviceCategories erhalten." -Level 'OK'
    $Kategorien | Format-Table deviceCategoryId, name -AutoSize

} catch {
    Write-Log "Verbindung fehlgeschlagen: $($_.Exception.Message)" -Level 'ERR'
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
        Write-Log "Details: $($_.ErrorDetails.Message)" -Level 'ERR'
    }
    if ($_.Exception.Response) {
        try {
            $Stream = $_.Exception.Response.GetResponseStream()
            $Stream.Position = 0
            $Reader = New-Object System.IO.StreamReader($Stream)
            $Rohtext = $Reader.ReadToEnd()
            Write-Log "Rohantwort: $Rohtext" -Level 'ERR'
        } catch {
            Write-Log "Rohantwort konnte nicht gelesen werden: $($_.Exception.Message)" -Level 'WARN'
        }
    }
    exit 1
}
