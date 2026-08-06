#Requires -Version 5.1

# ==========================================================
# VERIFY-ONBOARDED-SERVERS.PS1
# Zweck    : Vergleicht aktive AD Server mit dem SuperOps Asset-Export
#            und optional mit Nutanix VM-Inventar.
# Autor    : Claude / GitHub Copilot
# Version  : 1.0
# Datum    : 2026-08-06
# ==========================================================

param(
    [string]$SuperOpsCsv = "C:\Admin\Ditzler\PatchManagement\SuperOps_PatchInventar_20260806_1017.csv",
    [switch]$IncludeNutanix,
    [string]$NutanixClusterIp,
    [string]$OutputFolder = "C:\Admin\Ditzler\PatchManagement"
)

$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrorAndExit {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

function Get-ADServerList {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Write-Info "ActiveDirectory-Modul nicht gefunden. Versuch, RSAT-AD-PowerShell zu installieren..."
        try {
            Import-Module ServerManager -ErrorAction Stop
            Install-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction Stop | Out-Null
            Write-Info "RSAT-AD-PowerShell installiert"
        }
        catch {
            Write-ErrorAndExit "ActiveDirectory Modul fehlt und konnte nicht installiert werden: $($_.Exception.Message)"
        }
    }

    Import-Module ActiveDirectory -ErrorAction Stop

    # Technische AD-Konten und CNOs (Cluster Name Objects) - kein eigenes
    # patchbares OS, nur die echten Cluster-Nodes (z.B. SV-OS-SQLND-*,
    # SV-OS-FSND-*) werden individuell erfasst und gepatcht.
    $ExcludedPatterns = @(
        "AZUREADSSOACC",
        "AZUREADKERBEROS*",
        "CAU*",
        "*DBCL*",
        "*SQLCL*",
        "*FSCL*"
    )

    Write-Info "Abfrage AD: alle aktiven Computer-Objekte mit OperatingSystem wie '*Server*' (Domaene ditzlernet.local)"
    $allNames = Get-ADComputer -Filter { Enabled -eq $true -and OperatingSystem -like "*Server*" } -Properties Name |
        Select-Object -ExpandProperty Name |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.ToUpperInvariant() }

    $filtered = $allNames | Sort-Object -Unique | Where-Object {
        $name = $_
        -not ($ExcludedPatterns | Where-Object { $name -like $_.ToUpperInvariant() })
    }

    return $filtered
}

function Read-SuperOpsAssets {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        Write-ErrorAndExit "SuperOps CSV nicht gefunden: $Path"
    }

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    $assets = @()

    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if (-not $line.Trim()) { continue }
        $fields = $line -split ';' | ForEach-Object { $_.Trim('"') }
        if ($fields.Count -lt 2) { continue }
        $assets += [PSCustomObject]@{
            Name     = ($fields[1] -replace '"','').Trim().ToUpperInvariant()
            Category = if ($fields.Count -gt 8) { ($fields[8] -replace '"','').Trim() } else { '' }
            Platform = if ($fields.Count -gt 3) { ($fields[3] -replace '"','').Trim() } else { '' }
            Status   = if ($fields.Count -gt 5) { ($fields[5] -replace '"','').Trim() } else { '' }
        }
    }

    return $assets | Sort-Object -Property Name -Unique
}

