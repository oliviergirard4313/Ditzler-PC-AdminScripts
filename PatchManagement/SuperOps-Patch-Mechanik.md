# Patch Management SuperOps — Mécanisme Catégorie / Rule Builder / Policy

Statut : DRAFT — sections marquées `[A CONFIRMER]` à valider avec GIO avant diffusion.
Dernière mise à jour : 2026-08-25

## 1. Vue d'ensemble — 3 couches indépendantes

SuperOps sépare la classification patch en trois objets distincts qui se chaînent :

```
Asset (Windows Machine)
  └─ Custom Field "Categorie_SW-Patch" (valeur radio, assignée manuellement)
        │
        ▼  Category Rule Builder (règle : "Categorie_SW-Patch is X" → map device category)
Device Category (ex: "SV - Software Standard - Update Ring Auto 1")
        │
        ▼  Policy Management > Association
Policy Set (comportement réel : scan seul / auto-install / fenêtre)
```

**Pourquoi 3 couches et pas une seule ?** Le Custom Field est la seule donnée qu'on assigne
manuellement, asset par asset. Le Rule Builder automatise la traduction de cette valeur "métier"
vers l'objet technique SuperOps ("Device Category") qui, lui, porte réellement une Policy. On ne
touche donc jamais la Policy directement par asset — on change juste le Custom Field, et tout le
reste suit automatiquement (après "Apply Rule").

## 2. Couche 1 — Custom Field "Categorie_SW-Patch"

- Emplacement : Settings > Assets > Custom Fields > `Categorie_SW-Patch` (type Radio).
- Champ technique côté API : `customFields.udf17radio` (confirmé empiriquement le 05.08.2026,
  ex. asset SV-OS-BAK-03 → `SV_SW-Std_Auto-Update-1`).
