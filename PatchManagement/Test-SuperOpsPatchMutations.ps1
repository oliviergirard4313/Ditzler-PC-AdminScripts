#Requires -Version 5.1

# ==========================================================
# TEST-SUPEROPSPATCHMUTATIONS.PS1
# Zweck : Prueft per GraphQL-Introspection, welche Mutations die
#         SuperOps IT-API fuer Patch-Installation/-Deployment anbietet.
#         Nur Lesezugriff (Introspection), keine Aenderungen.
#
# Hinweis JSON-Parsing (25.08.2026): sowohl Invoke-RestMethod als auch
# ConvertFrom-Json werfen unter Windows PowerShell 5.1 auf diesen Antworten
# "No parameterless constructor defined for type of 'System.String'" -
# bekannter Bug bei Arrays mit gemischten null/Objekt-Eintraegen (z.B.
# "ofType" ist bei Skalartypen null, bei Listen/NonNull-Typen ein Objekt).
# Deshalb hier durchgehend JavaScriptSerializer.DeserializeObject() statt
# ConvertFrom-Json - liefert lose typisierte Hashtable/ArrayList-Struktur
# statt PSCustomObject (kein Reflection-basiertes Object-Erzeugen, daher
# nie dieser Fehler), Zugriff per ['key'] statt .key.
# ==========================================================

try { Clear-Host } catch { }
$ErrorActionPreference = 'Stop'

$LibPath = "C:\ProgramData\Superops\Scripts\Ditzler-Powershell-Lib.psm1"
Import-Module $LibPath -Force
Initialize-WorkDir

$AllCreds = Get-Credentials -FileName "credentials.xml"
Initialize-SuperOpsCreds -AllCreds $AllCreds

Add-Type -AssemblyName System.Web.Extensions
$Serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$Serializer.MaxJsonLength = [int]::MaxValue
$Serializer.RecursionLimit = 1000

$Headers = @{
    'Content-Type'      = 'application/json'
    'Authorization'     = "Bearer $Global:SOApiKey"
    'CustomerSubDomain' = $Global:SOCustomer
}

function Invoke-SoGraphQL {
    param([string]$Query)
    $Body = $Serializer.Serialize(@{ query = $Query })
    $Raw = Invoke-WebRequest -Uri $Global:SOApiUrl -Method Post -Headers $Headers -Body $Body -TimeoutSec 30 -UseBasicParsing
    # "__type" ist ein RESERVIERTER/magischer Property-Name in
    # JavaScriptSerializer (ASP.NET-AJAX-Konvention fuer polymorphe
    # Deserialisierung) - GraphQL-Introspection nutzt aber genau dieses
    # Feld (__type(name: "X")), was dann "No parameterless constructor
    # defined for type of 'System.String'" wirft, egal ob per
    # ConvertFrom-Json, Invoke-RestMethod oder JavaScriptSerializer direkt
    # geparst (beobachtet 25.08.2026 - alle drei nutzen denselben
    # Deserializer unter Windows PowerShell 5.1). Workaround: den
    # problematischen Schluessel im Rohtext umbenennen, bevor geparst wird.
    $SafeContent = $Raw.Content -replace '"__type"', '"__gqltype"'
    return $Serializer.DeserializeObject($SafeContent)
}

# ---------------------------------------------------------
# 1. Alle Mutationsnamen + Beschreibung
# ---------------------------------------------------------

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

$Response = Invoke-SoGraphQL -Query $Query

if ($Response['errors']) {
    Write-Host "GraphQL Fehler:" -ForegroundColor Red
    $Response['errors'] | ForEach-Object { Write-Host " - $($_['message'])" }
    exit 1
}

$AllMutations = $Response['data']['__schema']['mutationType']['fields']
Write-Host "Alle Mutations total: $($AllMutations.Count)"
Write-Host ""
Write-Host "=== Alle Mutations (komplett) ===" -ForegroundColor Yellow
$AllMutations | Sort-Object { $_['name'] } | ForEach-Object { Write-Host "$($_['name'])  -  $($_['description'])" }

# ---------------------------------------------------------
# 2. Argumentnamen der 4 Ziel-Mutations (flache Query)
# ---------------------------------------------------------

Write-Host ""
Write-Host "=== Detail: Argumentnamen der Ziel-Mutations ===" -ForegroundColor Yellow
$FlatQuery = @'
query {
  __type(name: "Mutation") {
    fields(includeDeprecated: true) {
      name
      args { name }
    }
  }
}
'@
$FlatResponse = Invoke-SoGraphQL -Query $FlatQuery

$TargetNames = @('runScriptOnAsset', 'assignDeviceCategory', 'sendApproval', 'updateApproval')
$TargetMutations = $FlatResponse['data']['__gqltype']['fields'] | Where-Object { $TargetNames -contains $_['name'] }
foreach ($m in $TargetMutations) {
    $argNames = ($m['args'] | ForEach-Object { $_['name'] }) -join ', '
    Write-Host "$($m['name']) -> Argumente: $argNames"
}

# ---------------------------------------------------------
# 2b. Echten Input-Typnamen von runScriptOnAsset ermitteln (Namenskonvention
#     <Mutation>Input war falsch - jetzt gezielt mit einer Ebene type/ofType
#     nachfragen, nur fuer diese eine Mutation gebraucht)
# ---------------------------------------------------------

$TypedQuery = @'
query {
  __type(name: "Mutation") {
    fields(includeDeprecated: true) {
      name
      args {
        name
        type { name kind ofType { name kind } }
      }
    }
  }
}
'@
$TypedResponse = Invoke-SoGraphQL -Query $TypedQuery
$RunScriptField = $TypedResponse['data']['__gqltype']['fields'] | Where-Object { $_['name'] -eq 'runScriptOnAsset' }
Write-Host ""
Write-Host "=== Echter Input-Typname von runScriptOnAsset ===" -ForegroundColor Yellow
$RunScriptInputTypeName = $null
foreach ($a in $RunScriptField['args']) {
    $t = $a['type']
    $tn = if ($t['name']) { $t['name'] } elseif ($t['ofType']) { $t['ofType']['name'] } else { $null }
    Write-Host "  $($a['name']) : $tn"
    if ($a['name'] -eq 'input' -and $tn) { $RunScriptInputTypeName = $tn }
}

# ---------------------------------------------------------
# 3. Felder der Input-Typen
# ---------------------------------------------------------

$InputTypeNames = @('AssignDeviceCategoryInput')
if ($RunScriptInputTypeName) { $InputTypeNames += $RunScriptInputTypeName }

Write-Host ""
Write-Host "=== Felder der Input-Typen ===" -ForegroundColor Yellow
foreach ($typeName in $InputTypeNames) {
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
    $FieldsResponse = Invoke-SoGraphQL -Query $FieldsQuery

    Write-Host "--- $typeName ---"
    if (-not $FieldsResponse['data']['__gqltype']) {
        Write-Host "  (Typ existiert nicht - Namenskonvention geraten, hier falsch)" -ForegroundColor DarkGray
        continue
    }
    foreach ($f in $FieldsResponse['data']['__gqltype']['inputFields']) {
        $t = $f['type']
        $ft = if ($t['name']) { $t['name'] }
              elseif ($t['ofType'] -and $t['ofType']['name']) { $t['ofType']['name'] }
              elseif ($t['ofType'] -and $t['ofType']['ofType']) { $t['ofType']['ofType']['name'] }
              else { '?' }
        Write-Host "  $($f['name']) : $ft ($($t['kind']))  -  $($f['description'])"
    }
}
