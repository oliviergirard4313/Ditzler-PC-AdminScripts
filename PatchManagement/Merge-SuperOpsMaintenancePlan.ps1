[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ExcelPath,

    [Parameter(Mandatory=$false)]
    [string]$SuperOpsCsv,

    [Parameter(Mandatory=$false)]
    [string]$OutputCsv,

    [Parameter(Mandatory=$false)]
    [switch]$ExportUnmatchedSuperOps
)

if (-not $ExcelPath) {
    $ExcelPath = Join-Path -Path $PSScriptRoot -ChildPath 'Historique\Ditzler_Maintenance_Planung_v2024.xlsx'
}
if (-not $SuperOpsCsv) {
    $SuperOpsCsv = Join-Path -Path $PSScriptRoot -ChildPath 'SuperOps_PatchInventar_20260806_1017.csv'
}
if (-not $OutputCsv) {
    $OutputCsv = Join-Path -Path $PSScriptRoot -ChildPath 'Consolidated_SuperOps_Excel.csv'
}

try {
    [Reflection.Assembly]::LoadWithPartialName('System.IO.Compression.FileSystem') | Out-Null
} catch {
    Write-Verbose 'Unable to load System.IO.Compression.FileSystem assembly.'
}

function Get-ColumnIndex {
    param([string]$column)
    $index = 0
    foreach ($char in $column.ToUpper().ToCharArray()) {
        $index = $index * 26 + ([int][char]$char - [int][char]'A' + 1)
    }
    return $index
}

function Get-SharedStrings {
    param([System.IO.Compression.ZipArchive]$zip)
    $entry = $zip.GetEntry('xl/sharedStrings.xml')
    if (-not $entry) { return @() }
    $xml = New-Object System.Xml.XmlDocument
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try { $xml.Load($reader) } finally { $reader.Close() }
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('x','http://schemas.openxmlformats.org/spreadsheetml/2006/main')
    $shared = @()
    foreach ($si in $xml.SelectNodes('//x:si', $ns)) {
        $text = ''
        foreach ($t in $si.SelectNodes('.//x:t', $ns)) { $text += $t.InnerText }
        $shared += $text
    }
    return $shared
}

function Get-WorksheetPaths {
    param([System.IO.Compression.ZipArchive]$zip)
    $workbookEntry = $zip.GetEntry('xl/workbook.xml')
    if (-not $workbookEntry) { throw 'Workbook XML not found in Excel file.' }
    $xml = New-Object System.Xml.XmlDocument
    $reader = New-Object System.IO.StreamReader($workbookEntry.Open())
    try { $xml.Load($reader) } finally { $reader.Close() }
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('x','http://schemas.openxmlformats.org/spreadsheetml/2006/main')
    $sheetNodes = $xml.SelectNodes('//x:sheet', $ns)
    $relsEntry = $zip.GetEntry('xl/_rels/workbook.xml.rels')
    if (-not $relsEntry) { throw 'Workbook relationships file not found.' }
    $relsXml = New-Object System.Xml.XmlDocument
    $reader = New-Object System.IO.StreamReader($relsEntry.Open())
    try { $relsXml.Load($reader) } finally { $reader.Close() }
    $relsNs = New-Object System.Xml.XmlNamespaceManager($relsXml.NameTable)
    $relsNs.AddNamespace('rel','http://schemas.openxmlformats.org/package/2006/relationships')
    $relMap = @{}
    foreach ($rel in $relsXml.SelectNodes('//rel:Relationship', $relsNs)) {
        $relMap[$rel.GetAttribute('Id')] = $rel.GetAttribute('Target')
    }
    $map = @{}
    foreach ($sheet in $sheetNodes) {
        $rid = $sheet.GetAttribute('r:id')
        $target = $relMap[$rid]
        if ($target) {
            $map[$sheet.GetAttribute('name')] = "xl/$target"
        }
    }
    return $map
}

