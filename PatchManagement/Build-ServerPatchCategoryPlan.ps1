#Requires -Version 5.1

# ==========================================================
# BUILD-SERVERPATCHCATEGORYPLAN.PS1
# Zweck    : Konsolidiert AD, SuperOps und den alten Excel-Plan zu einer
#            einzigen Liste Server -> Ziel-Patch-Kategorie.
#            Alles was SuperOps aktuell in "SV_SW-Std_Update-ScanOnly"
#            sammelt, wird hier auf die echten Manual-Update-Group-1..4
#            Kategorien aufgeteilt.
#
#            Kategorienamen entsprechen exakt dem SuperOps Custom Field
#            "Categorie_SW-Patch" (Radio-Choices, per Screenshot GIO
#            06.08.2026 bestaetigt) - kein "PD_"-Praefix, Manual-Gruppen
#            heissen "...-Manual-Update-Group-N".
#
# Autor    : Claude Code
# Version  : 2.0
# Datum    : 2026-08-06
#
# Regeln (in Prioritaet):
#   0. ExcludeNames  -> Server existiert nicht mehr, aus der Liste raus
#   0. ManualOverrides -> von GIO explizit entschiedene Zuordnung
#   1. Name SV-OS-DC-* (ditzlernet.local DC) -> NO-Update (absolut)
#      Hinweis: SV-PSG-DC-* (Grundstoff-Domaene) ist davon NICHT
#      betroffen - dort gibt es kein W2012R2-Kompatibilitaetsproblem,
#      von GIO am 06.08.2026 bestaetigt ("c'est OK").
#   2. OS enthaelt "2012"                 -> NO-Update (absolut)
#   3. Name SV-PSG-* oder Excel-Gruppe 4  -> Manual-Update-Group-4
#   4. Bereits live in SuperOps auf Auto-Update-1/2 -> unveraendert
#   5. Excel-Gruppe "AutoInstall" ohne aktive Auto-Kategorie -> REVIEW
#   6. Excel-Gruppe 1/2/3 (eindeutig)     -> Manual-Update-Group-1/2/3
#   7. Widerspruechliche Excel-Gruppen oder kein Signal -> REVIEW
# ==========================================================

param(
    [string]$SuperOpsCsv = "C:\Admin\Ditzler\PatchManagement\SuperOps_PatchInventar_20260806_1017.csv",
    [string]$ConsolidatedExcelCsv = "C:\Admin\Ditzler\PatchManagement\Consolidated_SuperOps_Excel.csv",
    [string]$OutputCsv = "C:\Admin\Ditzler\PatchManagement\Server-Patch-Category-Plan.csv",
    [string]$OverviewCsv = "C:\Admin\Ditzler\PatchManagement\Server-Kategorien-Uebersicht.csv",
    [string]$ChangesCsv = "C:\Admin\Ditzler\PatchManagement\Server-Kategorien-Aenderungen.csv"
)

try { Clear-Host } catch { }
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

# ---------------------------------------------------------
# Von GIO am 06.08.2026 bestaetigte Entscheidungen
# ---------------------------------------------------------

# Server, die laut GIO nicht mehr existieren (Cluster umgebaut) - in
# SuperOps auf Status "retired" gesetzt (06.08.2026, sichtbar aber nicht
# verwaltbar) - komplett aus der Liste entfernen statt zu kategorisieren.
$ExcludeNames = @(
    'SV-OS-SQLND-01',
    'SV-OS-SQLND-02',
    # FSND-01/02 nicht mehr in AD gefunden, ersetzt durch FSND-11/12 -
    # gleiche Situation wie SQLND-01/02, daher gleich behandelt.
    'SV-OS-FSND-01',
    'SV-OS-FSND-02',
    'SV-PB-HV-01'
)