- Assigné manuellement par technicien sur la fiche de chaque asset (section "Asset Info").
- Choix actuels (radio), serveurs et postes mélangés dans le même champ :

  | Valeur | Portée | Rôle |
  |---|---|---|
  | `SV_SW-Std_NO-Update` | Serveur | Jamais patché (W2012R2, DCs ditzlernet.local, cluster nodes WSUS+CAU) |
  | `SV_SW-Std_Update-ScanOnly` | Serveur | Scan seul, historique / non trié |
  | `SV_SW-Std_Auto-Update-1` | Serveur | Patch auto SuperOps, fenêtre 1 |
  | `SV_SW-Std_Auto-Update-2` | Serveur | Patch auto SuperOps, fenêtre 2 |
  | `SV_SW-Std_Manual-Update-Group-1..4` | Serveur | Patch manuel semi-automatisé (scripts `PatchManagement\`) |
  | `SV_SW-AV-Rly_Auto-Update-2` | Serveur | Relais Bitdefender, hors schéma standard |
  | `WS_SW-Std_Update-1/2`, `WS_SW-Std_Update-Pilot`, `WS_SW-IT_Update-Pilot`, `WS_SW-Marketing_Update-2`, `WS_SW-Kiosk_Update-1`, `WS_SW-Mike_Update-1` | Poste de travail | Postes, hors périmètre serveur de ce document |

## 3. Couche 2 — Category Rule Builder

- Emplacement : Policy Management > Category Rule Builder (BETA).
- Une règle = une condition sur `Categorie_SW-Patch` (`is <valeur>`) + un mapping
  "Then map device category" vers un **Device Category**.
- Les règles s'évaluent **de haut en bas** ; la première qui matche gagne (comme un firewall).
- Rien n'est appliqué tant qu'on ne clique pas **"Apply Rule"** (bouton en haut à droite) — donc
  ajouter/modifier une règle sans cliquer Apply Rule ne change rien pour les assets existants.
- Exemple confirmé (capture GIO) : règle `SV - Software Standard - Update Ring Auto 1` →
  condition `Categorie_SW-Patch is SV_SW-Std_Auto-Update-1` → Device Category
  `Windows Server - SW-Std_Auto-Update-1`. Modèle "1 valeur = 1 règle = 1 Device Category" —
  c'est le cas pour `Auto-Update-1`, `Auto-Update-2`, `Antivirus Relay Auto-Update-2`, etc.
- État observé (capture GIO, "Windows Machine" / vue Rule Builder, 2e passage) — règles serveur
  visibles : `SV - Software Standard - Update Scan Only` (31 Assets), `SV - Software Standard -
  Update Ring Auto 1` (15), `SV - Software Standard - Update Ring Auto 2` (12), `SV - Antivirus
  Relay - Update Ring Auto 2` (2), plus les règles Workstation (`WS - ...`). Les comptes évoluent
  au fil des classifications (29→31, 16→15, 13→12 entre les deux captures) — ne pas figer ces
  chiffres dans une doc finale, seulement les mécanismes.

  **`[CONFIRMÉ — capture GIO 25.08.2026, éditeur "Advance Rule" de `SV - Software Standard -
  Update Scan Only`]`** : contrairement au modèle "1 valeur = 1 règle" ci-dessus, les 4 groupes
  manuels ne sont **pas** séparés en 4 règles/Device Categories distinctes. Ils sont regroupés avec
  `NO-Update`, `ScanOnly` et les assets non-classés dans **une seule règle**, via des conditions
  en `OR` :

  ```
  Match: OR
    ( Categorie_SW-Patch is empty   AND   Platform Category is Server )
    OR  Categorie_SW-Patch is SV_SW-Std_Update-ScanOnly
    OR  Categorie_SW-Patch is SV_SW-Std_Manual-Update-Group-1
    OR  Categorie_SW-Patch is SV_SW-Std_Manual-Update-Group-2
    OR  Categorie_SW-Patch is SV_SW-Std_Manual-Update-Group-3
    OR  Categorie_SW-Patch is SV_SW-Std_Manual-Update-Group-4
    OR  Categorie_SW-Patch is SV_SW-Std_NO-Update
    OR  Categorie_SW-Patch is SV_SW-Std_Manual-Update-TEST   [ajouté 25.08.2026, cf. §7.5]
  Then map device category: SV - Software Standard - Update Scan Only
  ```

  **`[CONFIRMÉ, GIO 25.08.2026]`** — les 4 valeurs `Manual-Update-Group-1..4` dans cette règle sont
  correctes telles quelles, pas besoin de vérification supplémentaire de leur ordre/contenu exact.

  Donc **une seule Device Category** reçoit à la fois : les serveurs pas encore classés (champ
  vide + Platform Category Server), les serveurs `ScanOnly` historiques, les 4 groupes manuels,
  **et** les serveurs `NO-Update` (W2012R2 + DCs ditzlernet.local).

  **Pourquoi c'est cohérent, pas une erreur** : la Policy associée à cette Device Category est
  (doit être — §4) "scan seul, zéro auto-install", exactement le comportement voulu pour les 6 cas
  regroupés ici (rien ne doit jamais être installé automatiquement par SuperOps, que ce soit
  définitif pour `NO-Update` ou en attente de script pour les groupes manuels). **La
  différenciation entre les 4 groupes manuels, `NO-Update` et `ScanOnly` ne se fait donc pas dans
  SuperOps** (même Device Category, même Policy pour les 6) — elle se fait uniquement au niveau de
  la valeur du Custom Field, lue directement par les scripts PowerShell
  (`Build-ServerPatchCategoryPlan.ps1` / `Invoke-ManualPatchRun.ps1 -Category "..."`). Choix de
  conception valable, mais qui signifie qu'on **ne peut pas filtrer/monitorer les 4 groupes
  manuels séparément dans le portail SuperOps** — uniquement via le Custom Field ou les scripts.

  **`[A CONFIRMER]`** — Le badge **"New 4"** vu sur cette ligne dans la 1ère capture (absent de la
  2e) correspondait vraisemblablement à l'ajout récent des 4 conditions `Manual-Update-Group-N` à
  cette règle — cohérent avec ce qu'on observe maintenant, mais pas formellement confirmé.

  **`[A CONFIRMER]`** — Les conditions `OR` après la première ne portent pas de filtre `Platform
  Category is Server` : si un poste de travail avait par erreur une de ces valeurs dans
  `Categorie_SW-Patch`, il serait aussi capté par cette règle. Risque faible en pratique, mais à
  garder en tête si la règle est un jour dupliquée/modifiée.

## 4. Couche 3 — Policy Management > Policy Set (Advanced Policy)

- Emplacement : Policy Management > Advanced Policy > Policy Set (onglet Endpoint).
- Arbre Root Policy → Child Policy Set par Device Category, ex. observé :
  - `Windows Workstation - WS_SW_Std_Update-2` (root) → enfants `SW-Kiosk_Update-1`,
    `SW-Mike_Update-1`, `WS_SW-IT_Update-Pilot`, `WS_SW-Marketing_Update-2`, `WS_SW-Std_Update-1`,
    `WS_SW-Std_Update-Pilot`.
  - `Windows Server - SV_SW-Std_Update-ScanOnly` (root) → enfants `PD_SW-Std_Update-ScanOnly`,
    `SV_SW-AV-Rly_Auto-Update-2`, `SV_SW-Std_Auto-Update-1`, `SV_SW-Std_Auto-Update-2`.
- Onglet **Association** : lie un Device Category (couche 2) à un ou plusieurs clients pour que la
  règle s'applique réellement à leurs assets (message d'avertissement vu dans l'éditeur de règle :
  *"Please ensure the current device category is linked to one or more clients for the rule to
  apply to their devices."*). **`[A CONFIRMER]`** : les catégories serveur sont-elles bien associées
  au(x) bon(s) client(s) — sinon la règle du Rule Builder ne s'applique jamais malgré une condition
  correcte.

### 4.1 Contenu réel de la policy racine `Windows Server - SV_SW-Std_ Update-ScanOnly`

**`[CONFIRMÉ — capture GIO 25.08.2026, section "Patch Management" de la policy]`**

Badge **"Root policy"** : *"This is the root policy for all Windows devices. All child policies
inherit from this policy."* — c'est donc la policy racine de **tout** l'arbre "Windows Server"
(pas juste des 6 cas regroupés en §3), qui s'applique par défaut à tout serveur sans override plus
spécifique. Elle comporte plusieurs sous-sections indépendantes :

**a) Schedule Scan Timing** (fréquence des scans SuperOps, pas de l'installation) :
Scan every `1 day`, once à `05:00`.

**b) Approval configurations** — classification "Approve" / "Defer" par type de mise à jour, pour
3 niveaux de criticité (Important / Optional / Others) :

| Type | Important | Optional | Others |
|---|---|---|---|
| Critical Updates | APPROVE | APPROVE | APPROVE |
| Definition Updates | APPROVE | APPROVE | APPROVE |
| Feature Packs | DEFER | DEFER | DEFER |
| Service Packs | DEFER | DEFER | DEFER |
| Update Rollup | APPROVE | APPROVE | APPROVE |
| Drivers | APPROVE | APPROVE | APPROVE |
| Updates | APPROVE | APPROVE | APPROVE |
| Tools | APPROVE | APPROVE | APPROVE |
| Others | APPROVE | APPROVE | APPROVE |

Table séparée **Security Updates** (par sévérité Critical/Important/Medium/Low/Others) :
toutes en **APPROVE**.

**Defer patch deployment by : `8 week(s)`** — un délai de carence de 8 semaines s'applique avant
que les updates "Approve" soient effectivement proposés/déployés.

**c) Patch configuration** (section distincte, plus bas sur la page) :
- **Enable Wake on LAN** : désactivé.
- **Auto-update preferences : `Do Nothing`** — *"Let both the OS manager and SuperOps agent
  handle updates based on system settings"* (l'alternative `Disable` désactiverait l'auto-update
  Windows local pour ne laisser que l'agent SuperOps gérer). Avec `Do Nothing`, c'est donc la
  configuration Windows/WSUS locale (AUOptions, cf. GPO) qui prime — cohérent avec l'architecture
  "WSUS+GPO = double protection" documentée dans `Historique\discussion.txt`.
- **Reboot options** : "When user logged in" → *Repeatedly ask for permission*, intervalle 60 min,
  48 répétitions. "When user logged out" → *Do Nothing*.
- **"No patch schedule"** affiché avec une icône horloge+plus, avant remplissage des champs
  ci-dessus — indique qu'**aucune fenêtre de déploiement d'installation n'est programmée** pour
  cette policy racine (distinct du "Schedule Scan Timing" du point a, qui ne fait que scanner).

**`[CONFIRMÉ — réponse du support SuperOps (chat), 25.08.2026]`** : la table Approval (point b)
marque presque toutes les catégories d'updates en `APPROVE`, ce qui semblait contredire
l'hypothèse "scan seul, zéro auto-install" — mais le support SuperOps a confirmé la lecture posée
en §4.2 :

> With Auto-update preferences = "Do Nothing", SuperOps does not take control of Windows Update
> behavior. The OS manager (Windows or WSUS) keeps full control of how updates are handled. No
> patch schedule → SuperOps has no deployment window to trigger installs. Do Nothing → SuperOps
> does not manage or override Windows Update settings. Approval matrix = Approve → this only
> matters if SuperOps is managing installation. Result: SuperOps can still scan and report
> missing patches, but it will not trigger installations on its own. Actual installs are governed
> entirely by Windows Update or WSUS policies. So yes — this configuration effectively makes
> SuperOps scan-only for those devices.

Donc : la table `APPROVE` est **inerte** tant que `Auto-update preferences = Do Nothing` et qu'il
n'y a pas de "patch schedule" — SuperOps scanne et rapporte, mais n'installe jamais rien lui-même.
Le vrai gate est WSUS/GPO. Cette policy racine est donc bien "scan-only" en pratique pour tout
device qui en hérite sans override, y compris les 4 groupes manuels (§3) — l'affichage "Approve"
peut être ignoré/laissé tel quel sans risque tant que ces deux conditions restent vraies.

### 4.2 Pourquoi ça n'a pas d'importance pratique pour les groupes manuels (raisonnement GIO 25.08.2026)

Point clé, confirmé par le raisonnement suivant : l'installation des groupes manuels ne passe **à
aucun moment** par le pipeline d'installation de SuperOps (cf. §6 — `Install-ManualPatches-Local.ps1`
appelle directement l'API WUA locale sur les updates déjà approuvés côté **WSUS**, indépendamment
de la table Approval SuperOps). Donc, que la table Approval de la policy racine dise "Approve" ou
"Defer" **ne change rien** à ce que le script installe — c'est un réglage hérité, pas un contrôle
actif pour ces groupes.

**Décision : ne pas changer `Auto-update preferences` (garder `Do Nothing`).** Passer à `Disable`
retirerait la gestion des updates à l'OS manager local pour la confier exclusivement à l'agent
SuperOps — ce qui irait à l'encontre du besoin exprimé (garder la possibilité d'utiliser le GUI
Windows Update directement sur le serveur). `Do Nothing` + pas de "patch schedule" = l'agent
SuperOps n'installe jamais rien de lui-même, WSUS/GPO reste le seul gate réel, et le GUI natif
reste utilisable. Cohérent avec le principe de double protection déjà en place dans l'architecture
WSUS+GPO (`Historique\discussion.txt`).

**Vérification (deux voies en parallèle, lancées 25.08.2026) :**
- **`[CONFIRMÉ]`** Question posée au chat support SuperOps — réponse reçue le 25.08.2026,
  confirme formellement la sémantique "Do Nothing + no patch schedule = zéro action de l'agent
  SuperOps" (citation complète ci-dessus, §4.1).
- **`[OPTIONNEL / EN ATTENTE]`** Test réel sur `TEST-Update-1`, gardé comme validation empirique
  indépendante si souhaité : créer une nouvelle valeur de Custom Field dédiée au test (ex.
  `SV_SW-Std_Manual-Update-TEST`), une règle Rule Builder + Device Category dédiée, un Child
  Policy Set associé, assigner `TEST-Update-1` à cette valeur, puis observer sur plusieurs cycles
  de scan si un install se déclenche tout seul malgré la table Approval héritée en `APPROVE`. Plus
  nécessaire pour trancher la question (réponse support suffisante), mais reste utile pour
  valider le flux complet `Invoke-ManualPatchRun.ps1` de bout en bout avant de l'utiliser sur les
  4 groupes réels.

## 5. Ce que l'API SuperOps (IT-Edition, GraphQL) expose réellement

Endpoint : `https://euapi.superops.ai/it` (IT-Edition, pas MSP). Auth : header `Authorization:
Bearer <token>` + `CustomerSubDomain`. Credentials via `credentials.xml` (DPAPI, nécessite un
contexte SYSTEM pour être déchiffré — cf. script `Get-Credentials`).

**Confirmé disponible (testé) :**
- `getAssetList` (paginé par 100) → `assetId, name, hostName, platform, platformFamily, status,
  patchStatus, lastCommunicatedTime, customFields` — inclut `customFields.udf17radio`
  (= valeur du Custom Field Categorie_SW-Patch). Script : `Get-SuperOpsPatchInventar.ps1`.
- `getDeviceCategories` → `deviceCategoryId, name`. Script : `Test-SuperOpsConnection.ps1`.
- Mutations `runScriptOnAsset` et `assignDeviceCategory` existent dans le schéma (introspection du
  05/06.08.2026, script `Test-SuperOpsPatchMutations.ps1`) — donc en théorie il est possible de
  réassigner la Device Category d'un asset par API, et de lancer un script SuperOps sur un asset.

**`[CONFIRMÉ — introspection GraphQL exécutée par GIO le 25.08.2026, contexte SYSTEM local]`**
Résultat complet des champs `Query` correspondant à `categ|rule|polic|customfield|udf|associat` :

```
getAssetCustomFields         - Fetches the list of asset custom fields based on module Ex: Windows, Mac
getDeviceCategories          - Fetches a list of device categories
getItDocumentationCategories - Fetches all available IT document categories.
getServiceCategoryList       - Fetches a list of all the service categories created in the service catalog.
```

**Réponse à la question "peut-on récupérer la config par API ?" : non, pas pour les couches 2 et
3.** Aucun champ `Query` ne correspond au Category Rule Builder (les règles avec leurs conditions
`OR`/`AND` et leur mapping vers une Device Category) ni au Policy Set / Association (Advanced
Policy). Seules deux choses sont lisibles par API :
- **Couche 1** (Custom Field) : `getAssetCustomFields` (définition des champs) et
  `customFields.udf17radio` sur chaque asset via `getAssetList` (valeur assignée).
- **Couche 2, uniquement la liste plate** : `getDeviceCategories` retourne `deviceCategoryId,
  name` — donc on sait *quelles* Device Categories existent, mais pas *quelles conditions* les
  alimentent (le détail des règles reste UI-only, visible seulement dans l'éditeur "Advance Rule"
  du portail).
- **Couche 3 (Policy Set / Association)** : rien du tout — ni lecture ni, a priori, écriture par
  API pour cette partie (fonctionnalité "Advanced Policy", probablement encore BETA côté SuperOps).

Conséquence pratique : le Rule Builder et les Policy Sets doivent être **configurés et audités
manuellement dans le portail** (captures d'écran + ce document comme trace). Seule la couche 1
(assignation de la valeur du Custom Field par asset) peut être automatisée/vérifiée par script —
ce qui est déjà fait (`Get-SuperOpsPatchInventar.ps1`, mutation `assignDeviceCategory` disponible
si on veut un jour scripter le changement de Device Category directement — mais pas la logique de
règle elle-même).

**`[TROUVÉ 26.08.2026, écriture couche 1]`** La couche 1 n'est pas juste lisible mais aussi
**écrivible** par API : mutation `updateAsset(input: UpdateAssetInput!)` avec
`{ assetId: "...", customFields: { udf17radio: "<nouvelle valeur>" } }` (trouvé par recherche web,
documentation publique `https://developer.superops.com/it` — **pas encore vérifié directement
contre l'API réelle**, faute d'accès credentials.xml/SYSTEM dans cette session). Nouveau script
`Set-AssetPatchCategory.ps1` implémente ça, avec une vérification de schéma (`__type(name:
"UpdateAssetInput")`) exécutée avant tout envoi réel pour confirmer que les champs `assetId`/
`customFields` existent bien tels quels avant de faire confiance à la doc web. Permettrait
d'appliquer automatiquement `Server-Kategorien-Aenderungen.csv` (sortie de
`Build-ServerPatchCategoryPlan.ps1`) sans reclasser chaque serveur à la main dans le portail —
**à tester d'abord contre `TEST-Update-1/2/3` (catégorie `SV_SW-Std_Manual-Update-TEST`, sans
conséquence) avant tout usage sur de vrais serveurs**, voir en-tête du script pour la procédure.

