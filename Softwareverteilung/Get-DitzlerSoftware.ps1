#Requires -Version 5.1
<#
.SYNOPSIS
    Laedt einen Installer aus der Azure-Softwareverteilung (ditzlersoftware)
    herunter und prueft den SHA256-Hash, bevor er verwendet wird.

.DESCRIPTION
    Funktioniert innerhalb und ausserhalb des Firmennetzes (HTTPS nach
    https://ditzlersoftware.blob.core.windows.net).

    Ablauf:
      1. Liegt die Datei mit dem richtigen Hash schon im Zielordner, wird sie
         wiederverwendet (kein erneuter Download).
      2. Download nach <Datei>.part mit bis zu -Versuche Versuchen
         (403/404 werden nicht wiederholt: SAS ungueltig bzw. Pfad falsch).
      3. SHA256 pruefen. Bei Abweichung wird die Datei geloescht und eine
         Ausnahme geworfen - die Datei wird NIE ausgefuehrt.
      4. Rueckgabe: vollstaendiger Pfad der geprueften Datei.

    Fehler werden als Ausnahme geworfen (Meldungen ohne SAS). Im SuperOps-
    Skript per try/catch abfangen und mit Stop-Script melden (Event 9001).

    Der erwartete Hash stammt aus Publish-Software.ps1 und gehoert ins
    SuperOps-Skript - NICHT aus den Blob-Metadaten lesen (wer die Datei
    manipulieren kann, koennte auch die Metadaten aendern).

    Kompatibel mit Windows PowerShell 5.1 (SuperOps-Agent, SYSTEM).

.PARAMETER Pfad
    Blob-Pfad innerhalb des Containers, z.B. 'Nutanix/NGT/4.5.1.8/nutanix-guest-agent-4.5.1.8.exe'
    (wird von Publish-Software.ps1 ausgegeben).

.PARAMETER Sha256
    Erwarteter SHA256-Hash (64 Hex-Zeichen).

.PARAMETER Sas
    SAS-Token der Policy "clients-lesen" (mit oder ohne fuehrendes '?').
    In SuperOps als geheime Variable hinterlegen, nie im Skripttext.

.PARAMETER Zielordner
    Standard: C:\Windows\Temp\DitzlerSoftware

.EXAMPLE
    . .\Get-DitzlerSoftware.ps1
    try {
        $installer = Get-DitzlerSoftware -Pfad '7-Zip/7-Zip/25.01/7z2501-x64.msi' `
                                         -Sha256 '0123...ABCD' -Sas $Sas
        $p = Start-Process msiexec.exe -ArgumentList "/i `"$installer`" /qn /norestart" -Wait -PassThru
        if ($p.ExitCode -notin 0, 3010) { throw "msiexec ExitCode $($p.ExitCode)" }
    }
    catch {
        Stop-Script -Message "7-Zip Installation fehlgeschlagen: $($_.Exception.Message)"
    }

.NOTES
    Autor   : GIO / Claude
    Version : 1.0
    Datum   : 26.11.2026
    Spaeter in Ditzler-Powershell-Lib.psm1 uebernehmen.
#>

function Get-DitzlerSoftware {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Pfad,
        [Parameter(Mandatory)] [ValidatePattern('^[0-9A-Fa-f]{64}$')] [string] $Sha256,
        [Parameter(Mandatory)] [string] $Sas,
        [string] $Zielordner     = (Join-Path $env:windir 'Temp\DitzlerSoftware'),
        [string] $StorageAccount = 'ditzlersoftware',
        [string] $Container      = 'software',
        [ValidateRange(1, 10)] [int] $Versuche = 3
    )

    $Sas    = $Sas.Trim().TrimStart('?')
    $Sha256 = $Sha256.ToUpperInvariant()
    if (-not $Sas) { throw 'Get-DitzlerSoftware: SAS-Token ist leer.' }

    # Blob-Pfad pruefen und URL bauen (jedes Segment kodieren)
    $segmente = $Pfad.Trim('/').Split('/')
    if ($segmente.Count -lt 2 -or ($segmente | Where-Object { -not $_ -or $_ -match '^\.+$' })) {
        throw "Get-DitzlerSoftware: ungueltiger Pfad '$Pfad'."
    }
    $dateiname = $segmente[-1]
    $url       = 'https://{0}.blob.core.windows.net/{1}/{2}' -f $StorageAccount, $Container,
                 (($segmente | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')

    if (-not (Test-Path $Zielordner)) {
        New-Item -ItemType Directory -Path $Zielordner -Force | Out-Null
    }
    $ziel    = Join-Path $Zielordner $dateiname
    $tempZiel = "$ziel.part"

    # 1. Bereits vorhanden und korrekt?
    if (Test-Path -LiteralPath $ziel) {
        if ((Get-FileHash -LiteralPath $ziel -Algorithm SHA256).Hash -eq $Sha256) {
            Write-Verbose "Bereits vorhanden und Hash korrekt: $ziel"
            return $ziel
        }
        Remove-Item -LiteralPath $ziel -Force
    }

    # TLS 1.2 fuer Windows PowerShell 5.1 erzwingen
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    # 2. Download mit Wiederholung
    $alteProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # sonst ist Invoke-WebRequest unter 5.1 extrem langsam
    $letzterFehler = $null
    try {
        for ($n = 1; $n -le $Versuche; $n++) {
            try {
                if (Test-Path -LiteralPath $tempZiel) { Remove-Item -LiteralPath $tempZiel -Force }
                Invoke-WebRequest -Uri "$url`?$Sas" -OutFile $tempZiel -UseBasicParsing -TimeoutSec 1800 -ErrorAction Stop
                $letzterFehler = $null
                break
            }
            catch {
                $status = $null
                if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
                $meldung = $_.Exception.Message.Replace($Sas, '<SAS>')
                $letzterFehler = if ($status) { "HTTP $status - $meldung" } else { $meldung }

                if ($status -in 403, 404) {
                    break   # SAS ungueltig/abgelaufen oder Pfad falsch - Wiederholen sinnlos
                }
                if ($n -lt $Versuche) {
                    Write-Verbose "Versuch $n/$Versuche fehlgeschlagen ($letzterFehler) - neuer Versuch in $($n * 15) s"
                    Start-Sleep -Seconds ($n * 15)
                }
            }
        }
    }
    finally {
        $ProgressPreference = $alteProgress
    }

    if ($letzterFehler) {
        if (Test-Path -LiteralPath $tempZiel) { Remove-Item -LiteralPath $tempZiel -Force }
        throw "Get-DitzlerSoftware: Download von '$Pfad' fehlgeschlagen: $letzterFehler"
    }

    # 3. Hash pruefen
    $istHash = (Get-FileHash -LiteralPath $tempZiel -Algorithm SHA256).Hash
    if ($istHash -ne $Sha256) {
        Remove-Item -LiteralPath $tempZiel -Force
        throw "Get-DitzlerSoftware: SHA256 von '$Pfad' stimmt nicht (erwartet $Sha256, erhalten $istHash). Datei geloescht."
    }

    Move-Item -LiteralPath $tempZiel -Destination $ziel -Force
    return $ziel
}