# Explizite Zuordnung, die staerker wiegt als jede automatische Regel.
$ManualOverrides = @{
    'SV-OS-SQLND-11' = @{ Cat = 'SV_SW-Std_NO-Update'; Reason = 'SQL-Cluster-Node, Patch ueber WSUS+CAU orchestriert, nicht ueber SuperOps' }
    'SV-OS-SQLND-12' = @{ Cat = 'SV_SW-Std_NO-Update'; Reason = 'SQL-Cluster-Node, Patch ueber WSUS+CAU orchestriert, nicht ueber SuperOps' }
    'SV-OS-FSND-11'  = @{ Cat = 'SV_SW-Std_NO-Update'; Reason = 'FS-Cluster-Node, Patch ueber WSUS+CAU orchestriert, nicht ueber SuperOps' }
    'SV-OS-FSND-12'  = @{ Cat = 'SV_SW-Std_NO-Update'; Reason = 'FS-Cluster-Node, Patch ueber WSUS+CAU orchestriert, nicht ueber SuperOps' }
    'SV-OS-DEV-01'   = @{ Cat = 'SV_SW-Std_Auto-Update-2'; Reason = 'Von GIO entschieden 06.08.2026' }
    'SV-OS-TIME-01'  = @{ Cat = 'SV_SW-Std_Auto-Update-2'; Reason = 'Von GIO entschieden 06.08.2026' }
    'SV-OS-CR-01'    = @{ Cat = 'SV_SW-Std_Auto-Update-2'; Reason = 'Von GIO entschieden 06.08.2026' }
    # Entscheidung vom 06.08.2026 (Auto-Update-2) war ein Fehler - von GIO
    # am 26.08.2026 korrigiert: bleibt in Manual-Update-Group-2 (bereits so
    # in SuperOps gesetzt, das war die richtige Kategorie).
    'SV-OS-TIME-11'  = @{ Cat = 'SV_SW-Std_Manual-Update-Group-2'; Reason = 'Von GIO bestaetigt 26.08.2026 (Korrektur der fruehreren Entscheidung vom 06.08.2026)' }
    'SV-OS-AV-01'    = @{ Cat = 'SV_SW-Std_Auto-Update-2'; Reason = 'Von GIO entschieden 06.08.2026' }
    # OIP-01 war zwischen Gruppe 2 und 3 mehrdeutig - GIO hat die Wahl
    # offen gelassen ("decide"). Vorlaeufig Gruppe 2 gewaehlt (erster
    # historischer Treffer) - bitte bestaetigen oder korrigieren.
    'SV-OS-OIP-01'   = @{ Cat = 'SV_SW-Std_Manual-Update-Group-2'; Reason = 'Vorlaeufige Wahl (Gruppe 2 vs 3 war offen) - bitte bestaetigen' }
    # Comarch-Gruppe - von GIO auf Manual-Group-1 korrigiert (nicht
    # Auto-Update-1). Hinweis: nur SV-OS-CEE-TA-01 liegt tatsaechlich in
    # der AD-OU "20_Comarch" - NL-01/PRT-01/PRT-11 sind funktional/
    # geschaeftlich zugeordnet, nicht OU-technisch.
    'SV-OS-NL-01'    = @{ Cat = 'SV_SW-Std_Manual-Update-Group-1'; Reason = 'Comarch-Gruppe (GIO 06.08.2026)' }
    'SV-OS-PRT-01'   = @{ Cat = 'SV_SW-Std_Manual-Update-Group-1'; Reason = 'Comarch-Gruppe (GIO 06.08.2026)' }
    'SV-OS-PRT-11'   = @{ Cat = 'SV_SW-Std_Manual-Update-Group-1'; Reason = 'Comarch-Gruppe (GIO 06.08.2026)' }
    'SV-OS-PWR-01'   = @{ Cat = 'SV_SW-Std_Manual-Update-Group-2'; Reason = 'Von GIO korrigiert 06.08.2026 (nicht Gruppe 1)' }
    'SV-OS-WSUS-01'  = @{ Cat = 'SV_SW-Std_Auto-Update-2'; Reason = 'Von GIO entschieden 06.08.2026' }
    'SV-OS-SQLND-05' = @{ Cat = 'SV_SW-Std_NO-Update'; Reason = 'Von GIO entschieden 06.08.2026' }
    'SV-OS-PRB-01'   = @{ Cat = 'SV_SW-AV-Rly_Auto-Update-2'; Reason = 'Bitdefender-Relay, ausserhalb Std-Schema - unveraendert belassen (GIO 06.08.2026)' }
    'SV-PB-PRB-11'   = @{ Cat = 'SV_SW-AV-Rly_Auto-Update-2'; Reason = 'Bitdefender-Relay, ausserhalb Std-Schema - unveraendert belassen (GIO 06.08.2026)' }
}

# ---------------------------------------------------------
# 1. AD Server (Ground Truth: existiert der Server wirklich)
# ---------------------------------------------------------

Import-Module ActiveDirectory -ErrorAction Stop

$AdExcludedPatterns = @(
    "AZUREADSSOACC",
    "AZUREADKERBEROS*",
    "CAU*",
    "*DBCL*",
    "*SQLCL*",
    "*FSCL*"
)

Write-Info "Lese AD Server (Enabled, OperatingSystem wie '*Server*')"
$AdComputers = Get-ADComputer -Filter { Enabled -eq $true -and OperatingSystem -like "*Server*" } -Properties Name, OperatingSystem |
    Where-Object {
        $n = $_.Name.ToUpperInvariant()
        -not ($AdExcludedPatterns | Where-Object { $n -like $_.ToUpperInvariant() })
    }

