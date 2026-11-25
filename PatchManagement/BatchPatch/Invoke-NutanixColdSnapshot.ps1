#Requires -Version 7.0
<#
.SYNOPSIS
    Kalter Snapshot einer Nutanix-VM vor dem Patchen: Gast herunterfahren,
    Recovery Point anlegen, VM wieder starten, warten bis erreichbar.

.DESCRIPTION
    Wird von BatchPatch (Dienst unter DITZLERNET\svc_batchpatch auf
    SV-OS-WSUS-01) als "Execute local command" pro Zeile aufgerufen:
        pwsh.exe -NoProfile -File C:\Service\BatchPatch\Scripts\Invoke-NutanixColdSnapshot.ps1 -VmName $computer
    Ein ExitCode <> 0 bricht die Job Queue ab
    ("If previous action failed/errored (returned non-0), terminate queue").

    Prism Central API v3 (SV-NU-PrismCentral, 10.100.2.99:9440).
    Anmeldung: DITZLERNET\svc_batchpatch (Rolle in Prism Central), Passwort
    DPAPI-verschluesselt in -CredFile (nur unter svc_batchpatch lesbar).

    Recovery Point: Name BatchPatch_Update_<JJJJMMTT> (KB "Nutanix: Manueller
    Snapshot (Recovery Point) vor Updates"), Ablaufdatum nach -ExpiryDays
    (Standard 6 Tage, KB: hoechstens 7). Nach erfolgreichem Update MANUELL
    loeschen (Erinnerung im Outlook-Kalender), nicht auf den Ablauf warten.

    Herunterfahren nur per ACPI (sauber). Kein hartes Ausschalten: laeuft
    das Herunterfahren in den Timeout, bricht das Skript ab und die VM
    bleibt wie sie ist.

.PARAMETER VmName
    Name der VM in Prism Central (= Hostname, z.B. SV-PSG-CIM-01).

.PARAMETER CredFile
    Export-Clixml einer PSCredential (erstellt unter svc_batchpatch).

.NOTES
    Autor   : Olivier
    Version : 1.2 (Ablaufdatum 6 Tage, Name nach KB, -DryRun)
    Datum   : 23.11.2026

    Exitcodes:
      0  = OK
      10 = VM nicht (eindeutig) gefunden / Anmeldung fehlgeschlagen
      20 = Herunterfahren nicht innerhalb Timeout
      30 = Recovery Point fehlgeschlagen
      40 = Einschalten fehlgeschlagen
      50 = VM nach dem Start nicht erreichbar (Ping + TCP 445)
      1  = Unerwarteter Fehler
#>

param(
    [Parameter(Mandatory)][string]$VmName,
    [string]$PrismCentral = '10.100.2.99',
    [string]$CredFile     = 'C:\Service\BatchPatch\Cred\prism-central.xml',
    [string]$HostToCheck,
    [int]$ShutdownTimeoutMin = 15,
    [int]$OnlineTimeoutMin   = 15,
    [ValidateRange(1, 7)][int]$ExpiryDays = 6,
    # Nur Anmeldung, VM-Suche und Erreichbarkeit pruefen - nichts ausschalten/anlegen
    [switch]$DryRun,
    [string]$LogDir          = 'C:\Service\BatchPatch\Logs'
)

$ErrorActionPreference = 'Stop'
if (-not $HostToCheck) { $HostToCheck = $VmName }
# BatchPatch uebergibt evtl. den FQDN (z.B. SV-PSG-CIM-01.grundstoff.ditzler.ch):
# VM-Name in Prism = Kurzname, Erreichbarkeit ueber den FQDN pruefen
if ($VmName -match '\.') { $VmName = ($VmName -split '\.')[0].ToUpper() }
$Base = "https://$($PrismCentral):9440/api/nutanix/v3"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("NutanixSnapshot_{0}_{1:yyyyMMdd}.log" -f $VmName, (Get-Date))
function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] [{2}] {3}" -f (Get-Date), $Level, $VmName, $Msg
    Write-Output $line
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
}
function Stop-WithCode { param([int]$Code, [string]$Msg) Write-Log $Msg 'ERROR'; exit $Code }