function Get-NutanixVMList {
    # Zugangsdaten aus der bestehenden Ditzler-Powershell-Lib, gleiches
    # Muster wie "Monitoring Nutanix Snapshots.ps1" - keine Klartext-
    # Credentials als Skriptparameter.
    $LibPath = "C:\ProgramData\Superops\Scripts\Ditzler-Powershell-Lib.psm1"
    if (-not (Test-Path -LiteralPath $LibPath)) {
        Write-ErrorAndExit "Ditzler-Powershell-Lib nicht gefunden: $LibPath"
    }
    Import-Module $LibPath -Force
    Initialize-WorkDir

    $AllCreds = Get-Credentials -FileName "credentials.xml"
    $NutanixCreds = $AllCreds['ServiceAccounts']['Nutanix']
    if (-not $NutanixCreds) {
        Write-ErrorAndExit "Nutanix ServiceAccount fehlt in credentials.xml"
    }

    $NutUsername = $NutanixCreds.Username
    $NutPassword = $NutanixCreds.Password
    $ClusterTarget = if ($NutanixClusterIp) { $NutanixClusterIp } else { $NutanixCreds.Server }

    $roots = @('C:\Service\NutanixCmdlets', 'C:\Program Files (x86)\Nutanix Inc\NutanixCmdlets')
    $modules = @('Nutanix.Cli', 'Nutanix.Prism.Common', 'Nutanix.Prism.PS.Cmds')
    foreach ($module in $modules) {
        $manifest = $null
        foreach ($root in $roots) {
            if (Test-Path $root) {
                $found = Get-ChildItem -Path $root -Filter "$module.psd1" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($found) { $manifest = $found.FullName; break }
            }
        }
        if (-not $manifest) {
            Write-ErrorAndExit "Nutanix Modul '$module' nicht gefunden unter $($roots -join ', ')"
        }
        Import-Module -Name $manifest -Global -Force -ErrorAction Stop
    }

    Connect-NutanixCluster -Server $ClusterTarget -UserName $NutUsername -Password $NutPassword -AcceptInvalidSSLCerts | Out-Null
    $vms = Get-NTNXVM | Select-Object -ExpandProperty VMName
    return $vms | ForEach-Object { $_.ToUpperInvariant() } | Sort-Object -Unique
}

Write-Info "Starte Überprüfung der Onboarded-Server"

$adServers = Get-ADServerList
Write-Info "AD Server count: $($adServers.Count)"

$soAssets = Read-SuperOpsAssets -Path $SuperOpsCsv
Write-Info "SuperOps assets read: $($soAssets.Count)"

$soNames = $soAssets | Select-Object -ExpandProperty Name
$missingInSuperOps = $adServers | Where-Object { $soNames -notcontains $_ }
$missingInAD = $soNames | Where-Object { $adServers -notcontains $_ }

$missingInSuperOpsPath = Join-Path $OutputFolder 'MissingInSuperOps.txt'
$missingInADPath = Join-Path $OutputFolder 'MissingInAD.txt'
$soTablePath = Join-Path $OutputFolder 'SuperOps_ServerInventory.csv'

$missingInSuperOps | Set-Content -LiteralPath $missingInSuperOpsPath -Encoding UTF8
$missingInAD | Set-Content -LiteralPath $missingInADPath -Encoding UTF8
$soAssets | Export-Csv -LiteralPath $soTablePath -NoTypeInformation -Encoding UTF8

Write-Info "Ergebnis geschrieben: $missingInSuperOpsPath, $missingInADPath, $soTablePath"
Write-Info "Fehlende AD Server in SuperOps: $($missingInSuperOps.Count)"
Write-Info "SuperOps Names nicht in AD: $($missingInAD.Count)"

if ($IncludeNutanix) {
    Write-Info "Nutanix-Abfrage aktiv. Verbinde mit $NutanixClusterIp"
    $nutanixVMs = Get-NutanixVMList
    $nutanixPath = Join-Path $OutputFolder 'Nutanix_VMs.txt'
    $nutanixVMs | Set-Content -LiteralPath $nutanixPath -Encoding UTF8
    Write-Info "Nutanix VMs geschrieben: $nutanixPath"
    $untrackedNutanix = $nutanixVMs | Where-Object { $soNames -notcontains $_ }
    $untrackedPath = Join-Path $OutputFolder 'Nutanix_VMs_NotInSuperOps.txt'
    $untrackedNutanix | Set-Content -LiteralPath $untrackedPath -Encoding UTF8
    Write-Info "Nutanix VMs ohne SuperOps-Asset: $($untrackedNutanix.Count)"
}

Write-Info "Verifizierung abgeschlossen."