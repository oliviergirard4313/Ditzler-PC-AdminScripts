#Requires -Version 7.0
<#
.SYNOPSIS
    Nur-Lese-Test des Prism-Central-Zugriffs von svc_batchpatch
    (Anmeldung, sichtbare VMs, Recovery Points). Aendert NICHTS.

.DESCRIPTION
    In der Sitzung DITZLERNET\svc_batchpatch auf SV-OS-WSUS-01 ausfuehren
    (Zugangsdaten DPAPI, nur unter diesem Konto lesbar).
    Ausgabe: C:\Temp\GIO-Ausgabe\Test-PrismZugriff.txt

.NOTES
    Autor   : Olivier
    Version : 1.0
    Datum   : 23.11.2026
#>
param(
    [string]$PrismCentral = '10.100.2.99',
    [string]$CredFile     = 'C:\Service\BatchPatch\Cred\prism-central.xml',
    [string[]]$VmNames    = @('SV-PSG-CIM-01', 'SV-PSG-CIM-02', 'SV-PSG-HIST-01'),
    [string]$Ausgabe      = 'C:\Temp\GIO-Ausgabe\Test-PrismZugriff.txt'
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path (Split-Path $Ausgabe) | Out-Null
Set-Content -Path $Ausgabe -Value "Host: $env:COMPUTERNAME  Benutzer: $env:USERDOMAIN\$env:USERNAME  $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')" -Encoding UTF8
function W { param([string]$T) Write-Host $T; Add-Content -Path $Ausgabe -Value $T -Encoding UTF8 }

$Base = "https://$($PrismCentral):9440/api/nutanix/v3"
function Invoke-Prism {
    param([string]$Method, [string]$Path, $Body)
    $p = @{ Method = $Method; Uri = "$Base/$Path"; Credential = $Cred; Authentication = 'Basic'
            SkipCertificateCheck = $true; ContentType = 'application/json'; TimeoutSec = 60 }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 50) }
    try { Invoke-RestMethod @p }
    catch { throw "$Method $Path : $($_.Exception.Message) $($_.ErrorDetails.Message)" }
}

try {
    W "`n=== [1/4] Zugangsdaten ==="
    $Cred = Import-Clixml -Path $CredFile
    W "   OK: $($Cred.UserName)"

    W "`n=== [2/4] Sichtbare VMs (erwartet: nur die 3 PSG-VMs) ==="
    $r = Invoke-Prism POST 'vms/list' @{ kind = 'vm'; length = 50 }
    W "   Anzahl: $($r.metadata.total_matches)"
    $r.entities | ForEach-Object { W ("   {0}  {1}" -f $_.status.name, $_.status.resources.power_state) }

    W "`n=== [3/4] Einzelabfrage je VM ==="
    $i = 0
    foreach ($n in $VmNames) {
        $i++
        Write-Progress -Activity 'VMs' -Status "[$i/$($VmNames.Count)] $n" -PercentComplete ($i / $VmNames.Count * 100)
        $l = Invoke-Prism POST 'vms/list' @{ kind = 'vm'; length = 20; filter = "vm_name==$n" }
        $t = @($l.entities | Where-Object { $_.status.name -eq $n })
        if ($t.Count -ne 1) { W "   [$i/$($VmNames.Count)] $n : NICHT gefunden ($($t.Count))"; continue }
        $vm = Invoke-Prism GET "vms/$($t[0].metadata.uuid)"
        W ("   [{0}/{1}] {2} : uuid={3} Status={4} GET OK" -f $i, $VmNames.Count, $n, $vm.metadata.uuid, $vm.status.resources.power_state)
    }
    Write-Progress -Activity 'VMs' -Completed

    W "`n=== [4/4] Recovery Points (lesen) ==="
    $rp = Invoke-Prism POST 'vm_recovery_points/list' @{ kind = 'vm_recovery_point'; length = 100 }
    W "   Anzahl sichtbar: $($rp.metadata.total_matches)"
    $rp.entities | Select-Object -First 10 | ForEach-Object { W ("   {0}  {1}" -f $_.status.name, $_.status.resources.parent_vm_reference.name) }

    W "`nFERTIG (nichts geaendert)."
}
catch { W ("FEHLER: {0}" -f $_.Exception.Message) }