$AdByName = @{}
foreach ($c in $AdComputers) {
    $AdByName[$c.Name.ToUpperInvariant()] = $c.OperatingSystem
}
Write-Info "AD Server (bereinigt): $($AdByName.Count)"

# ---------------------------------------------------------
# 2. SuperOps Assets (Server + Server (Domain Controller))
# ---------------------------------------------------------

Write-Info "Lese SuperOps CSV: $SuperOpsCsv"
$SoLines = Get-Content -LiteralPath $SuperOpsCsv -Encoding UTF8 | Select-Object -Skip 1
$SoByName = @{}
foreach ($line in $SoLines) {
    if (-not $line.Trim()) { continue }
    $f = $line -split ';' | ForEach-Object { $_.Trim('"') }
    if ($f.Count -lt 9) { continue }
    $family = $f[4]
    if ($family -ne 'Server' -and $family -ne 'Server (Domain Controller)') { continue }
    $name = $f[1].Trim().ToUpperInvariant()
    $SoByName[$name] = [PSCustomObject]@{
        AssetId       = $f[0]
        Name          = $f[1]
        Platform      = $f[3]
        PlatformFamily= $family
        Status        = $f[5]
        PatchStatus   = $f[6]
        Category      = $f[8]
    }
}
Write-Info "SuperOps Server-Assets: $($SoByName.Count)"

# ---------------------------------------------------------
# 3. Alter Excel-Plan (historische Gruppierung, aus Consolidated CSV)
# ---------------------------------------------------------

Write-Info "Lese Excel-Historie: $ConsolidatedExcelCsv"
$ExcelRows = Import-Csv -LiteralPath $ConsolidatedExcelCsv
$ExcelGroupsByName = @{}
$RelevantGroups = @('Gruppe 1', 'Gruppe 2', 'Gruppe 3', 'Gruppe 4', 'AutoInstall', 'Autoinstall')
foreach ($row in $ExcelRows) {
    if (-not $row.Name) { continue }
    $g = $row.UpdateGroup.Trim()
    if ($g -notin $RelevantGroups) { continue }
    $gNorm = if ($g -eq 'Autoinstall') { 'AutoInstall' } else { $g }
    $key = $row.Name.Trim().ToUpperInvariant()
    if (-not $ExcelGroupsByName.ContainsKey($key)) {
        $ExcelGroupsByName[$key] = [System.Collections.Generic.List[string]]::new()
    }
    if (-not $ExcelGroupsByName[$key].Contains($gNorm)) {
        $ExcelGroupsByName[$key].Add($gNorm)
    }
}

# ---------------------------------------------------------
# 4. Kategorisierung
# ---------------------------------------------------------

$AllNames = @{}
foreach ($k in $AdByName.Keys) { $AllNames[$k] = $true }
foreach ($k in $SoByName.Keys) { $AllNames[$k] = $true }
foreach ($n in $ExcludeNames) { $AllNames.Remove($n.ToUpperInvariant()) }

$Plan = [System.Collections.Generic.List[object]]::new()

