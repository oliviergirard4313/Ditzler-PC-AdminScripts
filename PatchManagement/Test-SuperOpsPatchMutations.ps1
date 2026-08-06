#Requires -Version 5.1

# ==========================================================
# TEST-SUPEROPSPATCHMUTATIONS.PS1
# Zweck : Prueft per GraphQL-Introspection, welche Mutations die
#         SuperOps IT-API fuer Patch-Installation/-Deployment anbietet.
#         Nur Lesezugriff (Introspection), keine Aenderungen.
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
    mutationType {
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

$AllMutations = $Response.data.__schema.mutationType.fields
Write-Host "Alle Mutations total: $($AllMutations.Count)"
Write-Host ""
Write-Host "=== Alle Mutations (komplett) ===" -ForegroundColor Yellow
$AllMutations | Sort-Object name | ForEach-Object { Write-Host "$($_.name)  -  $($_.description)" }

Write-Host ""
Write-Host "=== Detail: runScriptOnAsset / assignDeviceCategory - Input-Typnamen ===" -ForegroundColor Yellow
$DetailQuery = @'
query {
  __type(name: "Mutation") {
    fields(includeDeprecated: true) {
      name
      args {
        name
        type {
          name
          kind
          ofType { name kind }
        }
      }
    }
  }
}
'@
$DetailBody = @{ query = $DetailQuery } | ConvertTo-Json -Depth 8
$DetailResponse = Invoke-RestMethod -Uri $Global:SOApiUrl -Method Post -Headers $Headers -Body $DetailBody -TimeoutSec 30

$TargetMutations = $DetailResponse.data.__type.fields | Where-Object { $_.name -in @('runScriptOnAsset', 'assignDeviceCategory') }
$InputTypeNames = @()
foreach ($m in $TargetMutations) {
    foreach ($a in $m.args) {
        $typeName = if ($a.type.name) { $a.type.name } else { $a.type.ofType.name }
        Write-Host "$($m.name) -> $($a.name) : $typeName"
        if ($typeName) { $InputTypeNames += $typeName }
    }
}

Write-Host ""
Write-Host "=== Felder der Input-Typen ===" -ForegroundColor Yellow
foreach ($typeName in ($InputTypeNames | Sort-Object -Unique)) {
    $FieldsQuery = @"
query {
  __type(name: "$typeName") {
    name
    inputFields {
      name
      description
      type {
        name
        kind
        ofType { name kind ofType { name kind } }
      }
    }
  }
}
"@
    $FieldsBody = @{ query = $FieldsQuery } | ConvertTo-Json -Depth 10
    $FieldsResponse = Invoke-RestMethod -Uri $Global:SOApiUrl -Method Post -Headers $Headers -Body $FieldsBody -TimeoutSec 30

    Write-Host "--- $typeName ---"
    foreach ($f in $FieldsResponse.data.__type.inputFields) {
        $ft = if ($f.type.name) { $f.type.name }
              elseif ($f.type.ofType.name) { $f.type.ofType.name }
              else { $f.type.ofType.ofType.name }
        Write-Host "  $($f.name) : $ft ($($f.type.kind))  -  $($f.description)"
    }
}