## 6. Ce qui déclenche réellement le patch manuel (rappel — ne dépend pas de la couche 2/3)

Point important à ne pas mélanger avec les 3 couches ci-dessus : le patch **manuel** des 4 groupes
ne passe **pas** par une policy SuperOps ni par `runScriptOnAsset`. Le flux actuel (scripts du
dossier `PatchManagement\`) est :

1. `Build-ServerPatchCategoryPlan.ps1` — construit `Server-Kategorien-Uebersicht.csv` (snapshot
   local Nom → Catégorie cible), à partir d'AD + export SuperOps + historique Excel.
2. `Invoke-ManualPatchRun.ps1 -Category "SV_SW-Std_Manual-Update-Group-N"` — lit ce CSV local
   (pas une requête live SuperOps), cible les serveurs de ce groupe, et pousse
   `Install-ManualPatches-Local.ps1` sur chacun via **PsExec** (pas via l'API SuperOps).
   **`[CORRIGÉ 25.08.2026]`** À l'origine le contenu du script était embarqué inline en
   `-EncodedCommand` — ça a planté au premier vrai test (`TEST-Update-1`, `-WhatIf`) avec
   *"The filename or extension is too long"* (~38 000 caractères encodés, au-dessus de la limite
   pratique de `CreateProcess`/PsExec, ~32 700). Corrigé : le script est maintenant copié par SMB
   (`C$`) vers `C:\ProgramData\Superops\Scripts\_ManualPatchRun\<RunId>\install.ps1` sur chaque
   serveur cible puis lancé via `-File` ; il se supprime lui-même en fin d'exécution (même
   principe que la copie `resume.ps1` déjà utilisée pour la reprise post-reboot).
3. `Install-ManualPatches-Local.ps1` tourne localement sur le serveur : installe les updates déjà
   approuvés WSUS via l'API WUA (COM), gère les reboots (tâche planifiée de reprise), puis force un
   scan SuperOps (`osupdater.exe -patchAction patchScan`) pour que le portail reflète l'état.

**`[DÉCISION DE SCOPE, GIO 25.08.2026]`** PsExec nécessite une confiance de domaine (ou des creds
admin locaux partagés) entre la machine qui lance `Invoke-ManualPatchRun.ps1` et le serveur cible.
`TEST-Update-1` a révélé le problème (`Last logged in by WIN-6JK8H520HOV\Administrator` — compte
local, pas encore joint à `ditzlernet.local`, donc PsExec ne peut pas s'authentifier). Vérification
sur `Server-Patch-Category-Plan.csv` (colonne `InAD`) : les Groupes **1 et 2 sont déjà 100%
membres du domaine** (`InAD=True` pour tous leurs serveurs) — seul le **Groupe 4 (Grundstoff,
réseau isolé)** est hors domaine, ce qui était déjà connu et scopé à part depuis le début du
projet. Décision : **pas de réécriture vers `runScriptOnAsset`** (agent SuperOps) — on reste sur
un pipeline scripté maison, et on joint simplement `TEST-Update-1` au domaine pour qu'il soit
représentatif des Groupes 1/2/3. Le Groupe 4 et les cas DMZ (ex. `SV-PB-PRB-11` vs `SV-OS-PRB-01`)
restent hors du pipeline `Invoke-ManualPatchRun.ps1` — traités à la main ou via le patch auto
SuperOps natif.

**`[CORRIGÉ 25.08.2026 — 2e blocage]`** Après le join AD, `Invoke-ManualPatchRun.ps1` a quand même
échoué : `New-Item : The network path was not found` sur `\\TEST-Update-1\C$\...`. Cause : CIFS/SMB
(port 445) n'est pas autorisé entre serveurs — cohérent avec le fait que `TEST-Update-1` est dans
l'OU AD `10_LAPS-Managed-Servers` (LAPS + WinRM/Kerberos, sans mouvement latéral SMB, est le
durcissement attendu pour ce genre d'OU). **PsExec est donc abandonné entièrement** (il dépend lui
aussi de SMB pour son propre mécanisme, pas seulement pour notre copie de fichier). Remplacé par
**PowerShell Remoting (WinRM, port 5985/5986)** dans `Invoke-ManualPatchRun.ps1` :
`Invoke-Command` écrit le script sur le serveur cible et le lance en détaché
(`Start-Process -WindowStyle Hidden`, équivalent du `-d` de PsExec), et le suivi d'état
(`state.json`) est lui aussi lu via `Invoke-Command` au lieu d'un chemin UNC — plus aucune
dépendance à SMB, ni pour le push ni pour le polling. Le reste de l'architecture (script copié
temporairement puis auto-supprimé, reprise après reboot via Scheduled Task locale SYSTEM sur la
cible) est inchangé — ce mécanisme ne dépendait déjà pas du canal de transport initial.
**`[A CONFIRMER]`** — vérifier que WinRM est bien activé/accessible sur tous les serveurs des
Groupes 1/2/3 avant un run réel (préflight `Test-WSMan` déjà intégré dans le script, échoue
proprement par serveur sinon).

**`[CORRIGÉ 25.08.2026 — 3e blocage, cause racine trouvée]`** `Test-WSMan` passait (WinRM
joignable, Kerberos négocié) mais `Invoke-Command` échouait avec *"Access is denied"*, y compris
après reboot de `TEST-Update-1` et confirmation que Domain Admins est bien admin local (pas besoin
de GPO — hypothèses intermédiaires rejetées). Log `Microsoft-Windows-WinRM/Operational` sur la
cible a donné la vraie cause : *"The authorization of the user failed with error 5"* — échec
**après** la négociation Kerberos, au moment de l'autorisation de session WinRM.

**Cause racine** : `Invoke-ManualPatchRun.ps1` était lancé depuis une PowerShell ouverte via
`psexec -i -s` (SYSTEM), habitude héritée du contournement DPAPI pour `credentials.xml`
(cf. [[feedback_superops_credentials_dpapi]]). Sous SYSTEM, même si `klist` affiche un ticket
Kerberos "adm_gio", c'est un cas classique de **double-hop/délégation** : le nego Kerberos réussit
au niveau transport (d'où `Test-WSMan` OK), mais le token qui arrive côté cible pour l'ouverture de
session WinRM n'a pas tous les SID de groupe d'adm_gio — d'où l'échec d'autorisation. Confirmé par
un test avec `-Credential` explicite (fresh Negotiate direct en tant qu'adm_gio, hors ticket
emprunté de SYSTEM) : ça fonctionne (`whoami` renvoie bien `ditzlernet\adm_gio`).

**`[CONFIRMÉ, GIO 25.08.2026]`** `Invoke-ManualPatchRun.ps1` et `Install-ManualPatches-Local.ps1`
**n'utilisent pas `credentials.xml`/l'API SuperOps** (contrairement à
`Get-SuperOpsPatchInventar.ps1`, `Test-SuperOpsSchemaIntrospect.ps1`, etc.) — `psexec -i -s`
n'était donc jamais nécessaire pour ce pipeline. **Solution : lancer le pipeline de patch depuis
une PowerShell normale, en tant qu'utilisateur (`adm_gio`), jamais via `psexec -i -s`.** Réserver
`psexec -i -s` exclusivement aux scripts qui parlent réellement à l'API SuperOps.

**`-WhatIf` (ajouté 25.08.2026)** : `Invoke-ManualPatchRun.ps1` et `Install-ManualPatches-Local.ps1`
supportent désormais `-WhatIf` (`SupportsShouldProcess`), propagé de l'orchestrateur jusqu'au
script exécuté à distance via PsExec. En mode `-WhatIf` : les updates en attente sont listés
(titre, KB, IsDownloaded) mais rien n'est téléchargé/installé/rebooté, et le scan SuperOps final
n'est pas déclenché. Limite connue : WUA ne peut pas savoir *avant* installation réelle si un
reboot sera nécessaire — le `-WhatIf` s'arrête donc après la 1ère liste, sans simuler plusieurs
rondes. Exemple : `.\Invoke-ManualPatchRun.ps1 -ServerList TEST-Update-1 -WhatIf`.

Conséquence : la couche 2/3 (Rule Builder + Policy Set) sert surtout à **garantir que SuperOps
lui-même n'installe rien automatiquement** sur ces serveurs (double protection avec WSUS), pas à
déclencher l'installation — c'est le rôle des scripts. Documenter/corriger la couche 2/3 reste
important pour la sécurité (éviter un auto-install SuperOps concurrent), mais n'est pas un
bloquant pour que `Invoke-ManualPatchRun.ps1` fonctionne.

## 6b. Piste `runScriptOnAsset` (agent SuperOps) — abandonnée pour l'installation réelle

**`[CONCLUSION 25.08.2026 — investigation approfondie]`** Après un pivot vers `runScriptOnAsset`
(script poussé via l'agent SuperOps plutôt que WinRM, dans l'espoir de contourner le mur WUA-COM),
constat final après de nombreux tests reproductibles sur `TEST-Update-1` :

- **`Search()`** fonctionne dans tous les contextes testés (WinRM synchrone, WinRM en job,
  agent SuperOps).
- **`Download()`/`Install()`** échouent dans **tous** les contextes testés : WinRM synchrone →
  `E_ACCESSDENIED` (0x80070005) propre et attrapé par notre `try/catch` ; tâche planifiée SYSTEM →
  même code, propre, visible dans Task Scheduler ; agent SuperOps (déclaré "Run as: System/Root
  User") → **mort silencieuse du process, sans aucune trace** (ni journal Application, ni
  Windows Defender, ni Bitdefender, ni journal `Microsoft-Windows-WindowsUpdateClient/Operational`,
  ni le propre journal de l'agent SuperOps) — reproduit deux fois de suite, systématiquement au
  même point (`Downloader.Download()`), après avoir écarté un problème réseau/WSUS (WSUS bien
  configuré via GPO - `AUOptions=3`, `UseWUServer=1` - et joignable, Internet aussi joignable).
- **Conclusion** : c'est la même limite de fond que celle identifiée dès le début (§ transport) -
  l'API COM WUA refuse `Download()`/`Install()` sans window station interactive, quel que soit le
  mécanisme de lancement essayé. Le pivot vers l'agent SuperOps ne contourne pas le problème, il
  change seulement la façon dont l'échec se manifeste (crash muet au lieu d'une exception propre).

- **`[RISQUE DE SÉCURITÉ IMPORTANT, GIO 25.08.2026]`** Constat additionnel et distinct : quand un
  script lancé via l'agent SuperOps reste bloqué en statut **"In Progress"** (ce qui arrive
  justement à chaque crash muet ci-dessus), **l'agent semble le relancer automatiquement à chaque
  redémarrage du service agent ou du serveur** — observé avec la même action ID réutilisée après
  reboot, et plusieurs entrées "Install-ManualPatches-Local" empilées en "In Progress" dans le
  panneau Executed Scripts après plusieurs cycles crash→reboot. **Implication** : tant qu'on ne
  comprend pas précisément ce mécanisme de reprise, il ne faut **pas** utiliser
  `runScriptOnAsset`/la Script Library pour des actions réelles et impactantes (install de patch,
  reboot) sans garde-fou supplémentaire — un script à moitié exécuté pourrait se relancer tout seul
  de façon incontrôlée à chaque redémarrage du serveur cible.

**`[TROUVÉ 25.08.2026]`** Le bouton portail "Approve & Install" (onglet Patches d'un asset) appelle
la mutation `executeAssetPatchAction(input: AssetPatchActionInput!)` avec
`{ assetId, patchIds: [...], actionType: "APPROVE_AND_INSTALL", approveAtPolicyLevel: false }` —
capturé via DevTools navigateur (Network). C'est exactement la sémantique voulue pour les groupes
manuels : déclenchement **à la demande**, indépendant du planning de la policy
(`approveAtPolicyLevel: false`). Test réel effectué sur `TEST-Update-1` (1 patch) : `DismHost` et
`wuaucltcore` se sont mis à tourner activement juste après — installation réelle en cours,
confirme que le mécanisme natif fonctionne bien là où notre script WUA échouait.

**`[BLOQUANT — pas la même API]`** Cette mutation tourne sur `https://support.ditzler.ch/rmm-web/rmm/api`,
authentifié par **cookies de session navigateur + jeton CSRF** (`app-token`, `uitoken`, `x-csrf-token`,
`x-user-role-type: TECHNICIAN`) — **pas** la même API ni le même mécanisme d'auth que
`https://euapi.superops.ai/it` (Bearer token via `credentials.xml`) utilisé par tous nos scripts.
C'est l'API interne de l'application web du portail, pas l'API publique documentée. Ne figure pas
dans les 53 mutations de l'API publique (confirmé - liste complète obtenue précédemment).
**`[A FAIRE]`** Redemander au support SuperOps : existe-t-il un équivalent de
`executeAssetPatchAction` sur l'API publique (accessible par clé API), plutôt que de tenter de
reproduire une session de navigateur complète depuis un script (fragile, non supporté, et
justement ce que la protection CSRF vise à empêcher).

**`[PERCÉE, GIO 25.08.2026 — question sur BatchPatch]`** GIO a demandé pourquoi un outil comme
BatchPatch (référence commerciale connue pour l'automatisation de patch Windows) y arrive alors
que nous non. Piste testée et **validée sur `TEST-Update-1`** : contourner entièrement l'API COM
`IUpdateInstaller.Install()` et installer directement les paquets déjà en cache local
(`C:\Windows\SoftwareDistribution\Download\...`) via **`DISM.exe /Online /Add-Package
/PackagePath:<fichier> /NoRestart`** — un outil en ligne de commande conçu pour l'installation
hors-ligne/scriptée, sans les contraintes de window station de l'API COM interactive.

Résultat sur KB5120708 (.NET cumulative update, fichier `.cab` déjà en cache d'une tentative
précédente) : *"The operation completed successfully."* **ExitCode 3010** (succès, reboot requis
pour finaliser). **Confirmé réellement installé** via `Get-HotFix -Id KB5120708` (pas juste DISM
qui prétend avoir réussi) — aucun crash, aucun `E_ACCESSDENIED`, testé via WinRM comme le reste du
pipeline.

**Limite découverte en testant KB5120233** (cumulative update de sécurité, format `.wim`
"checkpoint" plus complexe que KB5120708, nécessite d'abord une Servicing Stack Update - SSU) :
DISM se bloque (hang, pas d'erreur) en tentant d'appliquer un 2e paquet CBS alors qu'un reboot est
déjà en attente pour KB5120708 — comportement normal de la pile de servicing Windows (CBS), qui ne
permet qu'**une seule modification en attente de reboot à la fois**. Pas un nouveau bug, juste une
contrainte à respecter dans l'orchestration (rebooter entre chaque paquet nécessitant un reboot,
pas les empiler).

**Ce que ça change pour l'architecture** : le blocage du §4.1 n'était donc pas insurmontable — il
concernait spécifiquement l'API COM haut-niveau (`IUpdateInstaller`), pas l'installation en
elle-même. Nouvelle direction à explorer en priorité : réécrire l'étape d'installation de
`Install-ManualPatches-Local.ps1` pour utiliser DISM (paquets `.cab`/`.wim` CBS) et probablement
`wusa.exe` (paquets `.msu`) au lieu de `$Installer.Install()`, tout en gardant `Search()` (COM,
déjà fiable) pour la détection. Reste à valider :
- Comment obtenir de façon fiable le chemin du fichier en cache pour un update donné (mapping
  KB/UpdateID → fichier sous `SoftwareDistribution\Download`) sans dépendre de `Download()` COM.
- Si le téléchargement automatique WSUS (`AUOptions=3`, déjà configuré) suffit à peupler ce cache
  sans jamais appeler `Download()` nous-mêmes, ou s'il faut un déclencheur (`UsoClient
  StartDownload`, `wuauclt`) pour forcer le téléchargement à la demande.
- Gérer les paquets multi-fichiers (SSU + LCU) et leur ordre d'installation.
- Gérer les updates qui ne sont ni CBS ni MSU (WebView2, PowerShell — installeurs EXE/MSI classiques,
  probablement installables sans souci via leurs propres switches silencieux `/quiet`/`/S`).

Ça invalide en partie la conclusion "abandon de l'installation scriptée" ci-dessous, écrite avant
cette découverte — **§6b devient à relire avec cette nuance : le blocage concernait l'API COM
spécifiquement, pas l'installation scriptée en général.**

**`[IMPLÉMENTÉ, GIO 25.08.2026]`** `Install-ManualPatches-Local.ps1` réécrit : `Invoke-InstallRound`
n'appelle plus `Downloader.Download()`/`Installer.Install()` (COM). Nouvelle logique :
- **Download** : plus d'appel `Download()` du tout — on s'appuie sur le téléchargement WSUS
  automatique en arrière-plan (déjà configuré, `AUOptions=3`), avec juste un `DetectNow()` (COM,
  fire-and-forget, jamais bloqué contrairement à `Download()`) pour donner un coup de pouce. Les
  updates pas encore téléchargées sont journalisées et sautées pour cette ronde (retentées à la
  ronde/au run suivant).
- **Install** : nouvelle fonction `Get-CachedPackageFiles` qui retrouve les fichiers
  `.cab`/`.wim`/`.msu` déjà en cache (`C:\Windows\SoftwareDistribution\Download\...`) par numéro de
  KB (en excluant les fichiers de métadonnées), et inclut automatiquement tout `SSU-*.cab` présent
  dans le même dossier de session (prérequis Servicing Stack Update, ne porte pas le KB du
  cumulative update dans son nom). Tous les fichiers `.cab`/`.wim` sont passés en **un seul appel**
  `dism.exe /Online /Add-Package /PackagePath:<f1> /PackagePath:<f2> ... /NoRestart` (DISM gère
  l'ordre SSU→LCU en interne dans ce cas) ; les `.msu` passent par `wusa.exe /quiet /norestart`
  séparément. Code retour 0/3010 = succès (3010 = reboot requis), le reste = échec (`throw`,
  capturé par le `try/catch` existant → `Status=Failed` proprement enregistré, pas de crash muet).

**Validation** : test manuel isolé sur KB5120708 = succès complet (`Get-HotFix` confirme). Test du
script intégré (`dismtest1`) : StateId/WhatIf résolus correctement, mais KB5120233 s'est retrouvé
`IsDownloaded=False` à ce moment précis — **cause connue et sans rapport avec le nouveau code** :
un test manuel DISM précédent sur KB5120233 avait été interrompu de force (`Stop-Process`), ce qui
a invalidé son état de téléchargement en cache (confirmé sain par ailleurs :
`DISM /Cleanup-Image /CheckHealth` → aucune corruption). Le script s'est correctement comporté
(a détecté l'absence de téléchargement et a sauté proprement, sans tenter d'installer un paquet
invalide). `DetectNow()` relancé pour retélécharger KB5120233 en arrière-plan — **test complet en
conditions propres (via `Invoke-ManualPatchRun.ps1`, pas un appel manuel isolé) encore à refaire**
une fois le retéléchargement terminé.

**Bug mineur corrigé au passage** : `Get-Variable -Scope 1` (fallback Run Time Variables SuperOps,
§3) levait une erreur visible (`"scope number exceeds active scopes"`) quand le script est appelé
en top-level direct (pas de scope appelant) - `-ErrorAction SilentlyContinue` ne la supprimait pas
entièrement (erreur de liaison de paramètre, pas une erreur de cmdlet classique). Corrigé avec
`try/catch` explicite autour des deux appels (`StateId` et `WhatIf`).

**`[DÉCISION D'ARCHITECTURE, GIO 25.08.2026 — voir percée DISM ci-dessus]`** Abandon de `runScriptOnAsset`/l'agent SuperOps pour
déclencher l'**installation** réelle. Nouveau partage des rôles :
- **Notre script (`Install-ManualPatches-Local.ps1` via WinRM)** : garde son rôle de
  **détection/rapport** uniquement (`Search()` fonctionne de façon fiable et reproductible dans ce
  contexte) - utile pour lister ce qui est en attente sur les serveurs des groupes manuels, sans
  jamais tenter d'installer quoi que ce soit soi-même.
- **L'installation réelle** doit passer par le **mécanisme natif de SuperOps** (déjà prouvé
  fonctionnel : catégories Auto-Update-1/2 installent avec succès aujourd'hui) - via le bouton
  portail "Approve & Install" ou son équivalent API, à investiguer séparément (aucune mutation
  `installPatches`/`approvePatch` trouvée dans les 53 mutations existantes - piste `sendApproval`/
  `updateApproval` écartée, sans rapport avec les patches). Reste à déterminer précisément comment
  déclencher ça par script pour les 4 groupes manuels sans repasser par une policy auto-install
  permanente (qui contredirait l'intention "manuel").
  **`[SUPERSEDÉ 26.08.2026]`** Ce partage des rôles ne tient plus : voir la percée UsoClient
  ci-dessous (§4.4bis), qui permet à notre propre script d'installer réellement — le mécanisme
  natif SuperOps n'est donc plus nécessaire du tout pour les 4 groupes manuels (confirmé,
  GIO ne souhaite pas explorer davantage cette piste). Voir §6c pour le déclenchement retenu.

**`[PERCÉE, GIO 25.08.2026 — question sur BatchPatch, suite]`** DISM s'est avéré insuffisant : il
rejette catégoriquement les paquets `.wim` ("Invalid package location specified ... Must be a
directory, or a file with a '.mum', '.cab' or '.esd' extension"), or KB5120233 (cumulative update
de sécurité 24H2) est livré précisément sous cette forme ("checkpoint cumulative update"). DISM
n'est donc viable que pour les paquets `.cab` simples, pas pour tout le flux de patch réel. Sur
suggestion de GIO, remplacement complet par **`UsoClient.exe StartInstall`** : cet outil parle au
vrai **Update Orchestrator Service** (`UsoSvc`), le même mécanisme que celui utilisé par Windows
Update lui-même quand tout fonctionne normalement — il gère **tous les formats de paquet**
(y compris les `.wim` checkpoint) sans qu'on ait besoin de gérer soi-même le mapping
KB→fichier/l'ordre SSU→LCU/le choix DISM vs `wusa.exe`.

**Nouvelle logique de `Invoke-InstallRound`** (remplace entièrement `Get-CachedPackageFiles` +
DISM/`wusa.exe`, fonction supprimée) :
1. `Get-PendingUpdates` (COM `Search()`, toujours fiable) donne la liste des updates ciblées pour
   cette ronde — capturée **avant** de lancer l'installation (titre + `KBxxxxxxx`, ou titre seul si
   pas de KB, ex. WebView2/PowerShell) pour pouvoir suivre leur sort individuellement.
2. `DetectNow()` (fire-and-forget, cf. ci-dessus) puis `UsoClient.exe StartInstall` — asynchrone,
   aucun signal de complétion direct.
3. **Polling** toutes les `InstallPollSeconds` (défaut 30s, paramétrable) : ré-interroge
   `Get-PendingUpdates` et considère un update "en cours" si sa propriété COM
   `IsPendingInstallation` est vraie. Le round se termine dès que plus aucun des updates ciblés
   n'apparaît dans les updates encore en attente (= installés), ou après 3 polls consécutifs sans
   aucun changement ET sans rien d'`IsPendingInstallation` (plus de progrès détectable), ou après
   `InstallMaxWaitMinutes` (défaut 45 min) — ce qui arrive en premier. Chaque update ciblé finit
   marqué `Installiert` ou `NochAusstehend` dans le résultat de la ronde.

**Validation, 25.08.2026, `TEST-Update-1`** (VM ré-obtenue après extinction due à une mise à jour de
l'hyperviseur — confirmé sans rapport avec le script) : test synchrone couvrant les deux cas qui
avaient posé problème avec DISM —
- **KB5120708** (`.cab` simple) : installé avec succès.
- **KB5120233** (checkpoint `.wim`, le cas qui faisait échouer DISM) : installé avec succès —
  confirmé par `Get-HotFix` et vérification du numéro de build OS après un vrai reboot.

Le script se termine proprement (`Status=Completed`, JSON valide, pas de crash), avec deux nouveaux
bugs mineurs révélés par ce test (sans lien avec UsoClient lui-même) :
1. `Test-WuaRebootRequired` (nouvelle fonction, remplace la lecture de `RebootRequired` sur le
   retour de l'ancien `Installer.Install()`) utilisait `Microsoft.Update.SystemInfo` (COM) — bloqué
   par le **même mur `E_ACCESSDENIED`** que `Download()`/`Install()` (§4.1), qui s'étend donc à tout
   `Microsoft.Update.*` au-delà de `Search()`, pas seulement aux méthodes de téléchargement/
   installation. **`[CORRIGÉ 26.08.2026]`** Remplacé par une vérification **registre**, sans COM :
   présence de `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\
   RebootPending`, de `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\
   RebootRequired`, ou d'une valeur non vide dans `PendingFileRenameOperations`
   (`HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager`).
2. `Save-State` échouait encore par intermittence avec `Access is denied`, malgré le fix précédent
   du §7 point 5 (suppression avant réécriture) puis un fix ultérieur par écriture .NET brute
   (`[System.IO.File]::WriteAllText`, 3 tentatives) — les deux se sont révélés insuffisants sur la
   durée : le Deny NTFS `BUILTIN\Users Deny AppendData` bloque l'accès **indépendamment** du chemin
   utilisé pour écrire (hypothèse initiale d'un blocage spécifique à la couche provider PowerShell
   invalidée par l'échec de l'écriture .NET brute). **`[CORRIGÉ 26.08.2026 — cause racine trouvée]`**
   La fonction `Initialize-StateDir` ajoutée pour corriger ça (casser l'héritage ACL sur le dossier
   d'état et poser une ACL propre SYSTEM+Administrators FullControl) ne se déclenchait en réalité
   **jamais** : elle ne s'exécutait que "si le dossier n'existe pas encore", or
   `Invoke-ManualPatchRun.ps1` crée déjà ce dossier (par un simple `New-Item`, sans fix ACL,
   ligne ~196) **avant même que `Install-ManualPatches-Local.ps1` ne démarre** sur le serveur cible
   — le dossier existait donc toujours au moment de l'appel, et le fix ACL n'était jamais appliqué.
   Corrigé en dissociant "créer le dossier si absent" de "corriger son ACL" : l'ACL est maintenant
   corrigée une fois par processus (drapeau `$script:StateDirAclFixed`), que le dossier ait été créé
   par l'orchestrateur ou par ce script lui-même. **Re-testé le 26.08.2026 (`acltest3`) : les deux
   avertissements ont disparu, `state.json` s'écrit et se relit correctement.**

**`[VALIDÉ 26.08.2026 — test complet avec vrai reboot]`** Run de bout en bout via
`Invoke-ManualPatchRun.ps1` (pas un appel manuel synchrone), avec un reboot **réellement déclenché**
(clé de registre `RebootRequired` positionnée manuellement avant le run pour forcer le passage par ce
chemin, en l'absence d'update en attente nécessitant un vrai reboot sur `TEST-Update-1` à cette
date) :
- Round 1 : update trouvée et traitée, `Test-WuaRebootRequired` détecte correctement le flag ->
  état `WaitingReboot` écrit et lu correctement par l'orchestrateur (poll externe).
- `Register-ResumeTask` + `shutdown.exe /r` déclenchent un **vrai redémarrage** de la VM (~3.5 min
  d'écart mesuré entre `WaitingReboot` et la reprise, cohérent avec un reboot réel de Windows
  Server, pas un faux retour).
- Après reboot : la tâche planifiée `AtStartup` se déclenche, relance le script en mode `-Resume`,
  round 2 s'exécute et se termine `Status=Completed`, **la tâche planifiée se supprime bien
  elle-même** (plus aucune trace après coup, confirmé par `Get-ScheduledTask`).
- `state.json` final cohérent sur les deux rounds (`RoundsDone=2, RebootsDone=1`), aucun
  `ScriptError`, aucune boucle de relance.
- Seul point restant à noter (pas bloquant, sans rapport avec le reboot) : la même mise à jour
  "Update for Microsoft Defender Antivirus antimalware platform - KB4052623" reste `NochAusstehend`
  après installation via `UsoClient` dans les deux rounds testés ce jour-là et lors du test
  précédent (`acltest3`) — possible indice que les updates de plateforme Defender ne transitent pas
  par le même canal qu'`UsoClient`/Update Orchestrator Service que les cumulative updates classiques
  (elles passent parfois par le client Defender lui-même plutôt que WU). **`[A INVESTIGUER, PAS
  PRIORITAIRE]`** — sans impact sur les mises à jour de sécurité critiques (KB5120708/KB5120233,
  déjà validées).

Le pipeline complet (détection → installation asynchrone via UsoClient → reboot → reprise → rescan
SuperOps) est maintenant **validé de bout en bout en conditions réelles**, exit-code fix (point 9
ci-dessous) inclus — même si ce dernier point spécifique (retour propre pour l'agent SuperOps) n'a
de sens que si `runScriptOnAsset` est un jour réutilisé, ce qui n'est plus le chemin retenu (le
pipeline utilise exclusivement l'orchestrateur WinRM, §6/§6b).

## 6c. Déclenchement du pipeline maison pour les 4 groupes manuels

**`[DÉCIDÉ, GIO 26.08.2026]`** Deux questions tranchées pour l'usage opérationnel du pipeline
(§4.4bis) sur les 4 groupes de patch manuel :

1. **Quand/comment ça se lance** : **manuel à la demande**, pas de planification automatique. Un
   technicien lance le pipeline explicitement quand il décide que c'est le moment (fenêtre de
   maintenance) — cohérent avec le sens même de "manuel" pour ces groupes (par opposition à
   Auto-Update-1/2, gérés par SuperOps sur son propre calendrier). Pas d'infrastructure de
   planification à construire pour l'instant.
2. **Source de la liste de serveurs par groupe** : **lecture live via l'API SuperOps** (Custom
   Field `customFields.udf17radio` par asset) plutôt que le CSV statique
   `Server-Kategorien-Uebersicht.csv` (qui peut devenir obsolète si un serveur change de catégorie
   dans le portail après la génération du CSV).

**Contrainte qui en découle** : lire le Custom Field en direct nécessite d'appeler l'API SuperOps,
donc de déchiffrer `credentials.xml` (DPAPI) — **confirmé empiriquement 26.08.2026** que ça échoue
sous le compte admin normal (`adm_gio`) avec `Key not valid for use in specified state`, même sur
la machine qui a produit le fichier (cohérence avec la leçon déjà connue, voir mémoire
`feedback_superops_credentials_dpapi`) : seul le contexte **SYSTEM** (`psexec -i -s`) peut
déchiffrer ce fichier. Or `Invoke-ManualPatchRun.ps1` a l'exigence strictement inverse : il doit
tourner sous un utilisateur normal, jamais SYSTEM, sous peine de casser le double-hop Kerberos WinRM
vers les serveurs cibles (§6, déjà documenté). Les deux contextes de sécurité sont incompatibles
dans le même process.

**Solution retenue : deux scripts séparés, deux étapes** (plutôt que d'imbriquer un appel
`psexec -i -s` interne dans l'orchestrateur — plus simple, plus robuste, et testable indépendamment
des deux côtés) :
1. **`Get-AssetsByPatchCategory.ps1 -Category "SV_SW-Std_Manual-Update-Group-N"`** (nouveau script)
   — à lancer via `psexec -i -s pwsh.exe -NoProfile -File ...` — interroge `getAssetList` (même
   requête que `Get-SuperOpsPatchInventar.ps1`), filtre sur `customFields.udf17radio -eq $Category`
   et `platformFamily` de type serveur, affiche la liste trouvée et une ligne prête à copier-coller
   au format `-ServerList srv1,srv2,...`.
2. **`Invoke-ManualPatchRun.ps1 -ServerList <liste obtenue>`** — lancé normalement (utilisateur
   admin, jamais SYSTEM) — inchangé, utilise déjà le paramètre `-ServerList` existant, aucune
   modification nécessaire à ce script.

**`[DÉCIDÉ, GIO 26.08.2026]`** Le reboot déclenché par `Install-ManualPatches-Local.ps1` utilise
`shutdown.exe /r /f` (forcé — ferme les applications sans demander d'enregistrer, sinon un dialogue
"Enregistrer ?" resté sans réponse bloquerait le reboot indéfiniment et casserait la reprise
automatique). Risque identifié : une session interactive avec du travail non sauvegardé (ex.
Notepad ouvert) serait fermée sans confirmation. **Décision de GIO** : acceptable tel quel, à
condition que l'opérateur voie qui est connecté sur chaque serveur **avant** de lancer le run — pas
besoin d'un garde-fou technique supplémentaire dans le script (ex. annuler le reboot si une session
active est détectée). Implémenté côté GUI (`PatchManagement-GUI.ps1`) : le tableau de sélection des
serveurs affiche une colonne "Angemeldete Benutzer" (requête `quser` par WinRM, remplie
automatiquement par "Server aktualisieren"), une ligne avec un utilisateur connecté est surlignée en
orange, et la boîte de confirmation avant lancement liste explicitement les serveurs concernés si la
case cochée en a. Aucun changement nécessaire dans `Install-ManualPatches-Local.ps1` lui-même — la
visibilité côté GUI est jugée suffisante.

**`[À VALIDER PAR GIO]`** `Get-AssetsByPatchCategory.ps1` n'a pas pu être testé par Claude Code de
bout en bout : `psexec -s`/`-i -s` échoue systématiquement depuis les outils Bash/PowerShell de
cette session avec `Couldn't install PSEXESVC service: The handle is invalid` (limitation de sandbox
connue, voir mémoire `feedback_superops_credentials_dpapi`) — seule la logique de requête GraphQL a
été vérifiée par relecture (mêmes patterns que `Get-SuperOpsPatchInventar.ps1`, déjà validé en
production) et la syntaxe PowerShell confirmée saine. À tester une fois par GIO via
`psexec -i -s pwsh.exe -NoProfile -File Get-AssetsByPatchCategory.ps1 -Category "..."` avant un
premier usage réel sur un groupe.

**`[CORRIGÉ 26.08.2026 — 2 régressions trouvées sur VM neuves]`** GIO a recréé les 3 VM de test à
neuf (`TEST-Update-1/2/3`, pas des clones - "cloner et espérer que le join domain fonctionne,
n'importe quoi"). Premier test multi-serveurs (`-WhatIf`) : timeout sur les 3, aucun `state.json`
jamais mis à jour après sa création initiale. Deux causes distinctes trouvées :
1. **`pwsh.exe` absent sur VM neuve** : le lancement (`& pwsh.exe -File install.ps1 ...` depuis
   l'orchestrateur) échouait avant même que le script cible ne démarre - `pwsh.exe` s'installe
   généralement via Windows Update lui-même, donc absent tant qu'aucun cycle n'a eu lieu sur une
   machine neuve. Corrigé : interpréteur par défaut changé de `pwsh.exe` vers `powershell.exe`
   (Windows PowerShell 5.1, présent nativement sur tout Windows Server) dans
   `Invoke-ManualPatchRun.ps1` **et** `Install-ManualPatches-Local.ps1` - aucun autre changement
   nécessaire, les deux scripts sont déjà `#Requires -Version 5.1` sans syntaxe PS7-spécifique.
2. **`Set-Acl` oublié dans le fix `-WhatIf:$false`** : une fois le lancement débloqué, `state.json`
   restait quand même bloqué sur `Status=Running, RoundsDone=0` indéfiniment. Cause : `Set-Acl` dans
   `Initialize-StateDir` (fix ACL du §4.4bis) supporte `ShouldProcess` et était silencieusement
   supprimé sous `-WhatIf` (`What if: Performing the operation "Set-Acl"...`) - l'ACL n'était donc
   jamais réellement corrigée. Un test synchrone direct a confirmé qu'il ne s'agissait **pas** d'un
   crash (le script se termine normalement, `Status=Completed`, process qui quitte proprement) :
   seule la toute première écriture de `state.json` (création du fichier) passait, tous les
   écrasements suivants échouaient avec le même `Access is denied` qu'avant le fix du §4.4bis - ni
   l'orchestrateur ni le GUI ne voyaient donc jamais la complétion, d'où un faux timeout. Corrigé :
   `-WhatIf:$false` ajouté à l'appel `Set-Acl`. **Leçon** : le piège `SupportsShouldProcess` (déjà
   rencontré 2 fois sur ce projet, voir mémoire `feedback_powershell_whatif_falsepositive`) peut
   resurgir à chaque nouvel appel de cmdlet ajouté dans un script `SupportsShouldProcess` - il faut
   systématiquement vérifier `(Get-Command X).Parameters.Keys -contains 'WhatIf'` **et** ajouter
   `-WhatIf:$false` pour toute opération de suivi d'état/log (pas seulement au moment du fix
   initial), pas seulement pour les cmdlets "évidentes".

## 6d. Exécution depuis un autre poste (cas Groupe 4 / réseau PSG isolé)

**`[GIO 27.08.2026]`** Le Groupe 4 (`SV-PSG-*`, Grundstoff / réseau isolé) n'est pas joignable depuis
le poste d'administration habituel — GIO doit lancer le pipeline depuis **`SV-PB-PRB-11`**. Ce que ça
implique :

**Fichiers à copier** (dans `C:\Admin\Ditzler\PatchManagement\` — chemin codé en dur dans le GUI via
`$RepoDir` et dans les valeurs par défaut de `Invoke-ManualPatchRun.ps1` ; un autre emplacement
oblige à passer `-LocalScriptPath`/`-OutputCsv` à la main ou à éditer `$RepoDir`) :
- **Strict minimum pour lancer un run** : `Invoke-ManualPatchRun.ps1` **+**
  `Install-ManualPatches-Local.ps1` (ce dernier n'est pas exécuté sur place : l'orchestrateur le lit
  et le pousse lui-même sur chaque cible par WinRM — mais il doit être présent localement).
- **Pour le GUI** : `PatchManagement-GUI.ps1` en plus.
- **Pour le bouton "Server aktualisieren" du GUI** (liste live depuis SuperOps) :
  `Get-AssetsByPatchCategory.ps1` en plus, et sur la machine il faut alors **PsExec** (cherché dans
  `C:\ProgramData\chocolatey\bin\`, `C:\Tools\`, puis le PATH) ainsi que
  `C:\ProgramData\Superops\Scripts\Ditzler-Powershell-Lib.psm1` + `credentials.xml` (déposés par
  l'agent SuperOps — présents si la machine est bien un asset SuperOps managé). Sans ça, le bouton
  ne marche pas mais **le reste du GUI reste utilisable** : coller la liste des 3 serveurs dans le
  champ "Manuell".
- Pas nécessaires : `Set-AssetPatchCategory.ps1`, `Build-ServerPatchCategoryPlan.ps1`,
  `Get-SuperOpsPatchInventar.ps1`, les `Test-*.ps1` et les CSV (sauf si on veut le mode `-Category`
  de l'orchestrateur, qui lit `Server-Kategorien-Uebersicht.csv` — inutile ici puisque le Groupe 4
  ne compte que 3 serveurs qu'on peut nommer directement en `-ServerList`).

**`[AJOUTÉ 27.08.2026]`** Deux correctifs faits pour rendre ce scénario possible :
1. **`-Credential` sur `Invoke-ManualPatchRun.ps1`** : jusqu'ici la connexion WinRM utilisait
   toujours le contexte ambiant de l'utilisateur. Si `SV-PB-PRB-11` et les serveurs `SV-PSG-*` ne
   sont pas dans le même domaine (la Grundstoff-Domäne est distincte de `ditzlernet.local`), le
   ticket Kerberos ambiant ne suffit pas. Nouveau paramètre optionnel, propagé à `Test-WSMan`,
   `New-PSSession` et au polling — sans lui, comportement inchangé. Usage :
   `-Credential (Get-Credential)`.
2. **Interpréteur du GUI plus codé en dur** : le bouton "Server aktualisieren" lançait
   `psexec -s pwsh.exe ...` en dur ; `pwsh.exe` peut manquer (même piège que §7 point 12). Il
   bascule maintenant automatiquement sur `powershell.exe` si PowerShell 7 est absent.

**`[À VÉRIFIER SUR PLACE]`** Impossible à tester d'ici : `SV-PB-PRB-11` n'est pas résolvable depuis
le réseau d'administration (attendu, c'est tout l'intérêt de la manœuvre). À confirmer une fois sur
la machine : présence de PsExec et de `credentials.xml`, et surtout si le WinRM vers les `SV-PSG-*`
passe avec le compte ambiant ou s'il faut `-Credential`.

## 7. Points ouverts / corrections potentielles

1. **`[CONFIRMÉ, GIO 25.08.2026]`** — Les 4 groupes manuels **ne sont pas** 4 Device Categories
   distinctes : ils partagent **une seule** Device Category/règle (`SV - Software Standard -
   Update Scan Only`) avec `NO-Update`, `ScanOnly` et les assets non-classés (§3). C'est voulu
   (même Policy scan-only requise pour tous), mais ça veut dire que SuperOps seul ne permet pas de
   distinguer un groupe manuel d'un autre — cette distinction vit uniquement dans la valeur du
   Custom Field, lue par les scripts.
2. **`[CONFIRMÉ, support SuperOps + GIO, 25.08.2026]`** — La policy racine approuve (`APPROVE`)
   presque toutes les catégories d'updates (délai 8 semaines), mais c'est sans effet pratique :
   avec `Auto-update preferences = Do Nothing` et sans "patch schedule", l'agent SuperOps ne
   déclenche jamais d'installation lui-même (confirmation officielle du support, citée en §4.1) —
   WSUS/GPO reste l'unique gate réel. Décision : ne **pas** passer `Auto-update preferences` sur
   `Disable`, afin de conserver l'usage du GUI Windows Update en direct sur les serveurs (besoin
   exprimé par GIO) — `Disable` retirerait cette possibilité en donnant le contrôle exclusif à
   l'agent SuperOps. Ce point est clos.
3. **`[A CONFIRMER]`** — Association couche 2 → client(s) correcte pour toutes les catégories
   serveur (le message d'avertissement vu dans l'éditeur suggère que ça peut être manquant).
4. **`[CONFIRMÉ, GIO 25.08.2026]`** — Portée API : Category Rule Builder et Policy Set/Association
   ne sont **pas** lisibles par API (voir §5, introspection complète) — configuration et audit
   restent manuels dans le portail pour ces deux couches.
5. **`[EN COURS, GIO 25.08.2026]`** Catégorie test — état réel, différent de ce qui était planifié
   en §4.2 (pas de Device Category/Policy Set dédiés) :
   - Nouvelle valeur Custom Field créée : `SV_SW-Std_Manual-Update-TEST`.
   - Serveur `TEST-Update-1` déployé et onboardé dans SuperOps (Backend Servers, Möhlin - Office,
     Windows Server 2025 Standard Evaluation), Custom Field déjà assigné à cette valeur.
   - Approche retenue, plus simple que prévu : au lieu d'une Device Category + Policy Set séparés,
     `SV_SW-Std_Manual-Update-TEST` est ajouté comme **8e condition OR** à la règle partagée
     existante (`SV - Software Standard - Update Scan Only`, §3) — donc `TEST-Update-1` hérite
     directement de la policy racine déjà validée comme scan-only (§4.1/§4.2), sans nouvelle
     policy à créer/tester. Cohérent avec la conclusion du support SuperOps.
   - **`[A CONFIRMER]`** : la règle a été éditée dans le portail (capture de l'éditeur "Advance
     Rule") — reste à confirmer que **Save** puis **Apply Rule** ont bien été cliqués pour que le
     changement s'applique réellement à `TEST-Update-1`.
   - Rôle du test : servir de validation empirique du flux complet
     `Invoke-ManualPatchRun.ps1`/`Install-ManualPatches-Local.ps1` (§6) avant application aux 4
     groupes réels — plus nécessaire pour la question policy (déjà tranchée par le support), utile
     pour tester le script lui-même (transport WinRM, reboot handling, rescan SuperOps).
   - **`[CORRIGÉ 25.08.2026 — 2 derniers bugs, run complet réussi]`**
     (a) Même piège `SupportsShouldProcess` que pour `Save-State`, mais cette fois dans
     l'**orchestrateur** lui-même : `Export-Csv` (résultats) et `Remove-PSSession` (nettoyage)
     étaient suppressés sous `-WhatIf` → `-WhatIf:$false` ajouté aux deux, plus
     `Import-Module CimCmdlets -WhatIf:$false` en tête de script pour éviter le bruit cosmétique
     `Set-Alias` déclenché par le premier `New-PSSession`.
     (b) `UpdatesInstalledTotal` affichait **8** au lieu de **0** sur un run `-WhatIf` : `Write-Info`
     à l'intérieur de `Invoke-InstallRound` pollue la valeur de retour de la fonction (tout
     `Write-Output` interne à une fonction PowerShell fait partie de son flux de sortie/retour,
     sauf capture explicite) — `$History` contenait donc des lignes de log en plus du résumé, et le
     comptage de l'orchestrateur (`@($r.Installed).Count`) traitait chaque ligne de texte comme "1
     update installée" (`@($null).Count` vaut 1, pas 0). Fixé en filtrant l'appel avec
     `| Select-Object -Last 1`. Bug préexistant au script original, pas introduit par les
     changements WinRM — mais qui aurait faussé le rapport final sur un vrai run.
   - **`[CORRIGÉ 25.08.2026 — 5e bug, casse totale du script]`** Le fix précédent (a) avait
     lui-même introduit une régression : `Import-Module CimCmdlets -WhatIf:$false` — sauf que
     `Import-Module` **n'a pas de paramètre `-WhatIf`** (`(Get-Command Import-Module).Parameters.Keys`
     ne le contient pas). PowerShell rapporte l'erreur de liaison de paramètre en attribuant le nom
     du **script appelant** dans le message (`"...ps1 : A parameter cannot be found that matches
     parameter name 'WhatIf'"`), ce qui pointait à tort vers le `-WhatIf` du script lui-même et a
     fait perdre beaucoup de temps en diagnostic (cache de session, version PowerShell, etc., tous
     écartés avant de trouver la vraie cause par bisection du fichier). **Leçon retenue** : avant
     d'ajouter `-WhatIf:$false` à un cmdlet, vérifier qu'il supporte réellement ShouldProcess via
     `(Get-Command <nom>).Parameters.Keys -contains 'WhatIf'`. Fix : `-WhatIf:$false` retiré de
     l'appel `Import-Module` (celui-ci n'en a simplement pas besoin). Le bruit cosmétique
     `Set-Alias` du chargement de `CimCmdlets` persiste dans les logs (inoffensif, ignoré).
   - **`[CONFIRMÉ 25.08.2026]`** `-WhatIf` de bout en bout réussi sur `TEST-Update-1`
     (5 updates trouvées et listées, dont KB5120233, `PowerShell v7.6.5`) après résolution des
     3 blocages transport (domain-join, SMB→WinRM, SYSTEM→admin normal, §6) et de 3 bugs
     supplémentaires découverts en testant réellement (ci-dessous). Le pipeline est maintenant
     validé de bout en bout en mode simulation.

   - **`[CORRIGÉ 25.08.2026 — 4e blocage, le plus profond]`** Une fois le transport WinRM validé,
     le lancement du script lui-même échouait silencieusement : `Start-Process`, `Win32_Process.Create`
     et une tâche planifiée "exécuter maintenant" menaient tous au même résultat — le process
     démarre, écrit l'état initial, puis meurt avec le code retour **`2147942401` (0x80070005,
     `E_ACCESSDENIED`)** dès qu'il appelle l'API COM `Microsoft.Update.Session` (WUA). Confirmé
     via le journal Task Scheduler, et confirmé que ce n'est **pas** une question de compte (même
     échec en SYSTEM et en `adm_gio` via S4U) — c'est le fait d'être **complètement détaché**
     (sans window station) qui bloque WUA, quel que soit l'utilisateur. **Fix retenu** : au lieu de
     lancer le script en process détaché, l'orchestrateur ouvre maintenant une **PSSession** par
     serveur et y lance le script comme **job en arrière-plan** (`Invoke-Command -Session ...
     -AsJob`) — ça reste rattaché au contexte de la session WinRM (comme le test manuel qui avait
     fonctionné), sans être un process orphelin. Sessions fermées à la fin du run (§5 du script).
   - **`[CORRIGÉ DÉFINITIVEMENT 26.08.2026 — bug annexe, voir aussi §4.4bis]`** Une fois WUA
     débloqué, nouvel échec plus banal : écriture de `state.json` refusée (`Access is denied`) lors
     d'un **écrasement** du fichier existant — ACL héritée `BUILTIN\Users Deny AppendData` sur le
     dossier `_ManualPatchRun`, qui bloque même un admin (indirectement membre de `Users`) car un
     Deny NTFS l'emporte toujours sur un Allow FullControl. Deux contournements successifs
     (suppression avant réécriture, puis écriture .NET brute) se sont révélés insuffisants sur la
     durée — cause racine trouvée et corrigée le 26.08.2026 : `Initialize-StateDir` casse
     maintenant l'héritage ACL du dossier d'état et pose une ACL propre, et se déclenche bien
     même quand le dossier a déjà été créé par l'orchestrateur (bug du fix précédent). Re-testé,
     confirmé résolu.
   - **`[RÉSOLU 26.08.2026 — voir validation complète ci-dessus]`** La reprise après reboot
     (`Install-ManualPatches-Local.ps1`, tâche planifiée locale `AtStartup`) est elle-même une
     **tâche planifiée** — le même type de lancement qui avait fait planter WUA avec
     `E_ACCESSDENIED` à l'origine. Risque resté non testé un moment car `-WhatIf` ne déclenche
     jamais de reboot. Testé en conditions réelles le 26.08.2026 via `Invoke-ManualPatchRun.ps1`
     de bout en bout (reboot réel forcé, round 2 après reboot, tâche auto-supprimée) : **aucun
     blocage**, la tâche `AtStartup` relance bien le script en mode `-Resume` sans retomber dans le
     mur `E_ACCESSDENIED` (contrairement au lancement détaché testé plus tôt — cette tâche relance
     `pwsh.exe -File ...` normalement, pas un process orphelin sans window station, et n'appelle
     que `Search()`/`UsoClient.exe`, jamais l'API COM haut-niveau qui posait problème).
6. **`[NOUVEAU]`** — Vérifier si le Custom Field radio `Categorie_SW-Patch is empty` (1ère
   condition de la règle §3) capte bien tous les serveurs *pas encore* onboardés/classés, et pas
   seulement ceux déjà en base — un serveur nouvellement onboardé dans SuperOps sans valeur de
   Custom Field devrait automatiquement finir en scan-only tant qu'il n'est pas classé
   manuellement, ce qui semble être le comportement voulu (filet de sécurité).
8. **`[CLOS, GIO 26.08.2026]`** Piste "Approve & Install"/mécanisme natif SuperOps pour les 4
   groupes manuels (§6b) — **abandonnée définitivement**, confirmé par GIO ("non, absolument pas")
   maintenant que le pipeline maison (UsoClient, §4.4bis) installe réellement de bout en bout sans
   dépendre du portail. Question suivante traitée : comment déclencher **notre propre** pipeline
   pour les 4 groupes → voir §6c ci-dessous.
9. **`[VALIDÉ 26.08.2026]`** Sur le risque de reprise automatique "In Progress" au redémarrage
   (§6b) : le script n'appelait jamais `exit N` explicitement en fin d'exécution — corrigé
   (`exit 0`/`exit 1` partout où le script se termine, y compris avant un reboot planifié). Validé
   indirectement par le test de reboot/reprise réel du 26.08.2026 (§4.4bis) : aucune relance
   intempestive observée sur le cycle complet round 1 → reboot → round 2 → Completed. Ce point ne
   couvre toujours pas le cas théorique d'un crash brutal pendant un appel COM bloquant (le process
   y meurt trop vite pour atteindre un `exit`) — mais cette famille d'appels (`Download()`/
   `Install()`) n'est plus utilisée du tout depuis le passage à UsoClient, donc le risque résiduel
   est nul en pratique pour ce pipeline.
7. **`[FAIT 26.08.2026]`** Petit GUI pour lancer/suivre les runs de patch manuel sans passer par la
   ligne de commande — voir §6c, `PatchManagement-GUI.ps1`.
10. **`[VALIDÉ, GIO 26.08.2026]`** `Set-AssetPatchCategory.ps1` (écriture du Custom Field par API,
    voir §5) testé de bout en bout par GIO contre `TEST-Update-1` : vérification de schéma
    `UpdateAssetInput` confirmée (`assetId, name, site, department, customFields, requester,
    warrantyExpiryDate, purchasedDate`), `-WhatIf` correct, puis écriture réelle non-idempotente
    (`SV_SW-Std_Manual-Update-TEST` → `SV_SW-Std_Auto-Update-1`) confirmée par relecture API, puis
    restauration à la valeur d'origine confirmée de la même façon. Script pleinement opérationnel -
    utilisable pour appliquer `Server-Kategorien-Aenderungen.csv` si un futur écart de
    catégorisation apparaît (le seul trouvé le 26.08.2026, `SV-OS-TIME-11`, s'est révélé être un
    faux positif - voir point 11).
11. **`[CONFIRMÉ, GIO 26.08.2026]`** Plan de catégorisation régénéré avec un export SuperOps frais
    (26.08.2026, 156 assets/58 serveurs) : la catégorisation réelle des 4 groupes manuels est
    **déjà en place en production** (Groupe 1 : 7 serveurs, Groupe 2 : 5, Groupe 3 : 1, Groupe 4 :
    3) — une seule vraie divergence trouvée par la comparaison automatique
    (`SV-OS-TIME-11`, en Manual-Update-Group-2 alors que la décision du 06.08.2026 recommandait
    Auto-Update-2), et GIO a confirmé que **cette décision du 06.08 était elle-même une erreur** —
    `SV-OS-TIME-11` reste à raison en Manual-Update-Group-2, aucun changement nécessaire.
    `Build-ServerPatchCategoryPlan.ps1` corrigé en conséquence (`$ManualOverrides` mis à jour) pour
    ne plus reproduire ce faux positif aux prochaines régénérations. Les 8 autres entrées "REVIEW"
    du plan sont des faux positifs de l'heuristique (basée sur l'historique Excel, qui ne
    "reconnaît" pas des serveurs classés manuellement après coup) — leur catégorie actuelle en
    production est correcte, rien à faire. **Conclusion : la couche 1 (Custom Field) des 4 groupes
    manuels est déjà correctement configurée pour de vrai, ce n'est plus un blocage.**