try { $Cred = Import-Clixml -Path $CredFile }
catch { Stop-WithCode 10 "Zugangsdaten nicht lesbar ($CredFile): $($_.Exception.Message)" }

function Invoke-Prism {
    param([string]$Method, [string]$Path, $Body)
    $p = @{ Method = $Method; Uri = "$Base/$Path"; Credential = $Cred; Authentication = 'Basic'
            SkipCertificateCheck = $true; ContentType = 'application/json'; TimeoutSec = 60 }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 50) }
    Invoke-RestMethod @p
}

function Wait-PrismTask {
    param([string]$TaskUuid, [int]$TimeoutSec = 600)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        $t = Invoke-Prism GET "tasks/$TaskUuid"
        if ($t.status -eq 'SUCCEEDED') { return $true }
        if ($t.status -in 'FAILED','ABORTED') { Write-Log ("Task {0}: {1} {2}" -f $TaskUuid, $t.status, ($t.error_detail | Out-String).Trim()) 'ERROR'; return $false }
        Start-Sleep -Seconds 5
    }
    Write-Log "Task ${TaskUuid}: Timeout" 'ERROR'
    return $false
}

function Get-Vm { param([string]$Uuid) Invoke-Prism GET "vms/$Uuid" }

function Set-VmPower {
    param([string]$Uuid, [ValidateSet('ON','OFF')][string]$State)
    $vm = Get-Vm $Uuid
    $body = [ordered]@{ api_version = $vm.api_version; metadata = $vm.metadata; spec = $vm.spec }
    $body.spec.resources.power_state = $State
    if ($State -eq 'OFF') {
        $body.spec.resources | Add-Member -NotePropertyName power_state_mechanism -NotePropertyValue ([pscustomobject]@{ mechanism = 'ACPI' }) -Force
    }
    $r = Invoke-Prism PUT "vms/$Uuid" $body
    return $r.status.execution_context.task_uuid
}

function Wait-PowerState {
    param([string]$Uuid, [string]$State, [int]$TimeoutMin)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMinutes -lt $TimeoutMin) {
        if ((Get-Vm $Uuid).status.resources.power_state -eq $State) { return $true }
        Start-Sleep -Seconds 10
    }
    return $false
}

