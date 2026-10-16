# Autopilot – préparation et contrôle des PC

Scripts utilisés pour enregistrer un nouveau PC dans Windows Autopilot (Hybrid Join) **pendant l'OOBE**, avant la remise à l'utilisateur. Les fichiers sont copiés à la racine d'une clé USB.

## Contexte d'exécution

- Pendant l'OOBE, **Shift+F10** ouvre une console qui tourne sous **SYSTEM** (déjà élevée).
- À ce stade, le PC n'a **aucune intégration** : pas d'agent SuperOps, pas de Ditzler-Powershell-Lib, pas d'Intune. Les scripts n'écrivent donc que dans un log local et n'envoient pas d'alerte.
- Log : `C:\Service\AutopilotSetup\Work\Autopilot-Vorbereitung.log` (conservé après le nettoyage).

## Fichiers

| Fichier | Quand | Rôle |
|---|---|---|
| `__OOBESchliessen.bat` | OOBE, Shift+F10, si besoin | Passe les pages EULA et clé produit, puis relance l'interface OOBE |
| `_launch_.cmd` | OOBE, Shift+F10 | Lance `Autopilot-Vorbereitung.ps1` |
| `Autopilot-Vorbereitung.ps1` | via `_launch_.cmd` | Windows Update (plusieurs cycles avec redémarrages), puis upload du hash Autopilot et affectation du profil |
| `_check_.cmd` | Après Autopilot, session de l'utilisateur | Lance `CheckEnrollementPC.ps1` **sans droits admin** |
| `CheckEnrollementPC.ps1` | via `_check_.cmd` | Vérifie le Hybrid Join, le PRT, les certificats, l'enrollment Intune, les services et la synchronisation |

## Procédure

1. Démarrer le PC neuf jusqu'à l'OOBE, puis **Shift+F10**.
2. Si nécessaire : `X:\__OOBESchliessen.bat` (X = lettre de la clé USB).
3. Lancer `X:\_launch_.cmd`.
   - Le script copie ses fichiers dans `C:\Service\AutopilotSetup`, vérifie le réseau, installe PSWindowsUpdate puis les mises à jour.
   - **En cas de redémarrage automatique** : revenir à l'OOBE, **Shift+F10**, puis relancer `C:\Service\AutopilotSetup\_launch_.cmd` (ou celui de la clé USB). Le compteur de cycles est conservé sur le disque.
   - Au maximum **5 cycles** (`$MaxZyklen`). Au-delà, le script passe quand même à l'onboarding et affiche un warning.
4. Quand le message « BEREIT FUER AUTOPILOT-ONBOARDING » s'affiche : avoir les identifiants admin M365 sous la main, appuyer sur une touche et **se connecter immédiatement** dans la fenêtre du navigateur (elle a un timeout).
5. Le script importe le hash, affecte le profil et vérifie que l'appareil apparaît dans Intune.
6. Éteindre le PC : `shutdown /s /t 0`. L'utilisateur le démarre ensuite et se connecte avec son compte M365.
7. Après la première connexion de l'utilisateur, lancer `_check_.cmd` **dans sa session** (sans élévation).

## Options de `Autopilot-Vorbereitung.ps1`

- `-GroupTag <Tag>` : Group Tag Autopilot (vide par défaut).
- `$AusgeschlosseneKBs` (section Konfiguration) : liste de KB à ne pas installer, par exemple `@('KB5127648')`.
- Filtre Windows Update : pas de feature upgrades (catégorie `Upgrades`) ni de previews (titre `Preview|Vorschau`). Les pilotes sont installés.

## Points d'attention

- Les scopes Graph sont **identiques** à ceux que `Get-WindowsAutoPilotInfo` 3.9 demande lui-même. S'ils diffèrent, une deuxième connexion est demandée.
- `CheckEnrollementPC.ps1` ne demande plus d'identifiants admin et n'a plus besoin de WinRM. Si une zone (HKLM, magasin de certificats) n'est pas lisible, il affiche un warning plutôt qu'une erreur.
