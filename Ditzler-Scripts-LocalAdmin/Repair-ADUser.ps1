#Requires -Modules ActiveDirectory

[CmdletBinding()]
param(
    [string]$SamAccountName,
    [string]$UserPrincipalName,
    [string]$GivenName,
    [string]$Surname
)

Clear-Host

# ------------------------------------------------------------
# Entrées si non fournies
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($SamAccountName)) {
    $SamAccountName = Read-Host "SamAccountName de l'utilisateur à corriger"
}

if ([string]::IsNullOrWhiteSpace($UserPrincipalName)) {
    $UserPrincipalName = Read-Host "Nouveau UPN / E-Mail"
}

if ([string]::IsNullOrWhiteSpace($GivenName)) {
    $GivenName = Read-Host "Prénom"
}

if ([string]::IsNullOrWhiteSpace($Surname)) {
    $Surname = Read-Host "Nom"
}

$DisplayName   = "$GivenName $Surname"
$MailNickname  = $UserPrincipalName.Split("@")[0].ToLower()
$PrimaryProxy  = "SMTP:$UserPrincipalName"

# ------------------------------------------------------------
# Recherche utilisateur
# ------------------------------------------------------------

$TargetUser = Get-ADUser `
    -Filter "SamAccountName -eq '$SamAccountName' -or UserPrincipalName -eq '$UserPrincipalName'" `
    -Properties mail,mailNickname,proxyAddresses,DisplayName,Enabled,DistinguishedName `
    -ErrorAction SilentlyContinue

if (-not $TargetUser) {
    Write-Host ""
    Write-Host "Utilisateur introuvable." -ForegroundColor Red
    return
}

# ------------------------------------------------------------
# Mise à jour des attributs principaux
# ------------------------------------------------------------

Set-ADUser `
    -Identity $TargetUser.DistinguishedName `
    -GivenName $GivenName `
    -Surname $Surname `
    -DisplayName $DisplayName `
    -UserPrincipalName $UserPrincipalName `
    -EmailAddress $UserPrincipalName

# ------------------------------------------------------------
# Correction des attributs mail
# ------------------------------------------------------------

$ExistingProxyAddresses = @()

if ($TargetUser.proxyAddresses) {
    $ExistingProxyAddresses = @($TargetUser.proxyAddresses) | ForEach-Object {
        [string]$_
    }
}

# On conserve les autres types d'adresses (x500, sip, etc.)
# mais on remplace toutes les adresses smtp/SMTP par la nouvelle primaire
$ProxyAddressesClean = $ExistingProxyAddresses | Where-Object {
    $_ -notmatch '^SMTP:' -and $_ -notmatch '^smtp:'
}

$ProxyAddressesClean += $PrimaryProxy
$ProxyAddressesClean = @(
    $ProxyAddressesClean |
    Sort-Object -Unique |
    ForEach-Object { [string]$_ }
)

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
# Activation du compte si désactivé
# ------------------------------------------------------------

Enable-ADAccount -Identity $TargetUser.DistinguishedName -ErrorAction SilentlyContinue

# ------------------------------------------------------------
# Résultat final
# ------------------------------------------------------------

$Result = Get-ADUser `
    -Identity $TargetUser.DistinguishedName `
    -Properties mail,mailNickname,proxyAddresses,UserPrincipalName,DisplayName,Enabled

Write-Host ""
Write-Host "Utilisateur corrigé :" -ForegroundColor Green
Write-Host "Name            : $($Result.DisplayName)"
Write-Host "SamAccountName  : $($Result.SamAccountName)"
Write-Host "UPN             : $($Result.UserPrincipalName)"
Write-Host "mail            : $($Result.mail)"
Write-Host "mailNickname    : $($Result.mailNickname)"
Write-Host "Enabled         : $($Result.Enabled)"
Write-Host "proxyAddresses  :"
$Result.proxyAddresses | ForEach-Object { Write-Host " - $_" }