function Get-RowValues {
    param(
        [System.Xml.XmlNode]$row,
        [System.Xml.XmlNamespaceManager]$ns,
        [string[]]$sharedStrings
    )
    $values = @{}
    foreach ($cell in $row.SelectNodes('x:c', $ns)) {
        $ref = $cell.GetAttribute('r')
        $col = -join ($ref.ToCharArray() | Where-Object { $_ -cmatch '[A-Za-z]' })
        $index = Get-ColumnIndex $col
        $vNode = $cell.SelectSingleNode('x:v', $ns)
        if (-not $vNode) {
            $values[$index] = ''
            continue
        }
        $value = $vNode.InnerText
        if ($cell.GetAttribute('t') -eq 's') {
            $value = $sharedStrings[[int]$value]
        }
        $values[$index] = $value
    }
    $max = 0
    if ($values.Keys) { $max = ($values.Keys | Measure-Object -Maximum).Maximum }
    return (1..$max | ForEach-Object { if ($values.ContainsKey($_)) { $values[$_] } else { '' } })
}

function Read-ExcelAssets {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "Excel file not found: $Path" }
    $assets = @()
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $sharedStrings = Get-SharedStrings -zip $zip
        $worksheets = Get-WorksheetPaths -zip $zip
        foreach ($sheetName in $worksheets.Keys) {
            $entry = $zip.GetEntry($worksheets[$sheetName])
            if (-not $entry) { continue }
            $xml = New-Object System.Xml.XmlDocument
            $reader = New-Object System.IO.StreamReader($entry.Open())
            try { $xml.Load($reader) } finally { $reader.Close() }
            $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
            $ns.AddNamespace('x','http://schemas.openxmlformats.org/spreadsheetml/2006/main')
            $headerFound = $false
            foreach ($row in $xml.SelectNodes('//x:sheetData/x:row', $ns)) {
                $values = Get-RowValues -row $row -ns $ns -sharedStrings $sharedStrings
                if (-not $headerFound) {
                    $normalized = $values | ForEach-Object {
                        if ([string]::IsNullOrWhiteSpace($_)) { '' } else { ($_ -replace '\s+', ' ').Trim() }
                    }
                    if ($normalized -match 'Name' -and $normalized -match 'Server oder Gerät') {
                        $headerFound = $true
                        continue
                    }
                    if ($normalized -contains 'Name') {
                        $headerFound = $true
                        continue
                    }
                    continue
                }
                if ($values.Count -lt 5) { continue }
                $name = $values[4].Trim()
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                $assets += [PSCustomObject]@{
                    Sheet = $sheetName
                    Row = $row.GetAttribute('r')
                    Name = $name
                    UpdateGroup = if ($values.Count -ge 6) { $values[5].Trim() } else { '' }
                    BusinessImpact = if ($values.Count -ge 7) { $values[6].Trim() } else { '' }
                    IsGrundstoff = if ($values.Count -ge 8) { $values[7].Trim() } else { '' }
                    OS = if ($values.Count -ge 13) { $values[12].Trim() } else { '' }
                    IPAddress = if ($values.Count -ge 14) { $values[13].Trim() } else { '' }
                    UpdateDetails = if ($values.Count -ge 15) { $values[14].Trim() } else { '' }
                }
            }
        }
    } finally { $zip.Dispose() }
    return $assets
}