12b. **`[CORRIGÉ 26.08.2026]`** GIO a relevé que le GUI doit être lancé "Als Administrator" pour que
    le bouton "Server aktualisieren" fonctionne — `psexec -i -s` a besoin, même pour une élévation
    purement locale vers SYSTEM, que le processus appelant soit déjà élevé (sinon il ne peut pas
    installer son service `PSEXESVC`). Ajouté : vérification `WindowsPrincipal.IsInRole(Administrator)`
    au démarrage du GUI ; si non élevé, le bouton est désactivé avec un libellé et une infobulle
    explicites plutôt que d'échouer de façon confuse ou de déclencher une invite UAC en plein clic.
    Le reste du GUI (liste manuelle, lancement du patch via WinRM) fonctionne sans élévation.
12. **`[VALIDÉ 26.08.2026]`** Premier test `-WhatIf` du pipeline contre un **vrai serveur de
    production** (`SV-OS-APP-02`, seul membre du Groupe 3) via `Invoke-ManualPatchRun.ps1` :
    `Status=Completed`, 4 updates détectées et listées correctement, aucune erreur, rien installé/
    rebooté (comme attendu sous `-WhatIf`). Confirme que le pipeline fonctionne aussi bien sur un
    vrai serveur de prod que sur les VM de test.
