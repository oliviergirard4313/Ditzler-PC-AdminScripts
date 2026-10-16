<#
.SYNOPSIS
    Crée 4 comptes admin_ (Qlik Cloud Analytics) dans Active Directory.

.DESCRIPTION
    Même logique que New-ComarchAdminAccounts.ps1 (génération SamAccountName adm_<2 lettres
    prénom><1 lettre nom>, mot de passe aléatoire 16 caractères, affichage console uniquement),
    appliquée à ce nouveau lot de 4 utilisateurs.

    ⚠️ OU / GROUPES À CONFIRMER : ce script reprend par défaut la même OU et les mêmes groupes
    Comarch que le lot précédent (copiés depuis le template). "Qlik Cloud Analytics" étant a
    priori un périmètre différent, vérifiez que c'est bien voulu avant de lancer réellement —
    sinon passez vos propres -OUPath / -Groups. Testez avec -WhatIf d'abord.

    ⚠️ RDP + NLA : même piège que pour les comptes Comarch (voir New-ComarchAdminAccounts.ps1) —
    -ForcePasswordChangeAtLogon reste désactivé par défaut. Vérifiez le réglage NLA de l'hôte
    RDP cible pour ce périmètre avec Test-RdpNlaPasswordChange.ps1 avant de l'activer.

.EXAMPLE
    .\New-QlikAdminAccounts.ps1 -WhatIf
    Simule la création sans rien modifier dans l'AD.

.EXAMPLE
    .\New-QlikAdminAccounts.ps1 -OUPath 'OU=Qlik,OU=10_Admin-Users,OU=01_Users_W11,DC=ditzlernet,DC=local' -Groups 'GG-USR-Qlik-Admins'
    Crée les comptes dans une OU/groupe dédiés à Qlik plutôt que le défaut Comarch hérité du template.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$OUPath = 'OU=Polynorm,OU=10_Admin-Users,OU=01_Users_W11,DC=ditzlernet,DC=local',

    [string]$UPNSuffix = 'ditzlernet.local',

    [string[]]$Groups = @(
        'GG-Group-Comarch-PRJ',
        'GG-USR-Comarch-Server_Admins',
        'GG-USR-Comarch-SQL_Admins'
    ),

    [switch]$ForcePasswordChangeAtLogon,

    [ValidateRange(12, 64)]
    [int]$PasswordLength = 16,

    # Optionnel : export CSV local (désactivé par défaut, console uniquement).
    [switch]$ExportCredentialsCsv,
    [string]$CsvPath
)

#Requires -Version 5.1

# Résolution robuste du chemin CSV par défaut (ne dépend pas de $PSScriptRoot, qui peut être vide
# selon la façon dont le script est invoqué — copier-coller en console, ISE, raccourci, etc.)
if (-not $CsvPath) {
    $scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
                 elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
                 else { (Get-Location).Path }
    $CsvPath = Join-Path $scriptDir 'qlik-admin-accounts_DO-NOT-KEEP.csv'
}

# ---------------------------------------------------------------------------
# 0. Pré-requis
# ---------------------------------------------------------------------------
try {
    Import-Module ActiveDirectory -ErrorAction Stop
}
catch {
    throw "Le module ActiveDirectory (RSAT) n'est pas disponible sur cette machine. Installez RSAT-AD-PowerShell puis relancez."
}

if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OUPath'" -ErrorAction SilentlyContinue)) {
    throw "L'OU '$OUPath' est introuvable. Vérifiez le DistinguishedName (-OUPath)."
}

# ---------------------------------------------------------------------------
# 1. Données utilisateurs
#    Formule SamAccountName : adm_ + 2 premières lettres du prénom + 1ère lettre du nom (minuscules)
# ---------------------------------------------------------------------------
function Get-AdmSamAccountName {
    param(
        [Parameter(Mandatory)][string]$Vorname,
        [Parameter(Mandatory)][string]$Name
    )
    $normalize = {
        param($s)
        $formD = $s.Normalize([System.Text.NormalizationForm]::FormD)
        -join ($formD.ToCharArray() | Where-Object {
            [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark
        })
    }
    $v = (& $normalize $Vorname).Trim()
    $n = (& $normalize $Name).Trim()
    if ($v.Length -lt 2) { throw "Prénom '$Vorname' trop court pour générer un SamAccountName." }
    ('adm_{0}{1}' -f $v.Substring(0, 2), $n.Substring(0, 1)).ToLowerInvariant()
}

$Users = @(
    [PSCustomObject]@{ Vorname = 'Tobias';      Name = 'Luethi'; Funktion = 'Qlik Cloud Analytics'; Mail = 'Tobias.Luethi@polynorm.ch' }
)

foreach ($u in $Users) {
    $u | Add-Member -NotePropertyName SamAccountName -NotePropertyValue (Get-AdmSamAccountName -Vorname $u.Vorname -Name $u.Name) -Force
}

# Garde-fou : vérifie qu'il n'y a pas de collision de SamAccountName dans le lot
$dupes = $Users | Group-Object SamAccountName | Where-Object Count -gt 1
if ($dupes) {
    throw "Collision de SamAccountName détectée : $($dupes.Name -join ', '). Corrigez manuellement avant de continuer."
}

# ---------------------------------------------------------------------------
# 2. Génération de mot de passe aléatoire et sécurisé (sans caractères ambigus)
# ---------------------------------------------------------------------------
function New-RandomPassword {
    param([int]$Length = 16)

    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnpqrstuvwxyz'
    $digits  = '23456789'
    $special = '@#%+-_='
    $all     = $upper + $lower + $digits + $special

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    function Get-RandomChar([string]$set) {
        $bytes = [byte[]]::new(4)
        $rng.GetBytes($bytes)
        $idx = [System.BitConverter]::ToUInt32($bytes, 0) % $set.Length
        return $set[$idx]
    }

    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in @($upper, $lower, $digits, $special)) {
        $chars.Add((Get-RandomChar $set))
        $chars.Add((Get-RandomChar $set))
    }
    while ($chars.Count -lt $Length) {
        $chars.Add((Get-RandomChar $all))
    }

    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $bytes = [byte[]]::new(4)
        $rng.GetBytes($bytes)
        $j = [System.BitConverter]::ToUInt32($bytes, 0) % ($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }

    $rng.Dispose()
    -join ($chars[0..($Length - 1)])
}