try {
    Write-Log "----- Start kalter Snapshot (PC $PrismCentral) -----"

    # 1. VM finden
    try { $list = Invoke-Prism POST 'vms/list' @{ kind = 'vm'; length = 20; filter = "vm_name==$VmName" } }
    catch { Stop-WithCode 10 "Prism Central nicht erreichbar oder Anmeldung abgelehnt: $($_.Exception.Message)" }
    $vms = @($list.entities | Where-Object { $_.status.name -eq $VmName })
    if ($vms.Count -ne 1) { Stop-WithCode 10 "VM '$VmName' nicht eindeutig gefunden (Treffer: $($vms.Count))." }
    $Uuid = $vms[0].metadata.uuid
    Write-Log ("VM gefunden: uuid={0}, Status={1}" -f $Uuid, $vms[0].status.resources.power_state)

    if ($DryRun) {
        $vm = Get-Vm $Uuid
        $ngt = $vm.spec.resources.guest_tools.nutanix_guest_tools
        Write-Log ("[DRY-RUN] GET vms/{0} OK, NGT: {1}" -f $Uuid, $(if ($ngt) { $ngt.state } else { 'nicht gemeldet' }))
        Write-Log ("[DRY-RUN] wuerde: Herunterfahren ACPI (max {0} min), Recovery Point 'BatchPatch_Update_{1:yyyyMMdd}' mit Ablauf +{2} Tage, Einschalten, warten auf Ping+445 (max {3} min)" -f $ShutdownTimeoutMin, (Get-Date), $ExpiryDays, $OnlineTimeoutMin)
        $ping = Test-Connection -TargetName $HostToCheck -Count 1 -Quiet -TimeoutSeconds 2
        $t = New-Object Net.Sockets.TcpClient
        try { $smb = $t.ConnectAsync($HostToCheck, 445).Wait(3000) } catch { $smb = $false } finally { $t.Dispose() }
        Write-Log ("[DRY-RUN] Erreichbarkeit {0} jetzt: Ping={1}, TCP 445={2}" -f $HostToCheck, $ping, $smb)
        Write-Log '[DRY-RUN] Nichts geaendert.'
        exit $(if ($ping -and $smb) { 0 } else { 50 })
    }

    # 2. Herunterfahren (ACPI)
    if ($vms[0].status.resources.power_state -ne 'OFF') {
        $task = Set-VmPower -Uuid $Uuid -State OFF
        Write-Log "Herunterfahren (ACPI) angestossen, Task $task"
        if (-not (Wait-PowerState -Uuid $Uuid -State 'OFF' -TimeoutMin $ShutdownTimeoutMin)) {
            Stop-WithCode 20 "VM nach $ShutdownTimeoutMin min nicht aus - kein hartes Ausschalten, Abbruch."
        }
        Write-Log 'VM ist ausgeschaltet.'
    } else { Write-Log 'VM war bereits ausgeschaltet.' 'WARN' }

    # 3. Recovery Point
    $RpName = "BatchPatch_Update_{0:yyyyMMdd}" -f (Get-Date)
    $Expiry = (Get-Date).ToUniversalTime().AddDays($ExpiryDays).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    $rpBody = @{
        api_version = '3.1.0'
        metadata    = @{ kind = 'vm_recovery_point' }
        spec        = @{ name = $RpName; resources = @{ parent_vm_reference = @{ kind = 'vm'; uuid = $Uuid }; expiration_time = $Expiry } }
    }
    Write-Log "Recovery Point $RpName, Ablauf $Expiry (UTC)"
    try { $rp = Invoke-Prism POST 'vm_recovery_points' $rpBody }
    catch { Stop-WithCode 30 "Recovery Point konnte nicht angelegt werden: $($_.Exception.Message) - VM bleibt AUS." }
    if (-not (Wait-PrismTask -TaskUuid $rp.status.execution_context.task_uuid)) {
        Stop-WithCode 30 "Recovery Point '$RpName' fehlgeschlagen - VM bleibt AUS."
    }
    Write-Log "Recovery Point angelegt: $RpName"

    # 4. Einschalten
    try { $task = Set-VmPower -Uuid $Uuid -State ON }
    catch { Stop-WithCode 40 "Einschalten fehlgeschlagen: $($_.Exception.Message)" }
    if (-not (Wait-PowerState -Uuid $Uuid -State 'ON' -TimeoutMin 5)) { Stop-WithCode 40 'VM nach 5 min nicht eingeschaltet.' }
    Write-Log 'VM eingeschaltet, warte auf Erreichbarkeit (Ping + TCP 445).'

    # 5. Erreichbarkeit
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $online = $false
    while ($sw.Elapsed.TotalMinutes -lt $OnlineTimeoutMin) {
        if (Test-Connection -TargetName $HostToCheck -Count 1 -Quiet -TimeoutSeconds 2) {
            $t = New-Object Net.Sockets.TcpClient
            try { $online = $t.ConnectAsync($HostToCheck, 445).Wait(3000) } catch { $online = $false } finally { $t.Dispose() }
            if ($online) { break }
        }
        Start-Sleep -Seconds 15
    }
    if (-not $online) { Stop-WithCode 50 "$HostToCheck nach $OnlineTimeoutMin min nicht erreichbar." }
    Start-Sleep -Seconds 60   # Dienste fertig starten lassen
    Write-Log "----- Fertig: $HostToCheck erreichbar, Recovery Point $RpName -----"
    exit 0
}
catch {
    Write-Log ("Unerwarteter Fehler: {0}" -f $_.Exception.Message) 'ERROR'
    exit 1
}