13. **`[VALIDÉ 27.08.2026]`** Premier run **réel** (sans `-WhatIf`) du pipeline en production, sur
    `sv-os-mgt-01` (choisi par GIO, hors des 4 groupes manuels — catégorie `Auto-Update-2`, servait
    surtout à valider le pipeline lui-même). Avant le lancement : vérification systématique
    connectivité/WinRM + utilisateurs connectés (`quser`) — une session RDP active de GIO
    lui-même a été détectée et signalée, GIO a confirmé vouloir lancer quand même. Résultat :
    `Status=Completed`, 0 update trouvée (serveur déjà "Fully Patched"), aucun reboot nécessaire,
    aucune erreur — **le pipeline fonctionne en conditions réelles de bout en bout**.
    **Bug annexe trouvé et corrigé** : `SuperOpsScanOk=False` avec
    `SuperOpsScanError: "osupdater.exe nicht gefunden unter C:\Program Files\meineitrmm\bin\osupdater.exe"`
    — le dossier de l'agent SuperOps sous `Program Files` n'est pas uniforme (`meineitrmm` sur les
    VM de test, `superopsrmm` sur `sv-os-mgt-01`, probablement selon l'âge/le branding de
    l'installation de l'agent — confirmé par GIO comme spécifique à ce serveur "un peu bricolé",
    les autres ne devraient pas être concernés, mais le correctif reste une amélioration de
    robustesse valable dans tous les cas). Corrigé : recherche dynamique
    `C:\Program Files\*\bin\osupdater.exe` au lieu d'un chemin figé (exclut naturellement les
    copies `patch\<version>\backup|extracted\bin\` laissées par l'auto-mise-à-jour de l'agent, qui
    ont plus de niveaux de dossiers). Re-testé en `-RescanOnly` : `SuperOpsScanOk=True` confirmé.
