#Requires -Version 5.1
<#
.SYNOPSIS
    Listet live (SuperOps-API) alle Server, die aktuell einem bestimmten
    Wert des Custom Field "Categorie_SW-Patch" zugeordnet sind (z.B. einer
    der 4 manuellen Patch-Gruppen).

.DESCRIPTION
    Erster Schritt des manuellen On-Demand-Ablaufs fuer die 4 manuellen
    Patch-Gruppen (siehe SuperOps-Patch-Mechanik.md §6c): statt die
    Serverliste aus einem statischen CSV (Server-Kategorien-Uebersicht.csv,
    das nach einer Kategorie-Aenderung im Portal veralten kann) abzuleiten,
    fragt dieses Skript die SuperOps-API direkt zum Ausfuehrungszeitpunkt ab
    - immer aktuell.

    Zweiter Schritt: die erhaltene Liste an
    Invoke-ManualPatchRun.ps1 -ServerList <...> uebergeben, um den Patch-Lauf
    zu starten.

    WICHTIG - MUSS UNTER SYSTEM LAUFEN: dieses Skript entschluesselt
    credentials.xml (DPAPI), was unter einem normalen Konto mit "Key not
    valid for use in specified state" scheitert (empirisch bestaetigt
    26.08.2026 mit dem Admin-Konto adm_gio) - selbst auf der Maschine, die
    die Datei erzeugt hat. Aufruf ueber:
        psexec -i -s pwsh.exe -NoProfile -File Get-AssetsByPatchCategory.ps1 -Category "..."
    Invoke-ManualPatchRun.ps1 NIEMALS auf diese Weise (psexec -i -s) starten
    - dieses braucht den normalen Benutzerkontext fuer WinRM zu den
    Zielservern (Kerberos-Double-Hop bricht unter SYSTEM, siehe dessen
    eigener Kommentarkopf). Die beiden Skripte sind bewusst getrennt: der
    Teil, der credentials.xml anfasst (dieses hier), und der Teil, der mit
    den Zielservern spricht (Invoke-ManualPatchRun.ps1), muessen nie im
    selben Sicherheitskontext laufen.

.PARAMETER Category
    Exakter Wert des Custom Field "Categorie_SW-Patch", z.B.
    "SV_SW-Std_Manual-Update-Group-1" .. "-4".

.PARAMETER Json
    Unterdrueckt die lesbare Konsolenausgabe und gibt nur ein JSON-Array der
    gefundenen Servernamen auf STDOUT aus - fuer maschinelle Auswertung
    (z.B. durch die GUI, PatchManagement-GUI.ps1).

.EXAMPLE
    psexec -i -s pwsh.exe -NoProfile -File .\Get-AssetsByPatchCategory.ps1 -Category "SV_SW-Std_Manual-Update-Group-2"
#>

param(
    [Parameter(Mandatory)]
    [string]$Category,
    [switch]$Json
)

try { Clear-Host } catch { }
$ErrorActionPreference = 'Stop'

$KnownCategories = @(
    'SV_SW-Std_Manual-Update-Group-1',
    'SV_SW-Std_Manual-Update-Group-2',
    'SV_SW-Std_Manual-Update-Group-3',
    'SV_SW-Std_Manual-Update-Group-4'
)

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    if ($Json) { return }
    $Farbe = switch ($Level) {
        'OK'   { 'Green'  }
        'WARN' { 'Yellow' }
        'ERR'  { 'Red'    }
        default { 'White' }
    }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Msg" -ForegroundColor $Farbe
}

if (-not $Json) {
    Write-Host "=== Server fuer Kategorie '$Category' (Live-Abfrage SuperOps) ===" -ForegroundColor Cyan
}

if ($Category -notin $KnownCategories) {
    Write-Log "Ungewoehnlicher Wert fuer eine manuelle Gruppe (erwartet: $($KnownCategories -join ', ')) - fahre trotzdem fort, bei 0 Treffern Schreibweise pruefen." -Level 'WARN'
}

$LibPath = "C:\ProgramData\Superops\Scripts\Ditzler-Powershell-Lib.psm1"
if (-not (Test-Path -LiteralPath $LibPath)) {
    Write-Log "Bibliothek nicht gefunden: $LibPath" -Level 'ERR'
    if ($Json) { '[]' | Write-Output }
    exit 1
}
Import-Module $LibPath -Force
$AllCreds = Get-Credentials "credentials.xml"
Initialize-SuperOpsCreds -AllCreds $AllCreds

$Query = @'
query getAssetList($input: ListInfoInput!) {
  getAssetList(input: $input) {
    assets {
      name
      platformFamily
      status
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

$Treffer  = [System.Collections.Generic.List[string]]::new()
$Geladen  = 0
$Seite    = 1
$ProSeite = 100

do {
    $Vars = @{ input = @{ page = $Seite; pageSize = $ProSeite } }
    $Antwort = Invoke-SuperOpsGraphQL -Query $Query -Variables $Vars

    if ($Antwort.PSObject.Properties['errors'] -and $Antwort.errors) {
        $Fehler = ($Antwort.errors | ForEach-Object { $_.message }) -join '; '
        Write-Log "GraphQL-Fehler: $Fehler" -Level 'ERR'
        if ($Json) { '[]' | Write-Output }
        exit 1
    }

    $Assets = @($Antwort.data.getAssetList.assets)
    $Total  = $Antwort.data.getAssetList.listInfo.totalCount
    $Geladen += $Assets.Count

    foreach ($Asset in $Assets) {
        if ($Asset.platformFamily -notlike 'Server*') { continue }
        if ($Asset.customFields -and $Asset.customFields.udf17radio -eq $Category) {
            $Treffer.Add($Asset.name)
        }
    }

    Write-Log "Seite $Seite geladen: $Geladen / $Total Assets ($($Treffer.Count) Treffer bisher)"
    $Seite++

} while ($Assets.Count -gt 0 -and $Geladen -lt $Total)

$Treffer = @($Treffer | Sort-Object -Unique)

if ($Json) {
    ConvertTo-Json -InputObject $Treffer -Compress | Write-Output
    exit 0
}

Write-Host ''
if ($Treffer.Count -eq 0) {
    Write-Log "Kein Server fuer Kategorie '$Category' gefunden." -Level 'WARN'
    exit 0
}

Write-Log "$($Treffer.Count) Server gefunden:" -Level 'OK'
$Treffer | ForEach-Object { Write-Host "  - $_" }

Write-Host ''
Write-Host '=== Zum Einfuegen in Invoke-ManualPatchRun.ps1 ===' -ForegroundColor Yellow
Write-Host "-ServerList $($Treffer -join ',')"
