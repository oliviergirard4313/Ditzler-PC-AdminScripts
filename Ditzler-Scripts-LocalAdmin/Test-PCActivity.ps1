#requires -version 5.1
#requires -modules ActiveDirectory

[CmdletBinding()]
param(
    [string[]]$ComputerNames = @(
        "CLT-2SIUWIH2Z6D",
        "CLT-2VCPAQXDB9T",
        "CLT-66ZWI8JJOS3",
        "CLT-BLXJH0ETA69",
        "CLT-D6SKUQMWY5G",
        "CLT-UWEMSLRQAHV"
    ),

    [int]$RecentDays = 45,
    [int]$InactiveDays = 90,

    [string]$CsvPath = "C:\Service\AD-SuperOps-Audit\Logs\PC-Aktivitaetspruefung.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-TcpPort {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [int]$Port,

        [int]$TimeoutMs = 1500
    )

    $client = New-Object System.Net.Sockets.TcpClient

    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)

        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            return $false
        }

        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Get-ExactLastLogon {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [object[]]$DomainControllers
    )

    $latest = $null

    foreach ($dc in $DomainControllers) {
        try {
            $computer = Get-ADComputer `
                -Identity $ComputerName `
                -Server $dc.HostName `
                -Properties lastLogon `
                -ErrorAction Stop

            if ($computer.lastLogon -gt 0) {
                $date = [DateTime]::FromFileTime([Int64]$computer.lastLogon)

                if ($null -eq $latest -or $date -gt $latest) {
                    $latest = $date
                }
            }
        }
        catch {
            Write-Verbose "Letzter Logon konnte auf $($dc.HostName) fuer $ComputerName nicht gelesen werden: $($_.Exception.Message)"
        }
    }

    return $latest
}

$now = Get-Date
$recentLimit = $now.AddDays(-$RecentDays)
$inactiveLimit = $now.AddDays(-$InactiveDays)

$domainControllers = @(
    Get-ADDomainController -Filter * |
        Sort-Object HostName
)

$results = foreach ($computerName in $ComputerNames) {
    Write-Host "Pruefe $computerName ..." -ForegroundColor Cyan

    try {
        $adComputer = Get-ADComputer `
            -Identity $computerName `
            -Properties `
                DNSHostName,
                Enabled,
                LastLogonDate,
                PasswordLastSet,
                OperatingSystem,
                DistinguishedName,
                whenCreated,
                whenChanged `
            -ErrorAction Stop
    }
    catch {
        [PSCustomObject]@{
            ComputerName       = $computerName
            Bewertung          = "NICHT IN AD"
            ADEnabled          = $null
            OperatingSystem    = $null
            DNSHostName        = $null
            DNSAufloesbar      = $false
            IPAdresse          = $null
            Ping               = $false
            SMB445             = $false
            WinRM5985          = $false
            LastLogonExact     = $null
            LastLogonReplicated = $null
            PasswordLastSet    = $null
            TageSeitLogon      = $null
            TageSeitPasswort   = $null
            DistinguishedName  = $null
            Hinweis            = $_.Exception.Message
        }

        continue
    }

    $dnsName = if ([string]::IsNullOrWhiteSpace($adComputer.DNSHostName)) {
        $computerName
    }
    else {
        $adComputer.DNSHostName
    }

    $dnsResolvable = $false
    $ipAddress = $null

    try {
        $dnsResult = Resolve-DnsName `
            -Name $dnsName `
            -Type A `
            -ErrorAction Stop |
            Where-Object { $_.IPAddress } |
            Select-Object -First 1

        if ($null -ne $dnsResult) {
            $dnsResolvable = $true
            $ipAddress = $dnsResult.IPAddress
        }
    }
    catch {
        $dnsResolvable = $false
    }

    $ping = $false

    try {
        $ping = Test-Connection `
            -ComputerName $dnsName `
            -Count 1 `
            -Quiet `
            -ErrorAction SilentlyContinue
    }
    catch {
        $ping = $false
    }

    $smb = Test-TcpPort -ComputerName $dnsName -Port 445
    $winrm = Test-TcpPort -ComputerName $dnsName -Port 5985

    $exactLastLogon = Get-ExactLastLogon `
        -ComputerName $computerName `
        -DomainControllers $domainControllers

    $daysSinceLogon = if ($null -ne $exactLastLogon) {
        [math]::Floor(($now - $exactLastLogon).TotalDays)
    }
    else {
        $null
    }

    $daysSincePassword = if ($null -ne $adComputer.PasswordLastSet) {
        [math]::Floor(($now - $adComputer.PasswordLastSet).TotalDays)
    }
    else {
        $null
    }

    $networkActive = $ping -or $smb -or $winrm

    $recentAdActivity =
        ($null -ne $exactLastLogon -and $exactLastLogon -ge $recentLimit) -or
        ($null -ne $adComputer.PasswordLastSet -and $adComputer.PasswordLastSet -ge $recentLimit)

    $oldOrMissingLogon =
        ($null -eq $exactLastLogon) -or
        ($exactLastLogon -lt $inactiveLimit)

    $oldOrMissingPassword =
        ($null -eq $adComputer.PasswordLastSet) -or
        ($adComputer.PasswordLastSet -lt $inactiveLimit)

    if (-not $adComputer.Enabled) {
        $assessment = "AD DEAKTIVIERT"
    }
    elseif ($networkActive) {
        $assessment = "AKTIV"
    }
    elseif ($recentAdActivity) {
        $assessment = "WAHRSCHEINLICH AKTIV"
    }
    elseif ($oldOrMissingLogon -and $oldOrMissingPassword) {
        $assessment = "WAHRSCHEINLICH INAKTIV"
    }
    else {
        $assessment = "PRUEFEN"
    }

    $note = if ($computerName -eq "CLT-PT25PLIOCYG") {
        "Namensabweichung pruefen: In SuperOps wurde CLT-PT25PLI0CYG gefunden (O/0)."
    }
    else {
        $null
    }

    [PSCustomObject]@{
        ComputerName        = $computerName
        Bewertung           = $assessment
        ADEnabled            = $adComputer.Enabled
        OperatingSystem     = $adComputer.OperatingSystem
        DNSHostName         = $adComputer.DNSHostName
        DNSAufloesbar       = $dnsResolvable
        IPAdresse           = $ipAddress
        Ping                = $ping
        SMB445              = $smb
        WinRM5985           = $winrm
        LastLogonExact      = $exactLastLogon
        LastLogonReplicated = $adComputer.LastLogonDate
        PasswordLastSet     = $adComputer.PasswordLastSet
        TageSeitLogon       = $daysSinceLogon
        TageSeitPasswort    = $daysSincePassword
        DistinguishedName   = $adComputer.DistinguishedName
        Hinweis             = $note
    }
}

$results |
    Sort-Object Bewertung, ComputerName |
    Format-Table `
        ComputerName,
        Bewertung,
        ADEnabled,
        DNSAufloesbar,
        Ping,
        SMB445,
        WinRM5985,
        TageSeitLogon,
        TageSeitPasswort `
        -AutoSize

$csvDirectory = Split-Path -Path $CsvPath -Parent

if (-not (Test-Path -LiteralPath $csvDirectory)) {
    New-Item -Path $csvDirectory -ItemType Directory -Force | Out-Null
}

$results |
    Sort-Object ComputerName |
    Export-Csv `
        -LiteralPath $CsvPath `
        -Delimiter ";" `
        -NoTypeInformation `
        -Encoding UTF8

Write-Host ""
Write-Host "CSV erstellt: $CsvPath" -ForegroundColor Green