# ---------------------------------------------------------------------------
# 3. Création des comptes + appartenance aux groupes
# ---------------------------------------------------------------------------
$results = [System.Collections.Generic.List[object]]::new()

foreach ($u in $Users) {
    $sam = $u.SamAccountName
    $upn = "$sam@$UPNSuffix"
    $displayName = "$($u.Vorname) $($u.Name)"

    if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        Write-Warning "Le compte '$sam' existe déjà — création ignorée. Vérifiez-le manuellement si besoin."
        continue
    }

    $plainPassword  = New-RandomPassword -Length $PasswordLength
    $securePassword = ConvertTo-SecureString -String $plainPassword -AsPlainText -Force

    $newUserParams = @{
        Name                  = $displayName
        GivenName             = $u.Vorname
        Surname               = $u.Name
        DisplayName           = $displayName
        SamAccountName        = $sam
        UserPrincipalName     = $upn
        EmailAddress          = $u.Mail
        Description           = "Admin-Konto – Funktion: $($u.Funktion) – Owner-Mail: $($u.Mail)"
        Title                 = $u.Funktion
        Path                  = $OUPath
        AccountPassword       = $securePassword
        Enabled               = $true
        ChangePasswordAtLogon = [bool]$ForcePasswordChangeAtLogon
        PasswordNeverExpires  = $false
        CannotChangePassword  = $false
    }

    if ($PSCmdlet.ShouldProcess($sam, "New-ADUser dans $OUPath")) {
        try {
            New-ADUser @newUserParams -ErrorAction Stop
        }
        catch {
            Write-Error "Échec de création de '$sam' : $_"
            continue
        }

        foreach ($g in $Groups) {
            try {
                if (-not (Get-ADGroup -Identity $g -ErrorAction Stop)) { continue }
                Add-ADGroupMember -Identity $g -Members $sam -ErrorAction Stop
            }
            catch {
                Write-Error "Échec d'ajout de '$sam' au groupe '$g' : $_"
            }
        }
    }

    $results.Add([PSCustomObject]@{
        Vorname         = $u.Vorname
        Name            = $u.Name
        Funktion        = $u.Funktion
        SamAccountName  = $sam
        UPN             = $upn
        MotDePasseInit  = $plainPassword
        MustChangeAtLogon = [bool]$ForcePasswordChangeAtLogon
    })
}

# ---------------------------------------------------------------------------
# 4. Restitution des identifiants (console uniquement)
# ---------------------------------------------------------------------------
Write-Host "`n=== Comptes créés — identifiants initiaux (à transmettre par SMS puis à effacer de l'historique console) ===" -ForegroundColor Yellow
$results | Format-Table Vorname, Name, Funktion, SamAccountName, MotDePasseInit, MustChangeAtLogon -AutoSize

if ($ExportCredentialsCsv) {
    $results | Select-Object Vorname, Name, Funktion, SamAccountName, UPN, MotDePasseInit, MustChangeAtLogon |
        Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
    Write-Warning "Export CSV écrit ici (contient des mots de passe en clair !) : $CsvPath — supprimez-le dès que la transmission SMS est terminée."
}

Write-Host "`nPensez à :" -ForegroundColor Cyan
Write-Host " - Confirmer que l'OU et les groupes Comarch hérités du template conviennent bien à ce périmètre Qlik."
Write-Host " - Vérifier le réglage NLA de l'hôte RDP cible pour ces comptes (Test-RdpNlaPasswordChange.ps1) avant -ForcePasswordChangeAtLogon."
Write-Host " - Vider l'historique de cette console une fois les SMS envoyés (Clear-History / fermer la fenêtre)."