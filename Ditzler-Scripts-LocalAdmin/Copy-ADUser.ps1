#Requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [string]$SamAccountName,
    [string]$UserPrincipalName,
    [string]$GivenName,
    [string]$Surname,
    [string]$SourceUPN,
    [string]$TargetPath
)

Clear-Host

# ------------------------------------------------------------
# Entrées si non fournies
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($SamAccountName)) {
    $SamAccountName = Read-Host "SamAccountName, ex. USR-QS-KIOSK-01"
}

if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
    $UserPrincipalName = Read-Host "UPN / E-Mail, ex. USR-QS-KIOSK-01@ditzler.ch"
}

if ([string]::IsNullOrWhiteSpace($GivenName)) {
    $GivenName = Read-Host "Prénom"
}

if ([string]::IsNullOrWhiteSpace($Surname)) {
    $Surname = Read-Host "Nom"
}

$DisplayName = "$GivenName $Surname"

# ------------------------------------------------------------
# Vérifier si l'utilisateur cible existe déjà
# ------------------------------------------------------------

# Vérification UPN déjà existant
$ExistingUPN = Get-ADUser -Filter "UserPrincipalName -eq '$UserPrincipalName'" -ErrorAction SilentlyContinue
if ($ExistingUPN) {
    throw "UPN déjà utilisé : $UserPrincipalName"
}

$ExistingUser = Get-ADUser `
    -Filter "SamAccountName -eq '$SamAccountName' -or UserPrincipalName -eq '$UserPrincipalName'" `
    -ErrorAction SilentlyContinue

if ($ExistingUser) {
    Write-Host ""
    Write-Host "L'utilisateur existe déjà : $($ExistingUser.SamAccountName)" -ForegroundColor Yellow
    Write-Host "Utilise le script de correction pour le modifier." -ForegroundColor Yellow
    return
}

# ------------------------------------------------------------
# Utilisateur modèle (optionnel)
# ------------------------------------------------------------

$SourceUser = $null

if ([string]::IsNullOrWhiteSpace($SourceUPN)) {
    $SourceUPN = Read-Host "UPN de l'utilisateur à copier (laisser vide pour un nouvel utilisateur vierge)"
}

if (-not [string]::IsNullOrWhiteSpace($SourceUPN)) {
    $SourceUser = Get-ADUser `
        -Filter "UserPrincipalName -eq '$SourceUPN'" `
        -Properties * `
        -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        $TargetPath = $SourceUser.DistinguishedName -replace '^CN=[^,]+,',''
    }
}

# ------------------------------------------------------------
# OU cible
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($TargetPath)) {
    $TargetPath = Read-Host "OU cible, ex. OU=Users,DC=ditzlernet,DC=local"
}

# ------------------------------------------------------------
# Mot de passe initial
# ------------------------------------------------------------

$Password = Read-Host "Mot de passe initial" -AsSecureString

# ------------------------------------------------------------
# Création du compte
# ------------------------------------------------------------

if ($SourceUser) {
    New-ADUser `
        -Instance $SourceUser `
        -Name $DisplayName `
        -GivenName $GivenName `
        -Surname $Surname `
        -DisplayName $DisplayName `
        -SamAccountName $SamAccountName `
        -UserPrincipalName $UserPrincipalName `
        -EmailAddress $UserPrincipalName `
        -Path $TargetPath `
        -AccountPassword $Password `
        -Enabled $true `
        -ChangePasswordAtLogon $true
}
else {
    New-ADUser `
        -Name $DisplayName `
        -GivenName $GivenName `
        -Surname $Surname `
        -DisplayName $DisplayName `
        -SamAccountName $SamAccountName `
        -UserPrincipalName $UserPrincipalName `
        -EmailAddress $UserPrincipalName `
        -Path $TargetPath `
        -AccountPassword $Password `
        -Enabled $true `
        -ChangePasswordAtLogon $true
}

# ------------------------------------------------------------
# Normalisation des attributs mail après création
# ------------------------------------------------------------

$TargetUser = Get-ADUser `
    -Filter "SamAccountName -eq '$SamAccountName'" `
    -Properties proxyAddresses `
    -ErrorAction Stop

$MailNickname = $UserPrincipalName.Split("@")[0].ToLower()
$PrimaryProxy = "SMTP:$UserPrincipalName"

$ExistingProxyAddresses = @()

if ($TargetUser.proxyAddresses) {
    $ExistingProxyAddresses = @($TargetUser.proxyAddresses) | ForEach-Object {
        [string]$_
    }
}

# On garde uniquement les autres types (x500, sip, etc.)
$ProxyAddressesClean = $ExistingProxyAddresses | Where-Object {
    $_ -notmatch '^SMTP:' -and $_ -notmatch '^smtp:'
}

# Ajout de la nouvelle primaire
$ProxyAddressesClean += $PrimaryProxy

# Nettoyage final
$ProxyAddressesClean = @(
    $ProxyAddressesClean |
    Sort-Object -Unique |
    ForEach-Object { [string]$_ }
)

# Mise à jour
Set-ADUser `
    -Identity $TargetUser.DistinguishedName `
    -Replace @{
        mail         = $UserPrincipalName
        mailNickname = $MailNickname
    }

Set-ADUser `
    -Identity $TargetUser.DistinguishedName `
    -Clear proxyAddresses `
    -ErrorAction SilentlyContinue

Set-ADUser `
    -Identity $TargetUser.DistinguishedName `
    -Add @{
        proxyAddresses = [string[]]$ProxyAddressesClean
    }

# ------------------------------------------------------------
# Vérification finale
# ------------------------------------------------------------

$Result = Get-ADUser `
    -Filter "SamAccountName -eq '$SamAccountName'" `
    -Properties DisplayName,SamAccountName,UserPrincipalName,mail,Enabled

Write-Host ""
Write-Host "Utilisateur créé avec succès :" -ForegroundColor Green
Write-Host "Name            : $($Result.DisplayName)"
Write-Host "SamAccountName  : $($Result.SamAccountName)"
Write-Host "UPN             : $($Result.UserPrincipalName)"
Write-Host "mail            : $($Result.mail)"
Write-Host "Enabled         : $($Result.Enabled)"