function Read-SuperOpsCsv {
    param([string]$Path)
    if (-not (Test-Path $Path)) { throw "CSV file not found: $Path" }
    Add-Type -AssemblyName Microsoft.VisualBasic
    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Path, [System.Text.Encoding]::UTF8)
    $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
    $parser.SetDelimiters(';')
    $parser.HasFieldsEnclosedInQuotes = $true
    $rows = @()
    try {
        if (-not $parser.EndOfData) { $header = $parser.ReadFields() }
        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            if (-not $fields -or $fields.Count -lt 2) { continue }
            $rows += [PSCustomObject]@{
                AssetId = ($fields[0] -replace '^\ufeff"?|"?$','').Trim()
                Name = ($fields[1] -replace '^"?|"?$','').Trim()
                HostName = if ($fields.Count -gt 2) { ($fields[2] -replace '^"?|"?$','').Trim() } else { '' }
                Platform = if ($fields.Count -gt 3) { ($fields[3] -replace '^"?|"?$','').Trim() } else { '' }
                PlatformFamily = if ($fields.Count -gt 4) { ($fields[4] -replace '^"?|"?$','').Trim() } else { '' }
                Status = if ($fields.Count -gt 5) { ($fields[5] -replace '^"?|"?$','').Trim() } else { '' }
                PatchStatus = if ($fields.Count -gt 6) { ($fields[6] -replace '^"?|"?$','').Trim() } else { '' }
                LastCommunicated = if ($fields.Count -gt 7) { ($fields[7] -replace '^"?|"?$','').Trim() } else { '' }
                Category = if ($fields.Count -gt 8) { ($fields[8] -replace '^"?|"?$','').Trim() } else { '' }
            }
        }
    } finally { $parser.Close() }
    return $rows
}

Write-Host "Reading Excel file: $ExcelPath"
$excelAssets = Read-ExcelAssets -Path $ExcelPath
Write-Host "Found" $excelAssets.Count "assets in Excel."
Write-Host "Reading SuperOps CSV: $SuperOpsCsv"
$soAssets = Read-SuperOpsCsv -Path $SuperOpsCsv
Write-Host "Found" $soAssets.Count "rows in SuperOps export."

$soLookup = @{}
foreach ($asset in $soAssets) {
    if (-not [string]::IsNullOrWhiteSpace($asset.Name)) {
        $soLookup[$asset.Name.ToUpper()] = $asset
    }
}

$merged = foreach ($asset in $excelAssets) {
    $nameKey = $asset.Name.ToUpper()
    $soMatch = if ($soLookup.ContainsKey($nameKey)) { $soLookup[$nameKey] } else { $null }
    [PSCustomObject]@{
        ExcelSheet = $asset.Sheet
        ExcelRow = $asset.Row
        Name = $asset.Name
        UpdateGroup = $asset.UpdateGroup
        OS = $asset.OS
        IPAddress = $asset.IPAddress
        UpdateDetails = $asset.UpdateDetails
        SuperOpsName = if ($soMatch) { $soMatch.Name } else { '' }
        AssetId = if ($soMatch) { $soMatch.AssetId } else { '' }
        HostName = if ($soMatch) { $soMatch.HostName } else { '' }
        Platform = if ($soMatch) { $soMatch.Platform } else { '' }
        PlatformFamily = if ($soMatch) { $soMatch.PlatformFamily } else { '' }
        Status = if ($soMatch) { $soMatch.Status } else { '' }
        PatchStatus = if ($soMatch) { $soMatch.PatchStatus } else { '' }
        LastCommunicated = if ($soMatch) { $soMatch.LastCommunicated } else { '' }
        Category = if ($soMatch) { $soMatch.Category } else { '' }
        Matched = if ($soMatch) { 'Yes' } else { 'No' }
    }
}

$merged | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
Write-Host "Wrote consolidated output to $OutputCsv"

$matchedCount = ($merged | Where-Object { $_.Matched -eq 'Yes' }).Count
$unmatchedCount = ($merged | Where-Object { $_.Matched -eq 'No' }).Count
Write-Host "Exact matches by Name: $matchedCount" "unmatched Excel rows: $unmatchedCount"

if ($ExportUnmatchedSuperOps) {
    $unmatchedSuperOps = $soAssets | Where-Object { -not $soLookup.ContainsKey($_.Name.ToUpper()) -or ($merged | Where-Object { $_.AssetId -eq $_.AssetId -and $_.Matched -eq 'Yes' } | Measure-Object).Count -eq 0 }
    $unmatchedPath = "$PSScriptRoot\SuperOps_Unmatched.csv"
    $unmatchedSuperOps | Export-Csv -Path $unmatchedPath -NoTypeInformation -Encoding UTF8
    Write-Host "Wrote unmatched SuperOps rows to $unmatchedPath"
}
