[CmdletBinding()]
param(
    [string]$ExcelPath = "$PSScriptRoot\Historique\Ditzler_Maintenance_Planung_v2024.xlsx"
)
$zip = [System.IO.Compression.ZipFile]::OpenRead($ExcelPath)
$entry = $zip.GetEntry('xl/workbook.xml')
$xml = New-Object System.Xml.XmlDocument
$reader = New-Object System.IO.StreamReader($entry.Open())
try { $xml.Load($reader) } finally { $reader.Close() }
$ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
$ns.AddNamespace('x','http://schemas.openxmlformats.org/spreadsheetml/2006/main')
$sheet = $xml.SelectSingleNode('//x:sheet', $ns)
$rid = $sheet.GetAttribute('r:id')
$rels = New-Object System.Xml.XmlDocument
$relsEntry = $zip.GetEntry('xl/_rels/workbook.xml.rels')
$reader = New-Object System.IO.StreamReader($relsEntry.Open())
try { $rels.Load($reader) } finally { $reader.Close() }
$relsNs = New-Object System.Xml.XmlNamespaceManager($rels.NameTable)
$relsNs.AddNamespace('rel','http://schemas.openxmlformats.org/package/2006/relationships')
$target = $rels.SelectSingleNode("//rel:Relationship[@Id='$rid']", $relsNs).GetAttribute('Target')
$sheetXml = New-Object System.Xml.XmlDocument
$entry = $zip.GetEntry("xl/$target")
$reader = New-Object System.IO.StreamReader($entry.Open())
try { $sheetXml.Load($reader) } finally { $reader.Close() }
$zip.Dispose()
$sheetNs = New-Object System.Xml.XmlNamespaceManager($sheetXml.NameTable)
$sheetNs.AddNamespace('x','http://schemas.openxmlformats.org/spreadsheetml/2006/main')
$shared = @()
if ($zip.GetEntry('xl/sharedStrings.xml')) {
    $sharedXml = New-Object System.Xml.XmlDocument
    $entry = $zip.GetEntry('xl/sharedStrings.xml')
}

Write-Host "Sheet" $sheet.GetAttribute('name')
$rows = $sheetXml.SelectNodes('//x:sheetData/x:row', $sheetNs)
Write-Host "rows" $rows.Count
foreach ($row in $rows | Select-Object -First 10) {
    $cells = @()
    foreach ($cell in $row.SelectNodes('x:c', $sheetNs)) {
        $v = $cell.SelectSingleNode('x:v', $sheetNs)
        $cells += @{r=$cell.GetAttribute('r'); t=$cell.GetAttribute('t'); v=$v.InnerText}
    }
    Write-Host "row" $row.GetAttribute('r')
    $cells | ForEach-Object { Write-Host "  $_" }
}
