#Requires -Version 5.1

# ==========================================================
# TEST-SUPEROPSSCHEMAINTROSPECT.PS1
# Zweck : Prueft per GraphQL-Introspection, ob die SuperOps IT-API
#         Queries fuer Category Rules / Policy Sets / Associations
#         (Advanced Policy) anbietet - zur Beantwortung der Frage
#         "Konfiguration per API auslesbar?". Nur Lesezugriff.
# ==========================================================

try { Clear-Host } catch { }
$ErrorActionPreference = 'Stop'

$LibPath = "C:\ProgramData\Superops\Scripts\Ditzler-Powershell-Lib.psm1"
Import-Module $LibPath -Force
Initialize-WorkDir

$AllCreds = Get-Credentials -FileName "credentials.xml"
Initialize-SuperOpsCreds -AllCreds $AllCreds

$Query = @'
query {
  __schema {
    queryType {
      fields {
        name
        description
      }
    }
  }
}
'@

$Headers = @{
    'Content-Type'      = 'application/json'
    'Authorization'     = "Bearer $Global:SOApiKey"
    'CustomerSubDomain' = $Global:SOCustomer
}
$Body = @{ query = $Query } | ConvertTo-Json -Depth 5

$Response = Invoke-RestMethod -Uri $Global:SOApiUrl -Method Post -Headers $Headers -Body $Body -TimeoutSec 30

if ($Response.errors) {
    Write-Host "GraphQL Fehler:" -ForegroundColor Red
    $Response.errors | ForEach-Object { Write-Host " - $($_.message)" }
    exit 1
}

$AllQueries = $Response.data.__schema.queryType.fields
Write-Host "Total query fields: $($AllQueries.Count)"
Write-Host ""
Write-Host "=== Alle Query-Felder ===" -ForegroundColor Yellow
$AllQueries | Sort-Object name | ForEach-Object { Write-Host "$($_.name)  -  $($_.description)" }

Write-Host ""
Write-Host "=== Gefiltert: categ / rule / polic / customfield / udf / association ===" -ForegroundColor Cyan
$AllQueries | Where-Object { $_.name -match '(?i)categ|rule|polic|customfield|udf|associat' } | Sort-Object name | ForEach-Object { Write-Host "$($_.name)  -  $($_.description)" }