foreach ($name in ($AllNames.Keys | Sort-Object)) {
    $inAd = $AdByName.ContainsKey($name)
    $so   = $SoByName[$name]
    $inSo = $null -ne $so
    $os   = if ($inAd) { $AdByName[$name] } elseif ($inSo) { $so.Platform } else { '' }
    $currentCat = if ($inSo) { $so.Category } else { '' }

    # @() erzwingt Array-Kontext - sonst wird eine Liste mit genau einem
    # Element von PowerShell beim Zuweisen zu einem einzelnen String
    # "entrollt" und $excelGroups[0] liefert dann nur das erste Zeichen.
    $excelGroups = @(if ($ExcelGroupsByName.ContainsKey($name)) { $ExcelGroupsByName[$name] } else { @() })
    $excelGroupStr = $excelGroups -join '|'

    $recommended = ''
    $reason = ''

    if ($ManualOverrides.ContainsKey($name)) {
        $recommended = $ManualOverrides[$name].Cat
        $reason = $ManualOverrides[$name].Reason
    }
    elseif ($name -like 'SV-OS-DC-*') {
        $recommended = 'SV_SW-Std_NO-Update'
        $reason = 'Domain Controller ditzlernet.local - absolute Regel, kein Patch'
    }
    elseif ($os -like '*2012*') {
        $recommended = 'SV_SW-Std_NO-Update'
        $reason = 'Windows Server 2012 R2 - absolute Regel, kein Patch'
    }
    elseif ($name -notlike 'SV-PSG-DC-*' -and (($name -like 'SV-PSG-*') -or ($excelGroups -contains 'Gruppe 4'))) {
        $recommended = 'SV_SW-Std_Manual-Update-Group-4'
        $reason = 'Grundstoff / isoliertes Netz (Gruppe 4)'
    }
    elseif ($inSo -and $so.Category -in @('SV_SW-Std_Auto-Update-1', 'SV_SW-Std_Auto-Update-2')) {
        $recommended = $so.Category
        $reason = 'Bereits aktiv in SuperOps konfiguriert - unveraendert uebernommen'
    }
    elseif ($excelGroups.Count -eq 1 -and $excelGroups[0] -eq 'AutoInstall') {
        $recommended = 'REVIEW'
        $reason = 'Excel-Gruppe AutoInstall, aber keine aktive Auto-Kategorie in SuperOps - Wave 1 oder 2 manuell entscheiden'
    }
    elseif ($excelGroups.Count -eq 1 -and $excelGroups[0] -in @('Gruppe 1', 'Gruppe 2', 'Gruppe 3')) {
        $n = $excelGroups[0].Substring($excelGroups[0].Length - 1)
        $recommended = "SV_SW-Std_Manual-Update-Group-$n"
        $reason = "Historische Excel-Gruppe $n"
    }
    elseif ($excelGroups.Count -gt 1) {
        $recommended = 'REVIEW'
        $reason = "Widerspruechliche Excel-Gruppen: $excelGroupStr - manuell entscheiden"
    }
    else {
        $recommended = 'REVIEW'
        $reason = 'Kein Excel-Verlauf und keine aktive Auto-Kategorie - neuer/unklassifizierter Server'
    }

    if (-not $inSo) {
        $reason = "$reason [NICHT in SuperOps onboarded]"
    }
    if (-not $inAd) {
        $reason = "$reason [NICHT (mehr) in AD gefunden]"
    }

    $Plan.Add([PSCustomObject]@{
        Name               = $name
        InAD               = $inAd
        InSuperOps         = $inSo
        OS                 = $os
        CurrentCategory    = $currentCat
        ExcelGroup         = $excelGroupStr
        RecommendedCategory= $recommended
        Reason             = $reason
        AssetId            = if ($inSo) { $so.AssetId } else { '' }
    })
}

$Plan | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8
Write-Info "Plan geschrieben: $OutputCsv ($($Plan.Count) Server)"

# ---------------------------------------------------------
# 5. Zwei Zusatz-Exporte
#    a) Uebersicht (alle Server, lesbar) - fuer Kollegen
#    b) Aenderungen (nur Server, die in SuperOps existieren UND deren
#       Kategorie sich aendert) - fuer die manuelle Anpassung
# ---------------------------------------------------------

$Overview = $Plan | ForEach-Object {
    $bemerkung = if (-not $_.InSuperOps) { 'Nicht in SuperOps onboardet' }
                 elseif (-not $_.InAD) { 'Nicht mehr in AD gefunden' }
                 else { '' }
    [PSCustomObject]@{
        Name      = $_.Name
        OS        = $_.OS
        Kategorie = $_.RecommendedCategory
        Bemerkung = $bemerkung
    }
}
$Overview | Sort-Object Kategorie, Name | Export-Csv -LiteralPath $OverviewCsv -NoTypeInformation -Encoding UTF8
Write-Info "Uebersicht geschrieben: $OverviewCsv ($($Overview.Count) Server)"

$Changes = $Plan | Where-Object {
    $_.InSuperOps -and $_.RecommendedCategory -ne 'REVIEW' -and $_.CurrentCategory -ne $_.RecommendedCategory
} | ForEach-Object {
    [PSCustomObject]@{
        Name              = $_.Name
        AktuelleKategorie = $_.CurrentCategory
        NeueKategorie     = $_.RecommendedCategory
        AssetId           = $_.AssetId
    }
}
$Changes | Sort-Object NeueKategorie, Name | Export-Csv -LiteralPath $ChangesCsv -NoTypeInformation -Encoding UTF8
Write-Info "Aenderungen geschrieben: $ChangesCsv ($($Changes.Count) Server)"

Write-Host ""
Write-Host "=== Verteilung nach Ziel-Kategorie ===" -ForegroundColor Yellow
$Plan | Group-Object RecommendedCategory | Sort-Object Count -Descending | Format-Table Count, Name -AutoSize

Write-Host "=== Server mit aktueller Kategorie ungleich Zielkategorie (SuperOps-Update noetig) ===" -ForegroundColor Yellow
$Plan | Where-Object { $_.InSuperOps -and $_.RecommendedCategory -ne 'REVIEW' -and $_.CurrentCategory -ne $_.RecommendedCategory } |
    Format-Table Name, CurrentCategory, RecommendedCategory -AutoSize

Write-Host "=== REVIEW - manuell zu entscheiden ===" -ForegroundColor Yellow
$Plan | Where-Object { $_.RecommendedCategory -eq 'REVIEW' } | Format-Table Name, ExcelGroup, CurrentCategory, Reason -AutoSize
